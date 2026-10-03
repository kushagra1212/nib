#pragma once
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace nib::app {

// Port of Health: what nib can and cannot do right now, and why.
//
// Every check is passive -- files on disk, processes already running. Nothing
// is started to find out: waking llama-server costs gigabytes, and a health
// check that allocates is one that can cause the failure it was opened to
// explain. Proving a feature works is Test, run per row, on request.
enum class Feature { text_access, grammar, rewrite, dictation, speech, hotkeys, live_checking };

inline constexpr Feature all_features[] = {Feature::text_access, Feature::grammar, Feature::rewrite,
                                           Feature::dictation,   Feature::speech,  Feature::hotkeys,
                                           Feature::live_checking};

const wchar_t* title(Feature f);
const wchar_t* purpose(Feature f);

enum class HealthState { working, degraded, broken };

struct HealthContext {
    bool grammar_running = false;
    bool grammar_found = true;
    bool rewriter_loaded = false;
    bool live_enabled = false;
    bool microphone_allowed = true;
    std::vector<std::pair<std::wstring, std::wstring>> hotkeys;  // name, combo ("" when lost)
    std::map<Feature, std::wstring> last_failures;
};

struct HealthRow {
    Feature feature;
    HealthState state;
    std::wstring detail;   // what is true now, one line
    std::wstring reason;   // why it is not working; empty when it is
    std::wstring fix;      // what to do; empty when nothing
    bool restartable = false;
};

std::vector<HealthRow> health_report(const HealthContext& context);
HealthRow health_row(Feature f, const HealthContext& context);

}  // namespace nib::app
