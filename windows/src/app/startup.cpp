#include "app/startup.hpp"

#include <windows.h>

#include <string>
#include "platform/paths.hpp"

namespace nib::app::startup {
namespace {

constexpr const wchar_t* run_key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
// Where Task Manager records that the user switched a Run entry off.
constexpr const wchar_t* approved_key =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
constexpr const wchar_t* value_name = L"nib";

std::wstring command() {
    return L"\"" + (platform::paths::executable_dir() / L"nib.exe").wstring() + L"\" --background";
}

}  // namespace

State state() {
    wchar_t buffer[1024];
    DWORD size = sizeof buffer;
    if (RegGetValueW(HKEY_CURRENT_USER, run_key, value_name, RRF_RT_REG_SZ, nullptr, buffer, &size)
        != ERROR_SUCCESS) {
        return State::off;
    }
    // The first byte of the approval blob is 2 when enabled, 3 when the user
    // disabled the entry in Task Manager.
    BYTE approval[12]{};
    DWORD asize = sizeof approval;
    if (RegGetValueW(HKEY_CURRENT_USER, approved_key, value_name, RRF_RT_REG_BINARY, nullptr, approval,
                     &asize) == ERROR_SUCCESS
        && asize > 0 && (approval[0] & 1)) {
        return State::disabled_by_user;
    }
    return State::on;
}

bool set(bool enabled) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, run_key, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr)
        != ERROR_SUCCESS) {
        return false;
    }
    LSTATUS status;
    if (enabled) {
        const auto cmd = command();
        status = RegSetValueExW(key, value_name, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()),
                                static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
    } else {
        status = RegDeleteValueW(key, value_name);
        if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    if (enabled) {
        // Clear a Task Manager "disabled" mark, or turning it on here would
        // look like it worked and do nothing.
        HKEY approved = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, approved_key, 0, KEY_SET_VALUE, &approved) == ERROR_SUCCESS) {
            RegDeleteValueW(approved, value_name);
            RegCloseKey(approved);
        }
    }
    return status == ERROR_SUCCESS;
}

}  // namespace nib::app::startup
