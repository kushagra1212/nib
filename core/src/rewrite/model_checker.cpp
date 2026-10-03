#include "rewrite/model_checker.hpp"

#include <cstdio>
#include "lint/word_diff.hpp"
#include "support/log.hpp"
#include "text/sentence_split.hpp"
#include "text/unicode.hpp"

namespace nib {
namespace {

std::u16string mode_key(RewriteMode mode, const std::u16string& text) {
    return std::u16string(rewrite_mode::raw_value(mode)) + u"|" + text;
}

std::string mode_name(RewriteMode mode) { return utf16_to_utf8(rewrite_mode::raw_value(mode)); }

u16view view_of(const std::u16string& s) {
    return u16view(reinterpret_cast<const uint16_t*>(s.data()), static_cast<int32_t>(s.size()));
}

}  // namespace

bool ModelChecker::is_light_enough_for_live_use(const std::filesystem::path& model) {
    std::error_code ec;
    const auto size = std::filesystem::file_size(model, ec);
    return !ec && static_cast<int64_t>(size) <= live_model_size_limit;
}

ModelChecker::ModelChecker(Rewriter& rewriter, int32_t max_length, std::string locale)
    : rewriter_(rewriter), max_length_(max_length), locale_(std::move(locale)) {}

bool ModelChecker::cached(const std::u16string& key, std::u16string& out) {
    std::lock_guard lock(cache_lock_);
    const auto it = cache_.find(key);
    if (it == cache_.end()) return false;
    out = it->second;
    return true;
}

void ModelChecker::remember(const std::u16string& key, const std::u16string& value) {
    std::lock_guard lock(cache_lock_);
    if (cache_.insert_or_assign(key, value).second) cache_order_.push_back(key);
    while (cache_order_.size() > cache_limit) {
        cache_.erase(cache_order_.front());
        cache_order_.pop_front();
    }
}

std::vector<Suggestion> ModelChecker::check(const std::u16string& text) {
    const auto t = trimmed(text);
    if (t.empty() || grapheme_count(t) > max_length_) return {};

    std::u16string corrected;
    if (!cached(t, corrected)) {
        try {
            corrected = rewriter_.rewrite(t, RewriteMode::fix_grammar);
        } catch (const RewriteException&) {
            return {};
        }
        if (corrected.empty()) return {};
        remember(t, corrected);
    }

    if (!rewrite_text::is_trustworthy(t, corrected)) return {};
    if (rewrite_text::drops_content(t, corrected)) return {};
    if (rewrite_text::flips_question(t, corrected)) return {};
    return word_diff::suggestions(text, corrected, u"Suggested correction");
}

std::optional<std::u16string> ModelChecker::rewrite_quietly(const std::u16string& text,
                                                            RewriteMode mode) {
    const auto key = mode_key(mode, text);
    std::u16string hit;
    if (cached(key, hit)) return hit;
    std::u16string result;
    try {
        result = rewriter_.rewrite(text, mode);
    } catch (const RewriteException&) {
        return std::nullopt;
    }
    if (result.empty()) return std::nullopt;
    remember(key, result);
    return result;
}

std::vector<Suggestion> ModelChecker::clarity(const std::u16string& text, int32_t limit) {
    const auto found = sentences(view_of(text), 5, locale_.empty() ? nullptr : locale_.c_str());
    std::vector<Suggestion> out;
    int32_t taken = 0;
    for (const auto& sentence : found) {
        if (taken++ >= limit) break;
        // Each guard is a different reason to say nothing, and from outside
        // they all look the same. The log says which fired -- by length only.
        const std::string tag = "clarity [" + std::to_string(sentence.text.size()) + " units]";
        const auto rewritten = rewrite_quietly(sentence.text, RewriteMode::clearer);
        if (!rewritten) {
            log::write(tag + ": model gave nothing");
            continue;
        }
        if (*rewritten == sentence.text) {
            log::write(tag + ": unchanged");
            continue;
        }
        const double similarity = rewrite_text::character_similarity(
            lowercased(sentence.text), lowercased(*rewritten));
        char line[96];
        std::snprintf(line, sizeof line, ": similarity %.2f, dropped run %d", similarity,
                      rewrite_text::longest_dropped_run(sentence.text, *rewritten));
        log::write(tag + line);

        // May restructure, so the tight inline gate does not apply; it only
        // has to remain about the same sentence, and be worth interrupting for.
        if (similarity < 0.35 || similarity > 0.97) continue;
        // A tail that no longer lines up is only a truncation if the rewrite
        // also stops mid-sentence; clarity reorders endings constantly.
        if (rewrite_text::dropped_tail(sentence.text, *rewritten) >= 3
            && rewrite_text::looks_unfinished(*rewritten)) {
            log::write(tag + ": truncated the ending");
            continue;
        }
        if (rewrite_text::flips_question(sentence.text, *rewritten)) {
            log::write(tag + ": turned a question into a statement");
            continue;
        }

        Suggestion s;
        s.kind = SuggestionKind::clarity;
        s.source = SuggestionSource::model;
        s.range = sentence.range;
        s.message = u"This could read more clearly";
        s.replacements = {*rewritten};
        out.push_back(std::move(s));
    }
    return out;
}

RewriteOutcome ModelChecker::rewrite_selection(const std::u16string& text, RewriteMode mode) {
    const auto key = mode_key(mode, text);
    std::u16string hit;
    if (cached(key, hit)) {
        return hit == text ? RewriteOutcome::unchanged() : RewriteOutcome::rewritten(hit);
    }
    const std::u16string result = rewriter_.rewrite(text, mode);

    // A sentence that stops early is wrong in every mode. Both conditions: the
    // tail count finds an ending that does not line up; only the second says
    // it ended because the model stopped rather than because it rephrased.
    if (rewrite_text::dropped_tail(text, result) >= 3 && rewrite_text::looks_unfinished(result)) {
        log::write("rewrite truncated the ending, mode=" + mode_name(mode));
        return RewriteOutcome::refused(u"that rewrite cut off the ending");
    }
    if (rewrite_text::flips_question(text, result)) {
        log::write("rewrite turned a question into a statement, mode=" + mode_name(mode));
        return RewriteOutcome::refused(u"that rewrite answered your question instead of rewriting it");
    }
    if (!rewrite_mode::may_restructure(mode)
        && rewrite_text::drops_content(text, result, max_dropped_run)) {
        log::write("rewrite dropped content, mode=" + mode_name(mode) + " run="
                   + std::to_string(rewrite_text::longest_dropped_run(text, result)));
        return RewriteOutcome::refused(u"that rewrite dropped part of what you wrote");
    }
    remember(key, result);
    return trimmed(result) == trimmed(text) ? RewriteOutcome::unchanged()
                                            : RewriteOutcome::rewritten(result);
}

}  // namespace nib
