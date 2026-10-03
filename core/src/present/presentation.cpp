#include "present/presentation.hpp"

#include <algorithm>
#include "lint/word_diff.hpp"
#include "text/unicode.hpp"

namespace nib::present {
namespace {

bool overlaps(nib_range a, nib_range b) {
    return std::max(a.location, b.location) < std::min(range_end(a), range_end(b));
}

std::vector<std::u16string> words(const std::u16string& text) {
    std::vector<std::u16string> out;
    for (auto& t : word_diff::tokenize(text)) out.push_back(std::move(t.text));
    return out;
}

}  // namespace

std::u16string plain_text(const std::vector<Run>& runs) {
    std::u16string out;
    for (const auto& r : runs) out += r.text;
    return out;
}

std::vector<Run> diff(const std::u16string& original, const std::u16string& rewritten) {
    const auto before = words(original);
    const auto after = words(rewritten);
    const auto kept = word_diff::longest_common_subsequence(before, after);

    std::vector<Run> out;
    auto append = [&](const std::u16string& word, Style style) {
        if (!out.empty()) out.push_back({u" ", Style::plain});
        out.push_back({word, style});
    };
    size_t i = 0, j = 0, k = 0;
    while (i < before.size() || j < after.size()) {
        const std::u16string* common = k < kept.size() ? &kept[k] : nullptr;
        // Anything before the next surviving word was taken out...
        if (i < before.size() && (!common || before[i] != *common)) {
            append(before[i++], Style::removed);
            continue;
        }
        // ...and anything before it on the other side was put in.
        if (j < after.size() && (!common || after[j] != *common)) {
            append(after[j++], Style::added);
            continue;
        }
        if (i >= before.size() || j >= after.size()) break;
        append(after[j], Style::kept);
        ++i;
        ++j;
        ++k;
    }
    return out;
}

std::vector<Run> fix_card(const Suggestion& s, const std::u16string& replacement,
                          const std::u16string& context) {
    const int32_t n = static_cast<int32_t>(context.size());
    const nib_range r = s.range;
    if (r.location < 0 || r.length < 0 || range_end(r) > n) return {{replacement, Style::added}};

    std::vector<Run> out;
    // A short run-up so the edit reads as part of the sentence, cut at a word
    // boundary: slicing mid-word reads as a second error.
    const int32_t lead_start = std::max(0, r.location - 28);
    std::u16string lead = context.substr(static_cast<size_t>(lead_start),
                                         static_cast<size_t>(r.location - lead_start));
    if (lead_start > 0) {
        const auto space = lead.find(u' ');
        if (space != std::u16string::npos) lead = u"…" + lead.substr(space);
    }
    if (!lead.empty()) out.push_back({lead, Style::plain});

    out.push_back({context.substr(static_cast<size_t>(r.location), static_cast<size_t>(r.length)),
                   Style::removed});
    out.push_back({u" ", Style::plain});
    out.push_back({replacement, Style::added});

    const int32_t tail_end = std::min(n, range_end(r) + 24);
    std::u16string tail = context.substr(static_cast<size_t>(range_end(r)),
                                         static_cast<size_t>(tail_end - range_end(r)));
    if (tail_end < n) {
        const auto space = tail.rfind(u' ');
        if (space != std::u16string::npos) tail = tail.substr(0, space) + u"…";
    }
    if (!tail.empty()) out.push_back({tail, Style::plain});
    return out;
}

std::vector<Suggestion> merge(const std::vector<Suggestion>& harper,
                              const std::vector<Suggestion>& model, const std::u16string& text) {
    std::vector<Suggestion> out = harper;
    for (const auto& candidate : model) {
        const auto excerpt = candidate.excerpt(text).value_or(u"");
        if (static_cast<int32_t>(word_diff::tokenize(excerpt).size()) > max_correction_words) continue;
        // Harper already flagged this span, and its range is tighter.
        const bool taken = std::any_of(harper.begin(), harper.end(), [&](const Suggestion& h) {
            return overlaps(h.range, candidate.range);
        });
        if (!taken) out.push_back(candidate);
    }
    std::stable_sort(out.begin(), out.end(), [](const Suggestion& a, const Suggestion& b) {
        return a.range.location < b.range.location;
    });
    return out;
}

std::vector<Suggestion> settle_clarity(const std::vector<Suggestion>& corrections,
                                       const std::vector<Suggestion>& clarity) {
    // Corrections stay first so hit-testing prefers them: hovering a marked
    // word offers its fix, hovering elsewhere in a clean sentence the rewrite.
    std::vector<Suggestion> out = corrections;
    for (const auto& sentence : clarity) {
        const bool blocked = std::any_of(corrections.begin(), corrections.end(), [&](const Suggestion& c) {
            return overlaps(c.range, sentence.range);
        });
        if (!blocked) out.push_back(sentence);
    }
    return out;
}

std::vector<Mark> place(const std::vector<Mark>& marks, const Rect& field) {
    std::vector<Mark> out;
    for (const auto& mark : marks) {
        Mark placed{mark.suggestion, {}};
        for (const auto& r : mark.rects) {
            const Rect clipped{std::max(r.left, field.left), std::max(r.top, field.top),
                               std::min(r.right, field.right), std::min(r.bottom, field.bottom)};
            if (clipped.width() <= 0 || clipped.height() <= 0) continue;
            placed.rects.push_back({clipped.left - field.left, clipped.top - field.top,
                                    clipped.right - field.left, clipped.bottom - field.top});
        }
        if (!placed.rects.empty()) out.push_back(std::move(placed));
    }
    return out;
}

std::u16string dismissal_key(const Suggestion& s, const std::u16string& text) {
    return s.excerpt(text).value_or(u"") + u"|" + s.message;
}

bool worth_rewriting(const std::u16string& selection) {
    const auto t = trimmed(selection);
    return grapheme_count(t) >= 12 && word_diff::tokenize(t).size() >= 3;
}

std::u16string failure_message(const RewriteError& error) {
    using K = RewriteError::Kind;
    switch (error.kind) {
    case K::model_missing:   return u"no model installed";
    case K::server_failed:   return u"model would not start";
    case K::bad_response:    return u"model gave no answer";
    // The one failure with an obvious cause and an obvious fix.
    case K::out_of_memory:   return u"not enough memory -- try again in a moment";
    case K::rejected:        return u"model refused (" + to_u16(error.status) + u")";
    case K::truncated:       return u"selection too long -- rewrite a paragraph at a time";
    // llama-server sleeps after two idle minutes, so the first rewrite after a
    // pause waits on a cold start; that is not the model being missing.
    case K::timed_out:       return u"model took too long -- try again";
    case K::connection_lost: return u"model server stopped -- try again";
    }
    return u"model unavailable";
}

}  // namespace nib::present
