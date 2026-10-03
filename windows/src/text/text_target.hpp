#pragma once
#include <optional>
#include <string>
#include "text/uia.hpp"

namespace nib::text {

// Port of TextTarget: the text the hotkey panel works on, and where it goes
// back to.
struct TextTarget {
    enum class Source { automation, clipboard };

    std::u16string text;      // what the panel shows
    std::u16string full;      // the field's whole text, when it could be read
    nib_range range{0, 0};    // where `text` sits in `full`
    Source source = Source::clipboard;
    bool had_selection = false;
    // False when the range covers the selection rather than a measured
    // position: the writer must then type over whatever is selected instead of
    // selecting 0..length and overwriting the start of the document.
    bool range_is_absolute = false;
    std::optional<Field> field;
    HWND window = nullptr;
};

enum class WriteOutcome { typed, wrote_in_place, pasted, copied_to_clipboard };

enum class GrabFailure { none, sensitive, elevated, nothing };

// Reads the selection -- or, with nothing selected, the whole field -- from
// whatever has focus. Never reads a password field: that is checked before the
// clipboard route, which would otherwise send Ctrl+C to it.
std::optional<TextTarget> grab(Uia& uia, GrabFailure* why = nullptr);

// Writes `replacement` back over what was grabbed, preferring typing (undoable)
// over a UI Automation write over a paste. If nothing lands, it is left on the
// clipboard and the caller says so.
WriteOutcome replace(Uia& uia, const TextTarget& target, const std::u16string& replacement);

}  // namespace nib::text
