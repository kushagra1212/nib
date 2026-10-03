#pragma once
#include <windows.h>
#include <uiautomation.h>
#include <wrl/client.h>

#include <optional>
#include <string>
#include <vector>
#include "nib/nib_core.h"

// UI Automation: Windows' counterpart to the macOS Accessibility API.
//
// nib reads the focused field's text, its selection, and where each character
// sits on screen, and writes corrections back. Unlike macOS this needs no
// permission prompt -- but Windows still keeps a lower-integrity process out
// of an elevated one, so nib cannot read or type into an app running as
// administrator. That is reported, not worked around.
//
// Every call here crosses into another process and can block on it, so none
// of it runs on the UI thread.

namespace nib::text {

using Microsoft::WRL::ComPtr;

struct Field {
    ComPtr<IUIAutomationElement> element;
    CONTROLTYPEID control_type = 0;
    std::wstring role;        // "edit", "document", "combo box", ...
    std::wstring label;       // name, help text and placeholder, joined
    std::wstring app;         // executable name, for the log and diagnostics
    DWORD pid = 0;
    HWND window = nullptr;    // the top-level window it belongs to
    bool password = false;
    bool read_only = false;
    bool has_text = false;    // TextPattern
    bool has_value = false;   // ValuePattern
};

// Port of FieldEligibility: whether nib may read this field at all.
//
// A password field must never be read: checking the role alone reads
// passwords and hands them to the linter, the single worst thing an app that
// watches your typing can do. Web password inputs do not always report it, so
// the label is checked too, deliberately broadly.
bool may_read(const Field& field);
bool mentions_secret(std::wstring_view label);

class Uia {
public:
    // One per thread that uses it; COM is initialised on that thread.
    Uia();
    ~Uia();

    // One per thread, created on first use: COM and the automation object are
    // per thread, and creating them per call costs more than the call.
    static Uia& for_this_thread();
    bool ok() const { return automation_ != nullptr; }

    std::optional<Field> focused();
    std::optional<Field> describe(IUIAutomationElement* element);

    // The whole text of the field.
    std::optional<std::u16string> text(const Field& field);

    struct Selection {
        std::u16string text;
        nib_range range{0, 0};  // UTF-16 offsets into the field's text
        bool absolute = false;  // whether `range` was measured, not assumed
    };
    std::optional<Selection> selection(const Field& field);

    // Screen rectangles, one per line, for a UTF-16 range. Empty when the app
    // does not answer -- which many do not, and then nib shows the badge.
    std::vector<RECT> bounds(const Field& field, nib_range range);
    std::optional<RECT> frame(const Field& field);
    // Bounds of the current selection, without needing its offsets.
    std::vector<RECT> selection_bounds(const Field& field);

    // Selects a UTF-16 range in the field.
    bool select(const Field& field, nib_range range);
    bool set_value(const Field& field, const std::u16string& value);
    bool focus(const Field& field);

    IUIAutomation* automation() { return automation_.Get(); }

private:
    ComPtr<IUIAutomationTextRange> range_for(const Field& field, nib_range range);

    ComPtr<IUIAutomation> automation_;
    bool com_ = false;
};

// The executable name of a process, for the log ("slack.exe").
std::wstring process_name(DWORD pid);

// Whether a window belongs to an elevated process nib cannot reach.
bool is_elevated_window(HWND hwnd);

}  // namespace nib::text
