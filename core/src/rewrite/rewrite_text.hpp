#pragma once
#include <cstdint>
#include <string>
#include <variant>

// The parts of RewriteEngine and ModelChecker that are pure functions of text,
// split out so they can be tested without a model.

namespace nib {

// Port of RewriteError.
struct RewriteError {
    enum class Kind {
        model_missing,
        server_failed,
        bad_response,
        rejected,       // the server answered, and said no
        out_of_memory,  // the GPU or RAM could not hold the model
        truncated,      // ran out of tokens twice: selection too long
    };
    Kind           kind = Kind::bad_response;
    std::u16string detail;  // path, reason, or server message
    int32_t        status = 0;

    std::u16string description() const;
};

// Port of RewriteOutcome. Three answers rather than one string, because a
// refusal returned as the original text read as "looks good" in green over a
// sentence whose rewrite had just been rejected for changing the meaning.
struct RewriteOutcome {
    enum class Kind { rewritten, unchanged, refused };
    Kind           kind = Kind::unchanged;
    std::u16string text;    // the rewrite, or the refusal's reason

    static RewriteOutcome rewritten(std::u16string t) { return {Kind::rewritten, std::move(t)}; }
    static RewriteOutcome unchanged() { return {Kind::unchanged, {}}; }
    static RewriteOutcome refused(std::u16string why) { return {Kind::refused, std::move(why)}; }

    // The text to apply, or null when there is nothing to apply.
    const std::u16string* applicable() const {
        return kind == Kind::rewritten ? &text : nullptr;
    }
    friend bool operator==(const RewriteOutcome& a, const RewriteOutcome& b) {
        return a.kind == b.kind && a.text == b.text;
    }
};

namespace rewrite_text {

// The system message, not in `text` but occupying the window. Generous:
// undercounting spends the difference on a truncated reply.
inline constexpr int32_t prompt_overhead = 256;

// How much of the context window is left for the reply.
int32_t headroom(const std::u16string& text, int32_t context);

// Caps generation to a little more than the input, under three ceilings:
// policy (`limit`), physics (`headroom`) and the estimate.
int32_t token_budget(const std::u16string& text, int32_t limit, int32_t context = 2048);

// Strips the scaffolding small models add despite being told not to.
std::u16string clean(const std::u16string& raw);

// Turns an error response into something worth reading. `body` and `log` are
// UTF-8 as they came off the wire and out of llama-server's stderr.
RewriteError failure(int32_t status, const std::string& body, const std::string& log = {});

// --- ModelChecker's gates ---------------------------------------------------

// 1.0 for identical strings, approaching 0 as they diverge.
double character_similarity(const std::u16string& a, const std::u16string& b);

// Rejects a rewrite that strayed too far to be a correction.
bool is_trustworthy(const std::u16string& original, const std::u16string& corrected);

// The longest stretch of consecutive original words missing from the rewrite.
int32_t longest_dropped_run(const std::u16string& original, const std::u16string& corrected);
bool drops_content(const std::u16string& original, const std::u16string& corrected,
                   int32_t limit = 3);

// How many words were dropped from the very end.
int32_t dropped_tail(const std::u16string& original, const std::u16string& corrected);

// Whether a rewrite stops mid-sentence.
bool looks_unfinished(const std::u16string& text);

// Whether a rewrite turned a question into a statement.
bool flips_question(const std::u16string& original, const std::u16string& corrected);

}  // namespace rewrite_text
}  // namespace nib
