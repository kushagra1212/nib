#include "app/diagnostics.hpp"

#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>

#include <cstdio>
#include "app/dispatch.hpp"
#include "nib/version.h"
#include "rewrite/model_catalog.hpp"
#include "speech/speech_catalog.hpp"
#include "support/log.hpp"
#include "text/unicode.hpp"

namespace nib::app {
namespace {

uint64_t private_bytes(DWORD pid) {
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return 0;
    PROCESS_MEMORY_COUNTERS_EX pmc{};
    uint64_t out = 0;
    if (GetProcessMemoryInfo(p, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc), sizeof pmc)) {
        out = pmc.PrivateUsage;
    }
    CloseHandle(p);
    return out;
}

std::wstring bytes(uint64_t n) {
    wchar_t buf[32];
    if (n >= 1'000'000'000) swprintf(buf, 32, L"%.1f GB", n / 1e9);
    else swprintf(buf, 32, L"%.0f MB", n / 1e6);
    return buf;
}

std::wstring size_of(const std::filesystem::path& p) {
    std::error_code ec;
    const auto n = std::filesystem::file_size(p, ec);
    return ec ? L"?" : bytes(n);
}

}  // namespace

std::wstring Footprint::summary() const {
    std::wstring out = L"nib " + bytes(nib_bytes);
    if (engines) out += L" · engines " + bytes(engine_bytes);
    return out;
}

Footprint footprint() {
    Footprint f;
    const DWORD self = GetCurrentProcessId();
    f.nib_bytes = private_bytes(self);
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return f;
    PROCESSENTRY32W e{sizeof e};
    for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e)) {
        if (e.th32ParentProcessID == self) {
            f.engine_bytes += private_bytes(e.th32ProcessID);
            ++f.engines;
        }
    }
    CloseHandle(snap);
    return f;
}

std::wstring windows_version() {
    // RtlGetVersion tells the truth where GetVersionEx is shimmed.
    using Fn = LONG(WINAPI*)(OSVERSIONINFOW*);
    OSVERSIONINFOW v{sizeof v};
    if (auto fn = reinterpret_cast<Fn>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"))) fn(&v);
    SYSTEM_INFO si;
    GetNativeSystemInfo(&si);
    const wchar_t* arch = si.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64 ? L"ARM64" : L"x64";
    return L"Windows " + std::to_wstring(v.dwMajorVersion) + L"." + std::to_wstring(v.dwMinorVersion) + L" build "
           + std::to_wstring(v.dwBuildNumber) + L" " + arch;
}

std::wstring probe_field(text::Uia& uia) {
    auto field = uia.focused();
    if (!field) {
        HWND fg = GetForegroundWindow();
        if (fg && text::is_elevated_window(fg)) {
            return L"The frontmost app is running as administrator. Windows keeps nib out of it unless nib runs as "
                   L"administrator too.";
        }
        return L"Nothing has keyboard focus that UI Automation can see.";
    }
    std::wstring out;
    auto line = [&](const wchar_t* k, const std::wstring& v) { out += std::wstring(k) + v + L"\r\n"; };
    line(L"app:              ", field->app);
    line(L"role:             ", field->role);
    line(L"password field:   ", field->password ? L"YES -- never read" : L"no");
    const bool secret = text::mentions_secret(field->label);
    if (secret) line(L"label:            ", L"mentions a secret -- never read");
    line(L"text pattern:     ", field->has_text ? L"yes" : L"NO");
    line(L"value pattern:    ", field->has_value ? (field->read_only ? L"yes, read-only" : L"yes, writable") : L"no");
    const auto text = text::may_read(*field) ? uia.text(*field) : std::nullopt;
    line(L"read text:        ", text ? L"yes (" + std::to_wstring(text->size()) + L" characters)" : L"NO");
    const auto sel = text::may_read(*field) ? uia.selection(*field) : std::nullopt;
    line(L"read selection:   ", sel ? (sel->absolute ? L"yes, with position" : L"yes, no position") : L"no");
    const auto one = uia.bounds(*field, {0, 1});
    const auto four = uia.bounds(*field, {0, 4});
    line(L"bounds, 1 char:   ", one.empty() ? L"NO" : L"yes");
    line(L"bounds, 4 chars:  ", four.empty() ? L"NO" : L"yes");
    if (auto frame = uia.frame(*field)) {
        line(L"frame:            ", std::to_wstring(frame->left) + L"," + std::to_wstring(frame->top) + L" "
                                        + std::to_wstring(frame->right - frame->left) + L"x"
                                        + std::to_wstring(frame->bottom - frame->top));
    }
    out += L"\r\n";
    if (!text::may_read(*field)) {
        out += L"nib does not read this field.";
    } else if (!one.empty()) {
        out += L"Underlines work here, and so does everything else.";
    } else if (text) {
        out += L"nib can read and fix text here, but the app does not say where characters are -- so the badge "
               L"counts issues instead of underlining, and Ctrl+Alt+Space opens them.";
    } else {
        out += L"This field exposes no text. Select text and press Ctrl+Alt+Space: nib copies the selection instead.";
    }
    return out;
}

std::wstring diagnostic_report(const HealthContext& context) {
    std::wstring out;
    auto line = [&](const std::wstring& s) { out += s + L"\r\n"; };
    line(L"nib " NIB_VERSION_W L" for Windows, core ABI " + std::to_wstring(NIB_CORE_ABI_VERSION));
    line(windows_version());
    line(L"memory: " + footprint().summary());
    line(L"");
    line(L"Features");
    for (const auto& r : health_report(context)) {
        const wchar_t* state = r.state == HealthState::working ? L"working" : r.state == HealthState::degraded ? L"degraded" : L"BROKEN";
        line(L"  " + std::wstring(title(r.feature)) + L": " + state + L" -- " + r.detail);
        if (!r.reason.empty()) line(L"    reason: " + r.reason);
    }
    line(L"");
    line(L"Models");
    std::error_code ec;
    for (const auto& dir : {model_catalog::install_directory(), speech::whisper_catalog::install_directory(),
                            speech::voice_catalog::install_directory()}) {
        for (const auto& e : std::filesystem::directory_iterator(dir, ec)) {
            if (e.is_regular_file(ec)) line(L"  " + e.path().filename().wstring() + L"  " + size_of(e.path()));
        }
    }
    line(L"");
    line(L"Engines");
    auto engine = [&](const wchar_t* name, std::optional<std::filesystem::path> p) {
        line(std::wstring(L"  ") + name + L": " + (p ? L"present" : L"MISSING"));
    };
    engine(L"harper-ls", locate_harper());
    engine(L"llama-server", locate_llama_server());
    line(L"");
    line(L"Shortcuts");
    for (const auto& [name, combo] : context.hotkeys) line(L"  " + name + L": " + (combo.empty() ? L"NOT REGISTERED" : combo));
    line(L"  microphone allowed: " + std::wstring(context.microphone_allowed ? L"yes" : L"NO"));
    line(L"");
    line(L"Recent log");
    const auto recent = log::recent();
    const size_t from = recent.size() > 80 ? recent.size() - 80 : 0;
    for (size_t i = from; i < recent.size(); ++i) line(L"  " + widen(recent[i]));
    return out;
}

}  // namespace nib::app
