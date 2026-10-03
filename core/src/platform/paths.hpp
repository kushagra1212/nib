#pragma once
#include <cstdint>
#include <filesystem>
#include <optional>
#include <vector>

namespace nib::platform::paths {

namespace fs = std::filesystem;

// %LOCALAPPDATA%\nib -- the Application Support folder's counterpart. Local
// rather than roaming: models are gigabytes and must never sync.
fs::path data_dir();
fs::path models_dir();    // rewrite models, *.gguf
fs::path speech_dir();    // whisper models, *.bin
fs::path voice_dir();     // Kokoro model and voice pack
fs::path log_file();

// The directory nib.exe is in.
fs::path executable_dir();

// A bundled engine file. Installed, engines sit beside nib.exe under
// `engines\`; in a development checkout they are under `windows\vendor\`,
// found by walking up from the executable the way macOS walks to vendor/.
std::optional<fs::path> locate_engine(const fs::path& relative);

// Free bytes on the volume holding `path`, or nullopt when unknown.
std::optional<uint64_t> free_space(const fs::path& path);

}  // namespace nib::platform::paths
