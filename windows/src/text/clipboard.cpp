#include "text/clipboard.hpp"

#include <cstring>

namespace nib::text::clipboard {
namespace {

// The clipboard can be held open by another app for a moment; retry briefly.
bool open() {
    for (int i = 0; i < 10; ++i) {
        if (OpenClipboard(nullptr)) return true;
        Sleep(10);
    }
    return false;
}

}  // namespace

std::optional<std::u16string> get() {
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT) || !open()) return std::nullopt;
    std::optional<std::u16string> out;
    if (HANDLE h = GetClipboardData(CF_UNICODETEXT)) {
        if (const auto* p = static_cast<const char16_t*>(GlobalLock(h))) {
            out = std::u16string(p);
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return out;
}

bool set(const std::u16string& text) {
    if (!open()) return false;
    EmptyClipboard();
    const size_t bytes = (text.size() + 1) * sizeof(char16_t);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    bool ok = false;
    if (h) {
        if (void* p = GlobalLock(h)) {
            std::memcpy(p, text.c_str(), bytes);
            GlobalUnlock(h);
            ok = SetClipboardData(CF_UNICODETEXT, h) != nullptr;
        }
        if (!ok) GlobalFree(h);
    }
    CloseClipboard();
    return ok;
}

DWORD sequence() { return GetClipboardSequenceNumber(); }

Saved::Saved() : text_(get()) {}

void Saved::restore() {
    if (text_) set(*text_);
}

}  // namespace nib::text::clipboard
