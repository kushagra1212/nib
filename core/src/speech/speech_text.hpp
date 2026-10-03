#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

// Text to phonemes, phonemes to batches, samples to trimmed samples: the pure
// half of read-aloud, ported from the Swift that was itself checked against the
// Python engine (phonemizer + kokoro_onnx) over Tests/Fixtures.
//
// Phoneme strings are UTF-32 here. espeak's IPA is full of multi-byte symbols
// -- ð, ɹ, ˈ -- and the Python reference counts and slices them as code
// points, so code points are the unit throughout.

namespace nib::speech {

// --- PhonemePunctuation -------------------------------------------------------

namespace punctuation {

enum class Position { begin, end, inside, alone };

struct Mark {
    int32_t line = 0;
    std::u32string text;
    Position position = Position::inside;
    friend bool operator==(const Mark& a, const Mark& b) {
        return a.line == b.line && a.text == b.text && a.position == b.position;
    }
};

// phonemizer's default marks, verbatim.
const std::u32string& default_marks();

std::vector<std::u32string> lines(const std::u32string& text);

struct Preserved {
    std::vector<std::u32string> chunks;
    std::vector<Mark> marks;
};
Preserved preserve(const std::u32string& text, const std::u32string& marks = default_marks());

std::vector<std::u32string> restore(std::vector<std::u32string> phonemized, std::vector<Mark> marks,
                                    const std::u32string& separator, bool strip);

}  // namespace punctuation

// --- Phonemizer ----------------------------------------------------------------

// Where phonemes come from: espeak in the app, recorded output in tests.
using PhonemeSource = std::function<std::u32string(const std::u32string& chunk)>;

namespace phonemizer {
// The phonemes a sentence becomes, filtered to the vocabulary and with
// whitespace collapsed, ready to tokenise.
std::u32string phonemes(const std::u32string& text, const PhonemeSource& source);
// The same before filtering, which is what phonemizer returns.
std::u32string phonemize(const std::u32string& text, const PhonemeSource& source);
// Cleans one chunk of espeak output: `ð_ə k_w_ˈɪ_k` -> `ðə kwˈɪk `.
std::u32string tidy(const std::u32string& line, bool strip = false);
}  // namespace phonemizer

// --- PhonemeChunker -----------------------------------------------------------

namespace chunker {
inline constexpr int32_t lead_in = 180;
std::vector<std::u32string> split(const std::u32string& phonemes, int32_t limit = 510);
std::vector<std::u32string> streaming(const std::u32string& phonemes, int32_t limit = 510,
                                      int32_t lead = lead_in);
double pause_after(const std::u32string& phonemes, double sentence, double clause);
}  // namespace chunker

// --- AudioTrim ----------------------------------------------------------------

namespace trim {
struct Range {
    size_t start = 0, end = 0;
};
// librosa's trim: frames 60 dB below the loudest are silence.
Range bounds(const std::vector<float>& samples, float top_db = 60, size_t frame_length = 2048,
             size_t hop_length = 512);
std::vector<float> trimmed(const std::vector<float>& samples);
}  // namespace trim

// Volume, clipped rather than scaled to fit: past full scale crackles.
std::vector<float> leveled(const std::vector<float>& samples, float volume);

// --- Encoding helpers -----------------------------------------------------------

std::u32string to_u32(const std::string& utf8);
std::string to_utf8(const std::u32string& text);
std::u32string to_u32(const std::u16string& text);
bool is_space(char32_t c);

}  // namespace nib::speech
