#pragma once
#include <array>
#include <string>

namespace nib {

// Port of RewriteMode: what to ask the model for.
enum class RewriteMode { fix_grammar, clearer, shorter, native };

inline constexpr std::array<RewriteMode, 4> all_rewrite_modes{
    RewriteMode::fix_grammar, RewriteMode::clearer, RewriteMode::shorter,
    RewriteMode::native};

namespace rewrite_mode {

// "Fix grammar", "Make clearer", ... -- Swift's rawValue, also the cache key.
const char16_t* raw_value(RewriteMode mode);
// "Fix", "Clearer", "Shorter", "Native": fits four buttons on one row.
const char16_t* short_title(RewriteMode mode);
// "FIX", "CLEARER", ...: the label on a suggestion, naming which question it
// answers. Exists because Fix output was once judged as Native.
std::u16string badge(RewriteMode mode);

std::u16string instruction(RewriteMode mode);
// Constant per mode, so llama-server reuses the cached prefix.
std::u16string system_prompt(RewriteMode mode);

// Whether the mode may drop or move words. Only Fix -- meant to change as
// little as possible -- is held to the mid-sentence deletion rule.
bool may_restructure(RewriteMode mode);

}  // namespace rewrite_mode
}  // namespace nib
