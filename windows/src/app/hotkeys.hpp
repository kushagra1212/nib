#pragma once
#include <windows.h>

#include <functional>
#include <map>
#include <string>

namespace nib::app {

// System-wide shortcuts, through RegisterHotKey.
//
// Windows gives a combination to one app only and tells the loser nothing but
// a failed call -- so every registration's outcome is kept and shown in the
// control panel, rather than leaving a dead key that looks like a broken nib.
class Hotkeys {
public:
    enum class Action { panel, dictate, practice, speak, hush };

    struct Combo {
        UINT modifiers;
        UINT key;
        std::wstring label;  // "Ctrl+Alt+Space"
    };

    static Combo default_combo(Action action);
    static const wchar_t* name(Action action);

    explicit Hotkeys(HWND owner);
    ~Hotkeys();

    bool add(Action action, std::function<void()> fire);
    // Registrations do not reliably survive sleep and session switches; the
    // owner calls this on resume and unlock. Tearing down and rebuilding twice
    // is harmless; missing one leaves the keys dead for the day.
    void reregister();
    void unregister_all();

    // Call from the owner's window procedure for WM_HOTKEY.
    void fired(WPARAM id);

    // The label of a registered action, or empty when something else holds it.
    std::wstring label(Action action) const;
    bool registered(Action action) const;

private:
    struct Entry {
        Combo combo;
        std::function<void()> fire;
        bool active = false;
    };
    HWND owner_;
    std::map<Action, Entry> entries_;
};

}  // namespace nib::app
