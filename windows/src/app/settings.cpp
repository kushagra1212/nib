#include "app/settings.hpp"

#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>
#include "platform/paths.hpp"

namespace nib::app {
namespace {

std::filesystem::path file() { return platform::paths::data_dir() / L"settings.json"; }

}  // namespace

Settings Settings::load() {
    Settings s;
    std::ifstream in(file());
    if (!in) return s;
    const auto j = nlohmann::json::parse(in, nullptr, false);
    if (!j.is_object()) return s;
    s.live_checking = j.value("live_checking", s.live_checking);
    s.setup_offered = j.value("setup_offered", s.setup_offered);
    s.voice = j.value("voice", s.voice);
    s.rewrite_model = j.value("rewrite_model", s.rewrite_model);
    s.speech_model = j.value("speech_model", s.speech_model);
    s.file_log = j.value("file_log", s.file_log);
    return s;
}

void Settings::save() const {
    std::error_code ec;
    std::filesystem::create_directories(file().parent_path(), ec);
    const nlohmann::json j = {
        {"live_checking", live_checking}, {"setup_offered", setup_offered}, {"voice", voice},
        {"rewrite_model", rewrite_model}, {"speech_model", speech_model},   {"file_log", file_log},
    };
    // Written beside and renamed over, so a crash mid-write cannot leave a
    // half file that resets every setting on the next launch.
    const auto tmp = file().wstring() + L".tmp";
    {
        std::ofstream out(tmp, std::ios::trunc);
        out << j.dump(2);
    }
    std::filesystem::rename(tmp, file(), ec);
}

Settings& settings() {
    static Settings s = Settings::load();
    return s;
}

}  // namespace nib::app
