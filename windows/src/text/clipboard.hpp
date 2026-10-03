#pragma once
#include <windows.h>

#include <optional>
#include <string>

namespace nib::text::clipboard {

std::optional<std::u16string> get();
bool set(const std::u16string& text);
// Increments whenever anything is copied, by anyone.
DWORD sequence();

// Holds what was on the clipboard and puts it back, so a copy or paste nib
// makes on the user's behalf does not lose what they had copied.
class Saved {
public:
    Saved();
    void restore();

private:
    std::optional<std::u16string> text_;
};

}  // namespace nib::text::clipboard
