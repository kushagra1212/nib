#include "speech/speech_catalog.hpp"

#include <map>
#include "platform/paths.hpp"
#include "text/unicode.hpp"

namespace nib::speech {
namespace fs = std::filesystem;

namespace whisper_catalog {

const std::vector<CatalogModel>& all() {
    auto hf = [](const std::string& file) {
        return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + file;
    };
    static const std::vector<CatalogModel> models = {
        {"ggml-base-q5_1.bin", u"Whisper base",
         u"Smallest that works. Transcribes about 5x faster than you speak, and mishears unusual words.",
         59'700'000, hf("ggml-base-q5_1.bin")},
        {"ggml-small-q5_1.bin", u"Whisper small",
         u"Noticeably better on technical terms and accents, for three times the size.", 190'000'000,
         hf("ggml-small-q5_1.bin")},
        {"ggml-large-v3-turbo-q5_0.bin", u"Whisper large v3 turbo",
         u"The most accurate of these, and still faster than real time. Best for long dictation and "
         u"mixed languages.",
         574'000'000, hf("ggml-large-v3-turbo-q5_0.bin")},
    };
    return models;
}

const CatalogModel& recommended() { return all()[1]; }

fs::path install_directory() { return platform::paths::speech_dir(); }

namespace {
std::string& preferred() {
    static std::string name;
    return name;
}
}  // namespace

void prefer(const std::string& filename) { preferred() = filename; }

std::optional<fs::path> installed() {
    std::error_code ec;
    if (!preferred().empty()) {
        const auto chosen = install_directory() / fs::u8path(preferred());
        if (fs::is_regular_file(chosen, ec)) return chosen;
    }
    std::optional<fs::path> best;
    uintmax_t best_size = 0;
    for (const auto& e : fs::directory_iterator(install_directory(), ec)) {
        const auto name = e.path().filename().string();
        if (e.path().extension() != ".bin" || name.empty() || name[0] == '.') continue;
        const auto size = fs::file_size(e.path(), ec);
        if (!best || size > best_size) {
            best = e.path();
            best_size = size;
        }
    }
    return best;
}

}  // namespace whisper_catalog

namespace voice_catalog {
namespace {

std::string release(const std::string& file) {
    return "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/" + file;
}

std::optional<fs::path> exists(const std::string& name) {
    std::error_code ec;
    const auto p = install_directory() / fs::u8path(name);
    return fs::is_regular_file(p, ec) ? std::optional<fs::path>(p) : std::nullopt;
}

}  // namespace

const std::vector<CatalogModel>& models() {
    static const std::vector<CatalogModel> list = {
        {"kokoro-v1.0.onnx", u"Kokoro", u"The full model, and the one macOS nib runs. Best quality.",
         325'532'387, release("kokoro-v1.0.onnx")},
        {"kokoro-v1.0.int8.onnx", u"Kokoro, quantised",
         u"A quarter of the size for a small loss of quality.", 92'361'271, release("kokoro-v1.0.int8.onnx")},
    };
    return list;
}

const CatalogModel& voice_pack() {
    static const CatalogModel pack{"voices-v1.0.bin", u"Voices",
                                   u"54 voices. Needed whichever model is used.", 28'214'398,
                                   release("voices-v1.0.bin")};
    return pack;
}

fs::path install_directory() { return platform::paths::voice_dir(); }

std::optional<fs::path> installed_model() {
    for (const auto& m : models()) {
        if (auto p = exists(m.filename)) return p;
    }
    return std::nullopt;
}

std::optional<fs::path> installed_voice_pack() { return exists(voice_pack().filename); }

bool installed() { return installed_model() && installed_voice_pack(); }

std::vector<CatalogModel> needed() {
    std::vector<CatalogModel> out;
    if (!installed_model()) out.push_back(models()[0]);
    if (!installed_voice_pack()) out.push_back(voice_pack());
    return out;
}

std::u16string accent(const std::string& voice) {
    static const std::map<char, const char16_t*> accents = {
        {'a', u"American"}, {'b', u"British"},  {'e', u"Spanish"},    {'f', u"French"},  {'h', u"Hindi"},
        {'i', u"Italian"},  {'j', u"Japanese"}, {'p', u"Portuguese"}, {'z', u"Chinese"}};
    if (voice.empty()) return u"Other";
    const auto it = accents.find(voice[0]);
    return it == accents.end() ? u"Other" : it->second;
}

std::u16string title(const std::string& voice) {
    const auto underscore = voice.find('_');
    if (underscore != 2 || underscore + 1 >= voice.size()) return utf8_to_utf16(voice);
    std::string given = voice.substr(3);
    // Capitalised the way Swift's .capitalized does it: first letter of each word.
    bool start = true;
    for (auto& c : given) {
        if (c == '_' || c == ' ') {
            start = true;
            continue;
        }
        c = static_cast<char>(start ? std::toupper(static_cast<unsigned char>(c))
                                    : std::tolower(static_cast<unsigned char>(c)));
        start = false;
    }
    const auto acc = accent(voice);
    if (acc == u"Other") return utf8_to_utf16(given);
    return utf8_to_utf16(given) + u" — " + acc + u", " + (voice[1] == 'f' ? u"female" : u"male");
}

}  // namespace voice_catalog
}  // namespace nib::speech
