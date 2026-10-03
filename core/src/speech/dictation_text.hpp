#pragma once
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

// The parts of dictation that are text: what whisper wrote that nobody said,
// the words it should expect, and the transcripts kept in case one is lost.

namespace nib::speech {

// Port of WhisperEngine.clean: removes whisper's descriptions of sounds --
// "[BLANK_AUDIO]", "(upbeat music)", "*coughs*" -- which dictation would
// otherwise type into somebody's document as though they were words.
std::u16string clean_transcript(const std::u16string& raw);

// Port of SpeechVocabulary: words whisper is primed with. The largest single
// improvement to accuracy -- "Hasura" arrives as "Azure" until it is listed.
namespace vocabulary {
const std::vector<std::u16string>& defaults();
inline constexpr size_t limit = 64;
std::filesystem::path file();
// The file's terms when it has any, the defaults when not. "#" lines are
// comments.
std::vector<std::u16string> terms();
std::vector<std::u16string> parse(const std::u16string& contents);
// "Terms used: a, b, c." -- prose primes better than a bare list, and the full
// stop stops the first spoken word gluing onto the last term.
std::optional<std::u16string> prompt(const std::vector<std::u16string>& terms);
std::filesystem::path create_file_if_needed();
std::u16string file_header();
}  // namespace vocabulary

// Port of DictationHistory: the last hundred transcripts, newest first.
class DictationHistory {
public:
    struct Entry {
        std::u16string text;
        int64_t unix_seconds = 0;
        // One line for a menu, the middle elided rather than the tail: the end
        // of a sentence is how two dictations are told apart.
        std::u16string label(size_t width = 60) const;
        friend bool operator==(const Entry& a, const Entry& b) {
            return a.text == b.text && a.unix_seconds == b.unix_seconds;
        }
    };

    static constexpr size_t limit = 100;

    void add(const std::u16string& text, int64_t unix_seconds = now());
    void clear() { entries_.clear(); }
    const std::vector<Entry>& entries() const { return entries_; }

    static std::filesystem::path file();
    static DictationHistory load(const std::filesystem::path& from = file());
    // Readable only by the user: it is a record of things said at a desk.
    void save(const std::filesystem::path& to = file()) const;

    static int64_t now();

private:
    std::vector<Entry> entries_;
};

}  // namespace nib::speech
