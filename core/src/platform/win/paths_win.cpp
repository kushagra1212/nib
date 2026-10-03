#include "platform/paths.hpp"

#include <windows.h>
#include <shlobj.h>

#include <system_error>

namespace nib::platform::paths {

fs::path data_dir() {
    // Overridable so the test suite and a portable copy never touch the real
    // folder.
    if (const wchar_t* over = _wgetenv(L"NIB_DATA_DIR"); over && *over) return fs::path(over);

    PWSTR local = nullptr;
    fs::path out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
        out = fs::path(local) / L"nib";
    }
    CoTaskMemFree(local);
    return out;
}

fs::path models_dir() { return data_dir() / L"models"; }
fs::path speech_dir() { return data_dir() / L"speech"; }
fs::path voice_dir()  { return data_dir() / L"voice"; }
fs::path log_file()   { return data_dir() / L"nib.log"; }

fs::path executable_dir() {
    std::wstring buffer(MAX_PATH, L'\0');
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (n < buffer.size()) {
            buffer.resize(n);
            break;
        }
        buffer.resize(buffer.size() * 2);
    }
    return fs::path(buffer).parent_path();
}

std::optional<fs::path> locate_engine(const fs::path& relative) {
    std::error_code ec;
    const fs::path base = executable_dir();
    const fs::path installed = base / L"engines" / relative;
    if (fs::is_regular_file(installed, ec)) return installed;

    // Development: build output is several levels below the repo root.
    fs::path dir = base;
    for (int i = 0; i < 7 && !dir.empty(); ++i) {
        const fs::path candidate = dir / L"windows" / L"vendor" / relative;
        if (fs::is_regular_file(candidate, ec)) return candidate;
        const fs::path sibling = dir / L"vendor" / relative;
        if (fs::is_regular_file(sibling, ec)) return sibling;
        if (dir == dir.parent_path()) break;
        dir = dir.parent_path();
    }
    return std::nullopt;
}

std::optional<uint64_t> free_space(const fs::path& path) {
    std::error_code ec;
    fs::path probe = path;
    // The folder may not exist yet; ask about the nearest one that does.
    while (!probe.empty() && !fs::exists(probe, ec)) {
        if (probe == probe.parent_path()) break;
        probe = probe.parent_path();
    }
    const auto info = fs::space(probe, ec);
    if (ec) return std::nullopt;
    return info.available;
}

}  // namespace nib::platform::paths
