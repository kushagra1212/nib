#include "rewrite/model_catalog.hpp"

#include <algorithm>
#include <cstdio>
#include "platform/http.hpp"
#include "platform/paths.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"

namespace nib {
namespace fs = std::filesystem;

namespace {

std::string hugging_face(const std::string& repo, const std::string& file) {
    return "https://huggingface.co/" + repo + "/resolve/main/" + file;
}

std::u16string gb(int64_t bytes) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.1f GB", static_cast<double>(bytes) / 1e9);
    return utf8_to_utf16(buf);
}

std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

}  // namespace

std::u16string CatalogModel::size_label() const {
    const double mb = static_cast<double>(bytes) / 1e6;
    char buf[32];
    if (mb >= 1000) std::snprintf(buf, sizeof buf, "%.1f GB", mb / 1000);
    else std::snprintf(buf, sizeof buf, "%.0f MB", mb);
    return utf8_to_utf16(buf);
}

namespace model_catalog {

const std::vector<CatalogModel>& all() {
    // Q8_0 for the 0.6B, not the 409MB Q4_0: Q4_0 fixed the misspellings and
    // left every grammatical error in a six-error sentence; Q8_0 fixes all six.
    static const std::vector<CatalogModel> models = {
        {"Qwen3-0.6B-Q8_0.gguf", u"Qwen3 0.6B",
         u"Small and quick. Fixes everyday mistakes -- wrong verb forms, tense, "
         u"plurals -- in about half a second.",
         804'753'632, hugging_face("ggml-org/Qwen3-0.6B-GGUF", "Qwen3-0.6B-Q8_0.gguf")},
        {"Qwen3-4B-Instruct-2507-Q4_K_M.gguf", u"Qwen3 4B",
         u"Writes like a person. Rewrites awkward sentences into natural English "
         u"rather than just fixing the commas. About a second and a half per rewrite "
         u"on a fast machine.",
         2'497'281'120,
         hugging_face("unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf")},
    };
    return models;
}

const CatalogModel& recommended() { return all()[1]; }
const CatalogModel& compact() { return all()[0]; }

CatalogModel local(const fs::path& file) {
    std::error_code ec;
    const auto size = fs::file_size(file, ec);
    const std::wstring stem = file.stem().wstring();
    return CatalogModel{file.filename().string(), std::u16string(stem.begin(), stem.end()),
                        u"Already on this machine.", ec ? 0 : static_cast<int64_t>(size),
                        file.string()};
}

fs::path install_directory() { return platform::paths::models_dir(); }

}  // namespace model_catalog

std::vector<std::string> rank_models(std::vector<std::string> names) {
    auto score = [](const std::string& name) {
        const auto l = lower(name);
        // The 4B instruct is measured as the one that actually rewrites.
        if (l.find("qwen3-4b") != std::string::npos) return 0;
        if (l.find("qwen3-1.7b") != std::string::npos) return 2;
        if (l.find("qwen3-0.6b") != std::string::npos) return 3;
        if (l.find("llama-3.2-3b") != std::string::npos) return 2;
        if (l.find("270m") != std::string::npos) return 9;  // verified inadequate
        return 5;
    };
    std::sort(names.begin(), names.end(), [&](const std::string& a, const std::string& b) {
        const int sa = score(a), sb = score(b);
        return sa != sb ? sa < sb : a < b;
    });
    return names;
}

namespace {

std::vector<fs::path> model_search_paths() {
    std::vector<fs::path> paths{platform::paths::models_dir()};
    fs::path dir = platform::paths::executable_dir();
    for (int i = 0; i < 7 && !dir.empty(); ++i) {
        paths.push_back(dir / L"models");
        if (dir == dir.parent_path()) break;
        dir = dir.parent_path();
    }
    return paths;
}

}  // namespace

std::optional<fs::path> find_model(const std::string& requested) {
    std::error_code ec;
    if (!requested.empty()) {
        const fs::path explicit_path = fs::u8path(requested);
        if (explicit_path.is_absolute() || requested.find_first_of("/\\") != std::string::npos) {
            if (fs::is_regular_file(explicit_path, ec)) return explicit_path;
            return std::nullopt;
        }
    }
    for (const auto& dir : model_search_paths()) {
        std::vector<std::string> names;
        for (const auto& entry : fs::directory_iterator(dir, ec)) {
            const auto name = entry.path().filename().string();
            // Not ".x.gguf.incoming": a half-written file loaded as though whole.
            if (entry.is_regular_file(ec) && entry.path().extension() == ".gguf"
                && !name.empty() && name[0] != '.') {
                names.push_back(name);
            }
        }
        if (names.empty()) continue;
        const auto ranked = rank_models(names);
        if (!requested.empty()) {
            if (std::find(ranked.begin(), ranked.end(), requested) == ranked.end()) continue;
            return dir / fs::u8path(requested);
        }
        return dir / fs::u8path(ranked.front());
    }
    return std::nullopt;
}

std::optional<fs::path> locate_llama_server() {
    return platform::paths::locate_engine(fs::path(L"llama") / L"llama-server.exe");
}

std::optional<fs::path> locate_harper() {
    return platform::paths::locate_engine(fs::path(L"harper") / L"harper-ls.exe");
}

std::optional<RewriteEngine::Config> rewrite_config(const std::string& requested) {
    const auto server = locate_llama_server();
    if (!server) return std::nullopt;
    const auto model = find_model(requested);
    if (!model) return std::nullopt;
    RewriteEngine::Config config;
    config.server_binary = *server;
    config.model_path = *model;
    return config;
}

// --- ModelInstaller ----------------------------------------------------------

ModelInstaller::ModelInstaller(fs::path destination, bool verifies)
    : destination_(std::move(destination)), verifies_(verifies) {}

ModelInstaller::~ModelInstaller() {
    cancel_ = true;
    if (worker_.joinable()) worker_.join();
}

bool ModelInstaller::busy() const {
    std::lock_guard lock(lock_);
    return stage_.kind == Stage::Kind::downloading || stage_.kind == Stage::Kind::verifying;
}

ModelInstaller::Stage ModelInstaller::stage() const {
    std::lock_guard lock(lock_);
    return stage_;
}

void ModelInstaller::set(Stage stage) {
    {
        std::lock_guard lock(lock_);
        stage_ = stage;
    }
    if (on_change) on_change(stage);
}

void ModelInstaller::fail(std::u16string message) {
    Stage s;
    s.kind = Stage::Kind::failed;
    s.message = std::move(message);
    set(std::move(s));
}

std::optional<std::u16string> ModelInstaller::space_problem(const CatalogModel& model,
                                                            std::optional<uint64_t> free_bytes) {
    if (!free_bytes) return std::nullopt;  // unknown capacity is not evidence
    const int64_t needed = model.bytes * 2 + 500'000'000;
    if (static_cast<int64_t>(*free_bytes) >= needed) return std::nullopt;
    return u"Not enough disk space. " + model.title + u" needs about " + gb(needed)
           + u" free while installing, and there is " + gb(static_cast<int64_t>(*free_bytes)) + u".";
}

void ModelInstaller::start(const CatalogModel& model) {
    {
        std::lock_guard lock(lock_);
        if (stage_.kind != Stage::Kind::idle) return;
    }
    if (worker_.joinable()) worker_.join();
    cancel_ = false;
    worker_ = std::thread([this, model] { run(model); });
}

void ModelInstaller::cancel() {
    // Only a running install can be cancelled; closing the window before
    // choosing anything must not report a cancellation of nothing.
    if (!busy()) return;
    cancel_ = true;
}

void ModelInstaller::reset() {
    if (busy()) return;
    if (worker_.joinable()) worker_.join();
    set(Stage{});
}

void ModelInstaller::run(CatalogModel model) {
    std::error_code ec;
    if (auto problem = space_problem(model, platform::paths::free_space(destination_))) {
        fail(*problem);
        return;
    }
    fs::create_directories(destination_, ec);
    const fs::path staged = destination_ / fs::u8path("." + model.filename + ".incoming");
    const fs::path final_path = destination_ / fs::u8path(model.filename);
    fs::remove(staged, ec);

    Stage progress;
    progress.kind = Stage::Kind::downloading;
    progress.total = model.bytes;
    set(progress);

    const bool is_local = model.url.rfind("http", 0) != 0;
    if (is_local) {
        // A file the user picked: copied rather than moved, it is theirs.
        if (!fs::copy_file(fs::u8path(model.url), staged, fs::copy_options::overwrite_existing, ec)) {
            fail(u"Could not copy the model: " + utf8_to_utf16(ec.message()));
            return;
        }
    } else {
        int32_t status = 0;
        try {
            status = platform::http::download(
                model.url, staged,
                [&](int64_t received, int64_t total) {
                    // The server's figure when it gives one, the catalogue's
                    // when not -- a chunked response would never move the bar.
                    Stage s;
                    s.kind = Stage::Kind::downloading;
                    s.total = total > 0 ? total : model.bytes;
                    s.received = received;
                    s.fraction = s.total > 0 ? std::min(1.0, double(received) / double(s.total)) : 0;
                    set(s);
                },
                cancel_);
        } catch (const std::exception& e) {
            fs::remove(staged, ec);
            if (cancel_) { Stage s; s.kind = Stage::Kind::cancelled; set(s); return; }
            fail(utf8_to_utf16(e.what()));
            return;
        }
        if (cancel_ || status == 0) {
            fs::remove(staged, ec);
            Stage s;
            s.kind = Stage::Kind::cancelled;
            set(s);
            return;
        }
        if (status < 200 || status >= 300) {
            fs::remove(staged, ec);
            fail(u"The download server answered " + to_u16(status) + u". The model may have moved.");
            return;
        }
    }

    // A truncated download is the common failure and looks most like success.
    // Tolerant of small differences: the catalogue's size can age.
    const auto size = static_cast<int64_t>(fs::file_size(staged, ec));
    if (ec || size <= model.bytes / 2) {
        fs::remove(staged, ec);
        fail(u"The download stopped early -- " + to_u16(size / 1'000'000) + u"MB of "
             + to_u16(model.bytes / 1'000'000) + u"MB. Check the connection and try again.");
        return;
    }
    // Into place in one step: a half-written file under the real name would be
    // found by the model search and loaded as though it were whole.
    fs::rename(staged, final_path, ec);
    if (ec) {
        fs::remove(staged, ec);
        fail(u"Could not save the model: " + utf8_to_utf16(ec.message()));
        return;
    }

    if (verifies_) {
        Stage s;
        s.kind = Stage::Kind::verifying;
        set(s);
        const auto server = locate_llama_server();
        if (!server) {
            fail(u"The model downloaded, but llama-server is missing. Reinstall nib.");
            return;
        }
        RewriteEngine::Config config;
        config.server_binary = *server;
        config.model_path = final_path;
        RewriteEngine engine(config);
        try {
            const auto answer = engine.rewrite(u"she dont like it", RewriteMode::fix_grammar);
            if (trimmed(answer).empty()) {
                fail(u"The model loaded but returned nothing. It may not be a model this build can use.");
                return;
            }
        } catch (const RewriteException& e) {
            fail(u"The model downloaded but would not load: " + e.error.description());
            return;
        }
    }
    log::write("model installed: " + model.filename);
    Stage done;
    done.kind = Stage::Kind::done;
    done.installed = final_path;
    set(done);
}

}  // namespace nib
