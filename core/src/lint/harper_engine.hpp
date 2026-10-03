#pragma once
#include <condition_variable>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <vector>
#include "lint/lsp_client.hpp"
#include "lint/suggestion.hpp"

namespace nib {

// Port of HarperEngine: drives harper-ls and turns its diagnostics into
// Suggestions.
//
// The handshake is not guesswork: harper-ls pulls its settings through
// workspace/configuration and refuses to lint at all if the reply lacks a
// top-level "harper-ls" key. It also drops didOpen if that arrives before it
// has answered initialize, so the handshake is sequenced.
//
// Thread-safe. Calls block; the app makes them from a worker thread.
class HarperEngine {
public:
    struct Settings {
        std::string dialect = "American";
        std::string diagnostic_severity = "hint";
        bool        isolate_english = false;
        int32_t     max_file_length = 120'000;
        // Where harper keeps words added to its dictionary. Its defaults are
        // under the roaming profile and do not exist until written, which it
        // reports as an error on every start; nib points them at its own
        // folder and creates them.
        std::string user_dictionary;
        std::string file_dictionaries;
        nlohmann::json payload() const;
    };

    explicit HarperEngine(std::u16string executable, Settings settings = {});
    ~HarperEngine();

    bool running() const;
    void start();
    void stop();

    // Suggestions for `text`, without replacements -- fetched one request per
    // diagnostic, a 2000-word document produces ~430 of them, and fanning those
    // out over one pipe took 5.7s. Call with_replacements for what is shown.
    std::vector<Suggestion> lint(const std::u16string& text, int32_t timeout_ms = 10'000);

    std::vector<std::u16string> replacements(const Suggestion& suggestion);

    // Fills in replacements, then re-runs the filter: its plausibility half
    // needs them, and skipping it let "bugs" -> "thing" through.
    std::vector<Suggestion> with_replacements(const std::vector<Suggestion>& suggestions,
                                              const std::u16string& text);

private:
    nlohmann::json await_diagnostics(int32_t timeout_ms, const std::function<void()>& send);
    void deliver(nlohmann::json diagnostics, std::optional<int32_t> version);

    std::u16string executable_;
    Settings settings_;
    LspClient client_;
    bool started_ = false;
    int32_t version_ = 0;

    std::mutex call_lock_;  // one lint at a time: one document

    std::mutex wait_lock_;
    std::condition_variable waited_;
    bool armed_ = false;
    int32_t expected_version_ = 0;
    std::optional<nlohmann::json> delivered_;

    std::mutex index_lock_;
    // Raw diagnostics from the last lint, by suggestion id, so replacement
    // text can be fetched on demand.
    std::map<uint64_t, std::pair<nlohmann::json, nlohmann::json>> index_;
};

}  // namespace nib
