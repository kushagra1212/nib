#include "lint/writing_score.hpp"

#include <algorithm>
#include <cstdio>
#include "text/unicode.hpp"

namespace nib {
namespace {

// %.1f below ten, %.0f above, as String(format:) did.
std::u16string formatted(double value) {
    char buf[32];
    std::snprintf(buf, sizeof buf, value < 10 ? "%.1f" : "%.0f", value);
    return utf8_to_utf16(buf);
}

}  // namespace

WritingScore::WritingScore(int32_t i, int32_t w)
    : issues(std::max(0, i)), words(std::max(0, w)) {}

WritingScore::WritingScore(const std::vector<Suggestion>& suggestions,
                           const std::u16string& text)
    : WritingScore(static_cast<int32_t>(suggestions.size()), word_count(text)) {}

double WritingScore::rate() const {
    if (words <= 0) return 0;
    return static_cast<double>(issues) * 100.0 / static_cast<double>(words);
}

std::u16string WritingScore::summary() const {
    if (words <= 0) return {};
    if (issues <= 0) return u"no mistakes in " + to_u16(words) + u" words";

    const std::u16string plural = issues == 1 ? u"mistake" : u"mistakes";
    // Below twenty words one mistake in six reads as "17 per 100", a verdict
    // on the writer rather than on one short sentence.
    if (words < minimum_words_for_rate) return to_u16(issues) + u" " + plural;
    return to_u16(issues) + u" " + plural + u" · " + formatted(rate()) + u" per 100 words";
}

std::u16string WritingScore::compact() const {
    if (words <= 0) return {};
    return issues == 0 ? u"clean" : to_u16(issues);
}

WritingScore::Standing WritingScore::standing() const {
    if (issues == 0) return Standing::clean;
    if (words < minimum_words_for_rate) return issues <= 1 ? Standing::few : Standing::many;
    return rate() < 8 ? Standing::few : Standing::many;
}

int32_t WritingScore::word_count(const std::u16string& text) {
    return static_cast<int32_t>(split_whitespace(text).size());
}

}  // namespace nib
