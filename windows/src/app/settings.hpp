#pragma once
#include <string>

namespace nib::app {

// What nib remembers between launches. A small JSON file beside the models,
// read at start and written on every change.
struct Settings {
    bool live_checking = true;      // underline as you type
    bool setup_offered = false;     // the first-run model offer was shown
    std::string voice = "af_heart"; // Kokoro voice
    std::string rewrite_model;      // empty: best installed
    std::string speech_model;       // empty: best installed
    bool file_log = false;

    static Settings load();
    void save() const;
};

Settings& settings();

}  // namespace nib::app
