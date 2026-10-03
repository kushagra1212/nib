#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"
#include "rewrite/rewrite_mode.hpp"
#include "rewrite/rewrite_text.hpp"

// The decisions behind what nib shows, apart from how it is drawn: which marks
// survive a merge, what a diff looks like, what a failure is called. Both
// platforms draw the same answers, and every one of them was a bug on macOS
// before it was a rule, so they are tested here rather than per toolkit.

namespace nib::present {

// --- Text with styles ---------------------------------------------------------

enum class Style { plain, removed, added, kept };

struct Run {
    std::u16string text;
    Style style = Style::plain;
    friend bool operator==(const Run& a, const Run& b) { return a.text == b.text && a.style == b.style; }
};

std::u16string plain_text(const std::vector<Run>& runs);

// Port of DiffText: a rewrite word by word, removed words struck, added words
// underlined. Case-sensitive -- "chatgpt" to "ChatGPT" is a correction nib
// offers, and folding case would show it as no change at all.
std::vector<Run> diff(const std::u16string& original, const std::u16string& rewritten);

// Port of FixCard.diffText: "...lead old new tail..." with a little of the
// sentence either side, cut at word boundaries.
std::vector<Run> fix_card(const Suggestion& suggestion, const std::u16string& replacement,
                          const std::u16string& context);

// --- Live checking --------------------------------------------------------------

// Widest a model edit may be and still count as a correction.
inline constexpr int32_t max_correction_words = 4;

// Port of LiveChecker.merge: harper's precise marks are kept; the model adds
// only what harper missed, and only where it points at something small.
std::vector<Suggestion> merge(const std::vector<Suggestion>& harper,
                              const std::vector<Suggestion>& model, const std::u16string& text);

// Clarity waits for the errors in its sentence to be fixed: a rewrite of a
// sentence that still has typos is built on the typos.
std::vector<Suggestion> settle_clarity(const std::vector<Suggestion>& corrections,
                                       const std::vector<Suggestion>& clarity);

// How many marks may be drawn at once. Each costs a bounds call into the app
// being typed in, which is what stalls it.
inline constexpr size_t max_drawn_marks = 60;
// Fields longer than this are not checked -- and say so.
inline constexpr size_t max_live_length = 20'000;

struct Rect {
    int32_t left = 0, top = 0, right = 0, bottom = 0;
    int32_t width() const { return right - left; }
    int32_t height() const { return bottom - top; }
    friend bool operator==(const Rect& a, const Rect& b) {
        return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
    }
};

struct Mark {
    Suggestion suggestion;
    std::vector<Rect> rects;
};

// Port of MarkPlacement: clips each rect to the field -- a scrolled-away line
// still reports bounds -- and moves it into the overlay's coordinates.
std::vector<Mark> place(const std::vector<Mark>& marks, const Rect& field);

// Key for a dismissed suggestion: the word plus the message, because a re-lint
// mints new ids and a dismissal keyed on id would come straight back.
std::u16string dismissal_key(const Suggestion& s, const std::u16string& text);

// A selection worth offering a rewrite for: 12 characters, three words.
bool worth_rewriting(const std::u16string& selection);

// --- Rewrite bar ----------------------------------------------------------------

// What the bar tries unasked, in order, stopping at the first that changes
// anything. Least invasive first; Shorter is never automatic.
inline constexpr std::array<RewriteMode, 3> auto_order{RewriteMode::fix_grammar, RewriteMode::clearer,
                                                       RewriteMode::native};

// Port of SelectionBar.message(for:): a failure named for what it is. Short
// enough for the bar, distinct per cause -- two failures reading the same is
// how the "model unavailable" bug started.
std::u16string failure_message(const RewriteError& error);

}  // namespace nib::present
