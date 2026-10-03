#include "text/keystroke.hpp"

#include <vector>

namespace nib::text {
namespace {

INPUT key(WORD vk, bool up) {
    INPUT in{};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    return in;
}

INPUT unicode(wchar_t c, bool up) {
    INPUT in{};
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = c;
    in.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
    return in;
}

}  // namespace

void release_modifiers() {
    std::vector<INPUT> inputs;
    for (WORD vk : {VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN}) {
        if (GetAsyncKeyState(vk) & 0x8000) inputs.push_back(key(vk, true));
    }
    if (!inputs.empty()) SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

void type(const std::u16string& text) {
    if (text.empty()) return;
    release_modifiers();
    std::vector<INPUT> inputs;
    inputs.reserve(text.size() * 2);
    for (size_t i = 0; i < text.size(); ++i) {
        const char16_t c = text[i];
        if (c == u'\r') continue;
        if (c == u'\n') {
            inputs.push_back(key(VK_SHIFT, false));
            inputs.push_back(key(VK_RETURN, false));
            inputs.push_back(key(VK_RETURN, true));
            inputs.push_back(key(VK_SHIFT, true));
            continue;
        }
        if (c == u'\t') {
            inputs.push_back(key(VK_TAB, false));
            inputs.push_back(key(VK_TAB, true));
            continue;
        }
        // Surrogate pairs go as two Unicode events, which is what Windows
        // expects for characters outside the BMP.
        inputs.push_back(unicode(static_cast<wchar_t>(c), false));
        inputs.push_back(unicode(static_cast<wchar_t>(c), true));
    }
    // In chunks: one enormous SendInput can be cut short when the target's
    // queue fills, and SendInput reports that only as a smaller count.
    constexpr size_t chunk = 200;
    for (size_t at = 0; at < inputs.size(); at += chunk) {
        const UINT n = static_cast<UINT>(std::min(chunk, inputs.size() - at));
        SendInput(n, inputs.data() + at, sizeof(INPUT));
        if (at + n < inputs.size()) Sleep(2);
    }
}

void send_key(WORD vk, std::initializer_list<WORD> modifiers) {
    std::vector<INPUT> inputs;
    for (WORD m : modifiers) inputs.push_back(key(m, false));
    inputs.push_back(key(vk, false));
    inputs.push_back(key(vk, true));
    for (auto it = std::rbegin(modifiers); it != std::rend(modifiers); ++it) inputs.push_back(key(*it, true));
    SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

}  // namespace nib::text
