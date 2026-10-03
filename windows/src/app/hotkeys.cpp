#include "app/hotkeys.hpp"

#include "app/dispatch.hpp"
#include "support/log.hpp"

namespace nib::app {

Hotkeys::Combo Hotkeys::default_combo(Action action) {
    // Ctrl+Alt for all five: the roadmap's choice, and the one family of
    // combinations Windows itself leaves alone.
    const UINT mods = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
    switch (action) {
    case Action::panel:    return {mods, VK_SPACE, L"Ctrl+Alt+Space"};
    case Action::dictate:  return {mods, 'D', L"Ctrl+Alt+D"};
    case Action::practice: return {mods, 'P', L"Ctrl+Alt+P"};
    case Action::speak:    return {mods, 'N', L"Ctrl+Alt+N"};
    case Action::hush:     return {mods, 'H', L"Ctrl+Alt+H"};
    }
    return {};
}

const wchar_t* Hotkeys::name(Action action) {
    switch (action) {
    case Action::panel:    return L"Check Selection";
    case Action::dictate:  return L"Dictate";
    case Action::practice: return L"Practice Take";
    case Action::speak:    return L"Speak Selection";
    case Action::hush:     return L"Stop Speaking";
    }
    return L"";
}

Hotkeys::Hotkeys(HWND owner) : owner_(owner) {}

Hotkeys::~Hotkeys() { unregister_all(); }

bool Hotkeys::add(Action action, std::function<void()> fire) {
    Entry e{default_combo(action), std::move(fire), false};
    const int id = static_cast<int>(action) + 1;
    e.active = RegisterHotKey(owner_, id, e.combo.modifiers, e.combo.key) != FALSE;
    // Logged on success as well as failure: "registered fine" and "this never
    // ran" must not be the same silence.
    log::write(narrow(name(action)) + (e.active ? " hotkey registered on " : " hotkey unavailable -- something else holds ")
               + narrow(e.combo.label));
    entries_[action] = std::move(e);
    return entries_[action].active;
}

void Hotkeys::reregister() {
    std::string back;
    for (auto& [action, e] : entries_) {
        const int id = static_cast<int>(action) + 1;
        UnregisterHotKey(owner_, id);
        e.active = RegisterHotKey(owner_, id, e.combo.modifiers, e.combo.key) != FALSE;
        if (e.active) back += narrow(e.combo.label) + " ";
    }
    log::write("hotkeys re-registered: " + (back.empty() ? std::string("none") : back));
}

bool Hotkeys::claim_missing() {
    bool gained = false;
    for (auto& [action, e] : entries_) {
        if (e.active) continue;
        e.active = RegisterHotKey(owner_, static_cast<int>(action) + 1, e.combo.modifiers, e.combo.key) != FALSE;
        if (e.active) {
            log::write(narrow(name(action)) + " hotkey registered on " + narrow(e.combo.label) + ", now free");
            gained = true;
        }
    }
    return gained;
}

bool Hotkeys::all_registered() const {
    for (const auto& [action, e] : entries_) {
        if (!e.active) return false;
    }
    return true;
}

void Hotkeys::unregister_all() {
    for (auto& [action, e] : entries_) {
        UnregisterHotKey(owner_, static_cast<int>(action) + 1);
        e.active = false;
    }
}

void Hotkeys::fired(WPARAM id) {
    const auto action = static_cast<Action>(static_cast<int>(id) - 1);
    const auto it = entries_.find(action);
    if (it != entries_.end() && it->second.fire) it->second.fire();
}

std::wstring Hotkeys::label(Action action) const {
    const auto it = entries_.find(action);
    return it != entries_.end() && it->second.active ? it->second.combo.label : std::wstring();
}

bool Hotkeys::registered(Action action) const {
    const auto it = entries_.find(action);
    return it != entries_.end() && it->second.active;
}

}  // namespace nib::app
