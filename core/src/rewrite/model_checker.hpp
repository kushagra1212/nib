#pragma once
#include <cstdint>
#include <deque>
#include <filesystem>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"
#include "rewrite/rewrite_engine.hpp"

namespace nib {

// Port of ModelChecker: suggestions from the model rewriting the text, diffed
// back against the original.
//
// Harper marks spelling within milliseconds; this runs afterwards on a longer
// pause and supersedes those marks once ready. Every rewrite passes gates
// before it is trusted, because a small model asked to fix grammar sometimes
// answers the text, summarises it, or cuts off its ending.
class ModelChecker {
public:
    // Largest model that may run on every typing pause. Work nobody requested
    // has to stay cheap; above this Harper alone underlines live, and the big
    // model still answers the four buttons.
    static constexpr int64_t live_model_size_limit = 1'500'000'000;
    static bool is_light_enough_for_live_use(const std::filesystem::path& model);

    // The longest run of the original a non-restructuring rewrite may drop.
    static constexpr int32_t max_dropped_run = 3;

    explicit ModelChecker(Rewriter& rewriter, int32_t max_length = 600,
                          std::string locale = {});

    // Inline corrections for `text`, or none if the model cannot help.
    std::vector<Suggestion> check(const std::u16string& text);

    // One clarity suggestion per sentence that could read better.
    std::vector<Suggestion> clarity(const std::u16string& text, int32_t limit = 4);

    // A selection the user explicitly asked about. Throws RewriteException.
    RewriteOutcome rewrite_selection(const std::u16string& text, RewriteMode mode);

private:
    bool cached(const std::u16string& key, std::u16string& out);
    void remember(const std::u16string& key, const std::u16string& value);
    std::optional<std::u16string> rewrite_quietly(const std::u16string& text, RewriteMode mode);

    Rewriter& rewriter_;
    int32_t max_length_;
    std::string locale_;

    std::mutex cache_lock_;
    std::map<std::u16string, std::u16string> cache_;
    std::deque<std::u16string> cache_order_;
    static constexpr size_t cache_limit = 40;
};

}  // namespace nib
