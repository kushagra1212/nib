#include "app/tray.hpp"

#include <map>

namespace nib::app {

Tray::Tray(HWND owner, HICON icon, const std::wstring& tooltip) {
    data_.cbSize = sizeof data_;
    data_.hWnd = owner;
    data_.uID = 1;
    data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    data_.uCallbackMessage = callback_message;
    data_.hIcon = icon;
    wcsncpy_s(data_.szTip, tooltip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_ADD, &data_);
    data_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data_);
}

Tray::~Tray() { Shell_NotifyIconW(NIM_DELETE, &data_); }

void Tray::set_tooltip(const std::wstring& tooltip) {
    wcsncpy_s(data_.szTip, tooltip.c_str(), _TRUNCATE);
    data_.uFlags = NIF_TIP | NIF_SHOWTIP;
    Shell_NotifyIconW(NIM_MODIFY, &data_);
}

void Tray::set_icon(HICON icon) {
    data_.hIcon = icon;
    data_.uFlags = NIF_ICON;
    Shell_NotifyIconW(NIM_MODIFY, &data_);
}

void Tray::readd() {
    data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    Shell_NotifyIconW(NIM_ADD, &data_);
    Shell_NotifyIconW(NIM_SETVERSION, &data_);
}

void Tray::balloon(const std::wstring& title, const std::wstring& text) {
    NOTIFYICONDATAW n = data_;
    n.uFlags = NIF_INFO;
    wcsncpy_s(n.szInfoTitle, title.c_str(), _TRUNCATE);
    wcsncpy_s(n.szInfo, text.c_str(), _TRUNCATE);
    n.dwInfoFlags = NIIF_NONE | NIIF_RESPECT_QUIET_TIME;
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

UINT Tray::taskbar_created() {
    static const UINT msg = RegisterWindowMessageW(L"TaskbarCreated");
    return msg;
}

namespace {

void build(HMENU menu, const std::vector<MenuItem>& items, std::map<UINT, const MenuItem*>& ids, UINT& next) {
    for (const auto& item : items) {
        if (item.separator) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        if (!item.submenu.empty()) {
            HMENU sub = CreatePopupMenu();
            build(sub, item.submenu, ids, next);
            AppendMenuW(menu, MF_POPUP | (item.enabled ? 0 : MF_GRAYED), reinterpret_cast<UINT_PTR>(sub),
                        item.text.c_str());
            continue;
        }
        const UINT id = next++;
        ids[id] = &item;
        UINT flags = MF_STRING;
        if (!item.enabled || !item.action) flags |= MF_GRAYED;
        if (item.checked) flags |= MF_CHECKED;
        AppendMenuW(menu, flags, id, item.text.c_str());
        if (item.bold) {
            MENUITEMINFOW info{sizeof info};
            info.fMask = MIIM_STATE;
            info.fState = MFS_DEFAULT | (item.enabled && item.action ? 0 : MFS_GRAYED);
            SetMenuItemInfoW(menu, id, FALSE, &info);
        }
    }
}

}  // namespace

void Tray::popup(const std::vector<MenuItem>& items) {
    HMENU menu = CreatePopupMenu();
    std::map<UINT, const MenuItem*> ids;
    UINT next = 1;
    build(menu, items, ids, next);

    POINT p;
    GetCursorPos(&p);
    // Required for the menu to close when clicking elsewhere.
    SetForegroundWindow(data_.hWnd);
    const UINT chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, p.x, p.y,
                                         data_.hWnd, nullptr);
    PostMessageW(data_.hWnd, WM_NULL, 0, 0);
    DestroyMenu(menu);

    if (chosen) {
        const auto it = ids.find(chosen);
        if (it != ids.end() && it->second->action) {
            auto action = it->second->action;  // copied: `items` may be rebuilt by it
            action();
        }
    }
}

}  // namespace nib::app
