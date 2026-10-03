#pragma once
#include <windows.h>

#include <string>

namespace nib::text {

// Types a string into whatever has focus, as Unicode key events.
//
// Typing goes through the app's normal input path, so the edit lands in its
// undo stack and Ctrl+Z reverts it -- the reason it is tried before any
// UI Automation write, which changes text without the app noticing. Line
// breaks are sent as Shift+Enter: a plain Enter submits the message in every
// chat app nib is used in.
void type(const std::u16string& text);

// A key with modifiers, e.g. send_key('C', {VK_CONTROL}).
void send_key(WORD vk, std::initializer_list<WORD> modifiers = {});

// Releases modifiers the user may still be holding from a hotkey. Ctrl+Alt
// held down while nib types turns every letter into a shortcut.
void release_modifiers();

}  // namespace nib::text
