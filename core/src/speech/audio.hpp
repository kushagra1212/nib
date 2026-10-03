#pragma once
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

// Samples, in the formats the engines take: 16kHz mono float for whisper,
// 24kHz mono float out of Kokoro. Everything that crosses a rate goes through
// resample(), so there is one place where the conversion is right or wrong.

namespace nib::speech::audio {

inline constexpr int whisper_rate = 16'000;
inline constexpr int kokoro_rate = 24'000;

double duration(const std::vector<float>& samples, int rate = whisper_rate);
float peak(const std::vector<float>& samples);

// Whether nobody spoke. whisper invents words for silence -- four seconds of
// a silent file transcribes as "you" -- so silence is refused before the model
// is asked. -50 dB peak: far above digital silence (-91), far below speech.
inline constexpr float silence_threshold = 0.00316f;
bool silent(const std::vector<float>& samples);

// Band-limited resampling: a windowed-sinc low-pass, so 48kHz speech folded
// down to 16kHz does not alias its sibilants into the band whisper listens to.
std::vector<float> resample(const std::vector<float>& in, int from_rate, int to_rate);

// Interleaved channels down to one, by averaging.
std::vector<float> to_mono(const std::vector<float>& interleaved, int channels);

// A WAV file as 16kHz mono, whatever it was recorded at. PCM 16/24/32-bit and
// float32. Throws std::runtime_error on anything else.
std::vector<float> load_wav(const std::filesystem::path& file, int target_rate = whisper_rate);

// 16-bit PCM, because every player opens it.
void write_wav(const std::filesystem::path& file, const std::vector<float>& samples, int rate = whisper_rate);

}  // namespace nib::speech::audio
