#include "ui/dialogs.hpp"

#include <commctrl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

namespace nib::ui {

int ask(HWND owner, const std::wstring& title, const std::wstring& heading, const std::wstring& body,
        const std::vector<std::wstring>& buttons, bool warning) {
    std::vector<TASKDIALOG_BUTTON> list;
    for (size_t i = 0; i < buttons.size(); ++i) {
        list.push_back({static_cast<int>(100 + i), buttons[i].c_str()});
    }
    TASKDIALOGCONFIG config{sizeof config};
    config.hwndParent = owner;
    config.hInstance = GetModuleHandleW(nullptr);
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = title.c_str();
    config.pszMainIcon = warning ? TD_WARNING_ICON : MAKEINTRESOURCEW(1);
    if (!warning) config.dwFlags |= 0;
    config.pszMainInstruction = heading.c_str();
    config.pszContent = body.c_str();
    config.cButtons = static_cast<UINT>(list.size());
    config.pButtons = list.data();
    if (list.empty()) config.dwCommonButtons = TDCBF_OK_BUTTON;
    int pressed = -1;
    if (FAILED(TaskDialogIndirect(&config, &pressed, nullptr, nullptr))) return -1;
    return pressed >= 100 ? pressed - 100 : -1;
}

void tell(HWND owner, const std::wstring& heading, const std::wstring& body, bool warning) {
    ask(owner, L"nib", heading, body, {}, warning);
}

void open(const std::wstring& target) {
    ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

void reveal(const std::wstring& path) {
    PIDLIST_ABSOLUTE pidl = ILCreateFromPathW(path.c_str());
    if (pidl) {
        SHOpenFolderAndSelectItems(pidl, 0, nullptr, 0);
        ILFree(pidl);
    }
}

std::wstring choose_file(HWND owner, const std::wstring& title, const std::wstring& description,
                         const std::wstring& extension) {
    Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        return {};
    }
    const std::wstring pattern = L"*." + extension;
    COMDLG_FILTERSPEC spec{description.c_str(), pattern.c_str()};
    dialog->SetFileTypes(1, &spec);
    dialog->SetTitle(title.c_str());
    if (FAILED(dialog->Show(owner))) return {};
    Microsoft::WRL::ComPtr<IShellItem> item;
    if (FAILED(dialog->GetResult(&item))) return {};
    PWSTR path = nullptr;
    std::wstring out;
    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
        out = path;
        CoTaskMemFree(path);
    }
    return out;
}

}  // namespace nib::ui
