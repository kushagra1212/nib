#pragma once
#include <windows.h>

#include <string>
#include <vector>

namespace nib::ui {

// A message with buttons, as a Task Dialog. Returns the index of the button
// pressed, or -1 when dismissed.
int ask(HWND owner, const std::wstring& title, const std::wstring& heading, const std::wstring& body,
        const std::vector<std::wstring>& buttons, bool warning = false);

void tell(HWND owner, const std::wstring& heading, const std::wstring& body, bool warning = false);

// Opens a file, folder or URL with whatever Windows has for it.
void open(const std::wstring& target);

// Shows a file selected in Explorer.
void reveal(const std::wstring& path);

// The standard Open dialog, filtered to one extension ("gguf"). Empty when
// cancelled.
std::wstring choose_file(HWND owner, const std::wstring& title, const std::wstring& description,
                         const std::wstring& extension);

}  // namespace nib::ui
