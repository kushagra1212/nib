#pragma once
#include <string>
#include "app/health.hpp"
#include "text/uia.hpp"

namespace nib::app {

// What nib and its engines cost right now, from the processes themselves:
// nib.exe, and the harper-ls and llama-server it started.
struct Footprint {
    uint64_t nib_bytes = 0;
    uint64_t engine_bytes = 0;
    int engines = 0;
    std::wstring summary() const;
};
Footprint footprint();

// What the focused field exposes to UI Automation, and what that means for
// nib there. Run on a UI Automation thread.
std::wstring probe_field(text::Uia& uia);

// One clipboard action carrying what is needed to describe a failure. Its
// boundary is part of the design: versions, states, models, permissions and
// recent log lines -- never document text, selections, clipboard contents or
// transcripts. The log itself records only lengths and counts.
std::wstring diagnostic_report(const HealthContext& context);

std::wstring windows_version();

}  // namespace nib::app
