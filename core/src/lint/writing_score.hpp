#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"

namespace nib {

// Port of WritingScore: how much is wrong with a piece of writing, as a number.
//
// Counted by harper rather than judged by the model, deliberately. harper is
// deterministic, answers in about 30ms, and every point it takes off is an
// underline you can click to see the rule.
struct WritingScore {
    enum class Standing { clean, few, many };

    // Below this, a rate is arithmetic rather than information.
    static constexpr int32_t minimum_words_for_rate = 20;

    int32_t issues = 0;
    int32_t words = 0;

    WritingScore(int32_t issues, int32_t words);
    WritingScore(const std::vector<Suggestion>& suggestions, const std::u16string& text);

    // Errors per hundred words.
    double rate() const;
    // "3 mistakes · 4.2 per 100 words", or "no mistakes in 13 words".
    std::u16string summary() const;
    // Short enough for a cramped row.
    std::u16string compact() const;
    Standing standing() const;

    // Words, counted the way a person would: runs of non-space.
    static int32_t word_count(const std::u16string& text);

    friend bool operator==(const WritingScore& a, const WritingScore& b) {
        return a.issues == b.issues && a.words == b.words;
    }
};

}  // namespace nib
