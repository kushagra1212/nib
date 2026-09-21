#pragma once
#include <cstdint>
#include <string>
#include "nib/nib_core.h"

namespace nib {

// Non-owning. The caller owns the buffer for the duration of the call, which
// is what both Swift's withUnsafeBufferPointer and C#'s fixed() already give
// us.
struct u16view {
    const uint16_t* data = nullptr;
    int32_t         size = 0;

    u16view() = default;
    u16view(const uint16_t* d, int32_t n) : data(d), size(n) {}
    explicit u16view(nib_str s) : data(s.data), size(s.length) {}

    uint16_t operator[](int32_t i) const { return data[i]; }
    bool empty() const { return size <= 0; }

    u16view slice(int32_t location, int32_t length) const {
        return u16view(data + location, length);
    }
    std::u16string to_string() const {
        return std::u16string(reinterpret_cast<const char16_t*>(data),
                              static_cast<size_t>(size));
    }
};

inline bool is_high_surrogate(uint16_t u) { return u >= 0xD800 && u <= 0xDBFF; }
inline bool is_low_surrogate(uint16_t u)  { return u >= 0xDC00 && u <= 0xDFFF; }

}  // namespace nib
