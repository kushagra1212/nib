#include "text/text_target.hpp"

#include "support/log.hpp"
#include "text/clipboard.hpp"
#include "text/keystroke.hpp"

namespace nib::text {
namespace {

bool range_selects(const std::u16string& selected, const std::u16string& full, nib_range r) {
    if (r.location < 0 || r.length < 0) return false;
    if (static_cast<size_t>(r.location) + static_cast<size_t>(r.length) > full.size()) return false;
    return full.compare(static_cast<size_t>(r.location), static_cast<size_t>(r.length), selected) == 0;
}

void wait_for_focus(HWND window) {
    if (!window) return;
    // Hands the foreground back to the app the text came from. nib is the
    // foreground process when this runs -- the panel just had focus -- so the
    // focus-stealing rules allow it.
    SetForegroundWindow(window);
    for (int i = 0; i < 25 && GetForegroundWindow() != window; ++i) Sleep(10);
    Sleep(40);
}

std::optional<TextTarget> via_automation(Uia& uia) {
    auto field = uia.focused();
    if (!field || !may_read(*field)) return std::nullopt;

    const auto sel = uia.selection(*field);
    if (sel && !sel->text.empty()) {
        // Prefer the full field so the range is a real position; fall back to
        // the selection alone when the field will not read or disagrees.
        if (const auto full = uia.text(*field); full && sel->absolute && range_selects(sel->text, *full, sel->range)) {
            return TextTarget{sel->text, *full, sel->range, TextTarget::Source::automation, true, true, field,
                              field->window};
        }
        return TextTarget{sel->text, sel->text, {0, static_cast<int32_t>(sel->text.size())},
                          TextTarget::Source::automation, true, false, field, field->window};
    }
    if (const auto full = uia.text(*field); full && !full->empty()) {
        return TextTarget{*full, *full, {0, static_cast<int32_t>(full->size())},
                          TextTarget::Source::automation, false, true, field, field->window};
    }
    return std::nullopt;
}

std::optional<TextTarget> via_clipboard() {
    HWND window = GetForegroundWindow();
    clipboard::Saved saved;
    const DWORD before = clipboard::sequence();
    release_modifiers();
    send_key('C', {VK_CONTROL});
    // Give the app a moment to service the copy.
    for (int i = 0; i < 40 && clipboard::sequence() == before; ++i) Sleep(10);
    if (clipboard::sequence() == before) return std::nullopt;
    const auto text = clipboard::get();
    saved.restore();
    if (!text || text->empty()) return std::nullopt;
    return TextTarget{*text, *text, {0, static_cast<int32_t>(text->size())}, TextTarget::Source::clipboard,
                      true, false, std::nullopt, window};
}

}  // namespace

std::optional<TextTarget> grab(Uia& uia, GrabFailure* why) {
    if (why) *why = GrabFailure::none;
    HWND foreground = GetForegroundWindow();
    if (foreground && is_elevated_window(foreground)) {
        if (why) *why = GrabFailure::elevated;
        return std::nullopt;
    }
    // Checked before anything else: falling through to the clipboard would
    // send Ctrl+C to a password field.
    if (auto field = uia.focused()) {
        if (field->password || mentions_secret(field->label)) {
            if (why) *why = GrabFailure::sensitive;
            return std::nullopt;
        }
    }
    if (auto target = via_automation(uia)) return target;
    if (auto target = via_clipboard()) return target;
    if (why) *why = GrabFailure::nothing;
    return std::nullopt;
}

WriteOutcome replace(Uia& uia, const TextTarget& target, const std::u16string& replacement) {
    wait_for_focus(target.window);

    if (target.source == TextTarget::Source::automation && target.field) {
        const auto& field = *target.field;
        // Select what is being replaced, then type over it: typing enters the
        // app's undo stack. With a non-absolute range the user's own selection
        // is still in place, so it is typed over as it stands.
        bool selected = !target.range_is_absolute && target.had_selection;
        if (!selected) {
            uia.focus(field);
            selected = uia.select(field, target.range);
        }
        if (selected) {
            type(replacement);
            Sleep(60);
            const auto now = uia.text(field);
            if (!now || now->find(replacement) != std::u16string::npos || target.had_selection) {
                log::write("panel: applied by typing");
                return WriteOutcome::typed;
            }
        }
        // Whole-value write: no undo entry, but widely supported.
        if (!target.had_selection && field.has_value && !field.read_only
            && uia.set_value(field, replacement)) {
            log::write("panel: applied by value write -- no undo entry");
            return WriteOutcome::wrote_in_place;
        }
    }

    // Paste over the selection, then put the user's clipboard back.
    clipboard::Saved saved;
    if (clipboard::set(replacement)) {
        release_modifiers();
        if (!target.had_selection) send_key('A', {VK_CONTROL});
        send_key('V', {VK_CONTROL});
        Sleep(150);
        saved.restore();
        log::write("panel: applied by paste");
        return WriteOutcome::pasted;
    }
    clipboard::set(replacement);
    return WriteOutcome::copied_to_clipboard;
}

}  // namespace nib::text
