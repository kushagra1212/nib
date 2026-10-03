#include "lint/harper_engine.hpp"

#include <chrono>
#include "lint/suggestion_filter.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"

namespace nib {
namespace {

using json = nlohmann::json;

// harper-ls keys documents by URI. nib only ever lints one scratch buffer,
// which never exists on disk.
constexpr const char* document_uri = "file:///C:/nib/nib-buffer.md";
constexpr const char* root_uri = "file:///C:/nib";

}  // namespace

json HarperEngine::Settings::payload() const {
    return {
        {"linters", json::object()},
        {"codeActions", {{"forceStable", false}}},
        {"markdown", {{"IgnoreLinkTitle", false}}},
        {"dialect", dialect},
        {"diagnosticSeverity", diagnostic_severity},
        {"isolateEnglish", isolate_english},
        {"maxFileLength", max_file_length},
    };
}

HarperEngine::HarperEngine(std::u16string executable, Settings settings)
    : executable_(std::move(executable)), settings_(std::move(settings)) {
    client_.on_request = [this](const std::string& method, const json&) -> json {
        // One settings object per requested item; harper only ever asks for
        // one, but answering per item keeps nib spec-correct.
        if (method == "workspace/configuration") {
            return json::array({{{"harper-ls", settings_.payload()}}});
        }
        return json();
    };
    client_.on_notification = [this](const std::string& method, const json& params) {
        if (method != "textDocument/publishDiagnostics" || !params.is_object()) return;
        if (params.value("uri", std::string()) != document_uri) return;
        const auto diagnostics = params.find("diagnostics");
        if (diagnostics == params.end() || !diagnostics->is_array()) return;
        const auto version = params.find("version");
        deliver(*diagnostics, version != params.end() && version->is_number_integer()
                                  ? std::optional<int32_t>(version->get<int32_t>())
                                  : std::nullopt);
    };
    client_.on_exit = [this](uint32_t code) {
        log::write("harper-ls exited with " + std::to_string(code));
        std::lock_guard lock(wait_lock_);
        started_ = false;
        armed_ = false;
        waited_.notify_all();
    };
}

HarperEngine::~HarperEngine() { stop(); }

bool HarperEngine::running() const { return client_.running(); }

void HarperEngine::start() {
    if (started_ && client_.running()) return;
    client_.stop();
    client_.start(executable_, {u"--stdio"});

    client_.request("initialize", {
        {"processId", platform::current_pid()},
        {"rootUri", root_uri},
        {"workspaceFolders", json::array({{{"uri", root_uri}, {"name", "nib"}}})},
        {"capabilities", {
            {"textDocument", {
                {"publishDiagnostics", json::object()},
                {"codeAction", json::object()},
                {"synchronization", {{"dynamicRegistration", false}}},
            }},
            {"workspace", {{"configuration", true}}},
        }},
    }, 15'000);
    client_.notify("initialized", json::object());
    started_ = true;

    // harper answers didOpen with its own publishDiagnostics -- an empty array
    // for an empty document, landing late enough to be mistaken for the answer
    // to the first real lint, which then reports a page of errors as clean.
    // Drained here.
    try {
        await_diagnostics(5'000, [&] {
            client_.notify("textDocument/didOpen", {
                {"textDocument", {{"uri", document_uri}, {"languageId", "markdown"},
                                  {"version", 0}, {"text", ""}}},
            });
        });
    } catch (const LspError&) {
        // No answer for an empty document is not a failure.
    }
}

void HarperEngine::stop() {
    client_.stop();
    started_ = false;
}

std::vector<Suggestion> HarperEngine::lint(const std::u16string& text, int32_t timeout_ms) {
    std::lock_guard call(call_lock_);
    if (!started_ || !client_.running()) start();

    ++version_;
    const std::string utf8 = utf16_to_utf8(text);
    const json diagnostics = await_diagnostics(timeout_ms, [&] {
        client_.notify("textDocument/didChange", {
            {"textDocument", {{"uri", document_uri}, {"version", version_}}},
            {"contentChanges", json::array({{{"text", utf8}}})},
        });
    });

    const PositionMapper mapper(text);
    std::vector<Suggestion> suggestions;
    std::map<uint64_t, std::pair<json, json>> index;
    for (const auto& diagnostic : diagnostics) {
        if (!diagnostic.is_object()) continue;
        const auto lsp_range = diagnostic.find("range");
        const auto message = diagnostic.find("message");
        if (lsp_range == diagnostic.end() || message == diagnostic.end() || !message->is_string()) {
            continue;
        }
        const auto range = mapper.range(*lsp_range);
        if (!range) continue;
        Suggestion s;
        s.range = *range;
        s.message = utf8_to_utf16(message->get<std::string>());
        index[s.id] = {diagnostic, *lsp_range};
        suggestions.push_back(std::move(s));
    }
    {
        std::lock_guard lock(index_lock_);
        index_ = std::move(index);
    }
    // harper matches against a word list, so it "corrects" acronyms, type
    // names and product names into nonsense. Filtered before anything shows.
    return suggestion_filter::apply(suggestions, text);
}

std::vector<std::u16string> HarperEngine::replacements(const Suggestion& suggestion) {
    std::pair<json, json> entry;
    {
        std::lock_guard lock(index_lock_);
        const auto it = index_.find(suggestion.id);
        if (it == index_.end()) return {};
        entry = it->second;
    }
    json response;
    try {
        response = client_.request("textDocument/codeAction", {
            {"textDocument", {{"uri", document_uri}}},
            {"range", entry.second},
            {"context", {{"diagnostics", json::array({entry.first})}}},
        }, 5'000);
    } catch (const LspError&) {
        return {};
    }
    if (!response.is_array()) return {};

    std::vector<std::u16string> out;
    for (const auto& action : response) {
        // Skip "Add to dictionary" / "Ignore": they carry no edit.
        if (!action.is_object()) continue;
        const auto edit = action.find("edit");
        if (edit == action.end() || !edit->is_object()) continue;
        const auto changes = edit->find("changes");
        if (changes == edit->end() || !changes->is_object()) continue;
        const auto edits = changes->find(document_uri);
        if (edits == changes->end() || !edits->is_array() || edits->size() != 1) continue;
        const auto text = (*edits)[0].find("newText");
        if (text == (*edits)[0].end() || !text->is_string()) continue;
        out.push_back(utf8_to_utf16(text->get<std::string>()));
    }
    return out;
}

std::vector<Suggestion> HarperEngine::with_replacements(
    const std::vector<Suggestion>& suggestions, const std::u16string& text) {
    std::vector<Suggestion> out;
    out.reserve(suggestions.size());
    for (const auto& s : suggestions) {
        Suggestion filled = s;
        filled.replacements = replacements(s);
        out.push_back(std::move(filled));
    }
    return suggestion_filter::apply(out, text);
}

json HarperEngine::await_diagnostics(int32_t timeout_ms, const std::function<void()>& send) {
    // Armed before sending, so a fast reply cannot arrive before anything is
    // listening for it.
    {
        std::lock_guard lock(wait_lock_);
        armed_ = true;
        expected_version_ = version_;
        delivered_.reset();
    }
    send();
    std::unique_lock lock(wait_lock_);
    const bool got = waited_.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                      [&] { return delivered_.has_value() || !armed_; });
    armed_ = false;
    if (!got || !delivered_) {
        throw LspError(LspError::Kind::timed_out, "timed out waiting for publishDiagnostics");
    }
    json out = std::move(*delivered_);
    delivered_.reset();
    return out;
}

void HarperEngine::deliver(json diagnostics, std::optional<int32_t> version) {
    std::lock_guard lock(wait_lock_);
    // Unarmed means nobody asked: a stray publish for a lint that already
    // timed out. Dropped, so it cannot answer the next one. A version that is
    // not the one just sent is the same thing arriving late.
    if (!armed_) return;
    if (version && *version != expected_version_) return;
    delivered_ = std::move(diagnostics);
    waited_.notify_all();
}

}  // namespace nib
