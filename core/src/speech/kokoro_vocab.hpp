#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace nib::kokoro {

// The phoneme table Kokoro was trained with: each sound symbol and the number
// the model expects for it.
const std::vector<std::pair<char32_t, int32_t>>& vocab();
extern const char* const vocab_source_digest;

// Longest phoneme sequence the model accepts.
inline constexpr int32_t max_phonemes = 510;

std::optional<int32_t> token_for(char32_t symbol);

// Port of KokoroTokenizer: maps each symbol through the table, dropping any it
// does not know -- what the Python does. Per code point, as Python's len() and
// iteration over a str are. Throws std::length_error past max_phonemes.
std::vector<int32_t> tokenize(const std::u32string& phonemes);
std::u32string unknown_symbols(const std::u32string& phonemes);

}  // namespace nib::kokoro
