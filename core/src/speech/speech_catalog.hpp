#pragma once
#include <filesystem>
#include <optional>
#include <string>
#include <vector>
#include "rewrite/model_catalog.hpp"

// The files dictation and read-aloud need, and where they live. Same
// CatalogModel shape as the rewrite models, so the same installer, the same
// truncation check and the same Models section serve all three kinds.

namespace nib::speech {

namespace whisper_catalog {
// Multilingual builds throughout: an English-only model fails a Hindi sentence
// by transcribing it as confident nonsense English, not visibly.
const std::vector<CatalogModel>& all();
// small: base mishears ("nid" for "nib" on the first sentence tried); turbo is
// 574MB to find out whether you like dictating at all.
const CatalogModel& recommended();
std::filesystem::path install_directory();
// The installed model: the one chosen in the Models section when it is still
// there, otherwise the largest -- for whisper, size tracks accuracy.
std::optional<std::filesystem::path> installed();
void prefer(const std::string& filename);
}  // namespace whisper_catalog

namespace voice_catalog {
const std::vector<CatalogModel>& models();
const CatalogModel& voice_pack();
inline constexpr const char* default_voice = "af_heart";
std::filesystem::path install_directory();
std::optional<std::filesystem::path> installed_model();
std::optional<std::filesystem::path> installed_voice_pack();
// Both files, or nothing: speaking needs the pair.
bool installed();
// What still has to be downloaded, largest first.
std::vector<CatalogModel> needed();

// "af_heart" -> "Heart — American, female".
std::u16string title(const std::string& voice);
std::u16string accent(const std::string& voice);
}  // namespace voice_catalog

}  // namespace nib::speech
