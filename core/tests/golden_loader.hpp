#pragma once
#include <fstream>
#include <stdexcept>
#include <string>
#include <nlohmann/json.hpp>

// Goldens live at the repository root, tests run from core/build.
// NIB_GOLDEN_DIR is set by CMake so the path does not depend on the working
// directory.
inline nlohmann::json load_golden(const std::string& name) {
    const std::string path = std::string(NIB_GOLDEN_DIR) + "/" + name;
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open golden: " + path);
    return nlohmann::json::parse(in);
}

// Goldens store JSON strings; the core works in UTF-16. The conversion goes
// through ICU rather than std::codecvt, which is deprecated and was never
// reliable for anything outside the BMP -- which is precisely what these
// goldens exist to cover.
std::u16string utf8_to_utf16(const std::string& in);
