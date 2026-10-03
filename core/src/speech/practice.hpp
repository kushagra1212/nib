#pragma once
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// Practice: what a spoken answer sounded like, measured rather than
// remembered. Pure -- segments in, numbers and Markdown out.

namespace nib::speech {

// One stretch of speech whisper decoded, and where it sat in the recording.
struct SpokenSegment {
    std::u16string text;
    double start = 0;  // seconds
    double end = 0;
    double duration() const { return end > start ? end - start : 0; }
};

// Port of DeliveryReport. It does not grade content; this is the part a
// machine can count, and the part you cannot hear in your own voice.
struct DeliveryReport {
    double duration = 0;
    int32_t word_count = 0;
    double pace = 0;  // words per minute, silence included
    std::vector<std::pair<std::u16string, int32_t>> fillers;  // most first
    int32_t filler_total = 0;
    std::vector<std::pair<double, double>> long_pauses;  // (at, length)
    int32_t longest_sentence = 0;
    bool trails_off = false;

    static constexpr double pause_threshold = 2.0;
    static constexpr double comfortable_low = 130, comfortable_high = 165;

    DeliveryReport(const std::vector<SpokenSegment>& segments, double duration);

    std::u16string pace_verdict() const;
    double filler_rate() const;  // per minute
    std::u16string filler_verdict() const;

    static std::u16string normalise(const std::u16string& text);
    static std::vector<std::u16string> sentences(const std::u16string& text);
    static int32_t occurrences(const std::u16string& needle, const std::u16string& haystack);
};

namespace practice {
// The take as Markdown: numbers above the words, because someone reviewing a
// take wants "you said um fourteen times" first.
std::u16string markdown(const std::vector<SpokenSegment>& segments, const DeliveryReport& report,
                        const std::u16string& audio_name, int64_t unix_seconds);
std::vector<std::u16string> advice(const DeliveryReport& report);
std::u16string time(double seconds);
}  // namespace practice

}  // namespace nib::speech
