#pragma once
#include <windows.h>
#include <shellapi.h>

#include <functional>
#include <string>
#include <vector>

namespace nib::app {

// One item in the tray menu. Rebuilt every time the menu opens, so it shows
// what is true now rather than what was true at launch.
struct MenuItem {
    std::wstring text;
    std::function<void()> action;
    bool enabled = true;
    bool checked = false;
    bool separator = false;
    bool bold = false;
    std::vector<MenuItem> submenu;

    static MenuItem sep() {
        MenuItem m;
        m.separator = true;
        return m;
    }
};

// The notification-area icon: Windows' menu bar item.
class Tray {
public:
    static constexpr UINT callback_message = WM_APP + 1;

    Tray(HWND owner, HICON icon, const std::wstring& tooltip);
    ~Tray();

    void set_tooltip(const std::wstring& tooltip);
    void set_icon(HICON icon);
    // Explorer restarts drop every tray icon; the owner re-adds on
    // TaskbarCreated.
    void readd();
    void balloon(const std::wstring& title, const std::wstring& text);

    // Shows `items` at the cursor and runs the chosen action.
    void popup(const std::vector<MenuItem>& items);

    static UINT taskbar_created();

private:
    NOTIFYICONDATAW data_{};
};

}  // namespace nib::app
