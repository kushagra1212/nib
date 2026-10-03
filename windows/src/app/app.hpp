#pragma once
#include <windows.h>

#include <map>
#include <memory>
#include <optional>
#include <string>
#include "app/dispatch.hpp"
#include "app/health.hpp"
#include "app/hotkeys.hpp"
#include "app/tray.hpp"
#include "inline/live_checker.hpp"
#include "lint/harper_engine.hpp"
#include "rewrite/model_catalog.hpp"
#include "rewrite/model_checker.hpp"
#include "speech/controllers.hpp"
#include "speech/dictation_overlay.hpp"
#include "speech/dictation_text.hpp"
#include "text/text_target.hpp"
#include "text/uia.hpp"
#include "ui/control_panel.hpp"
#include "ui/suggestion_panel.hpp"

namespace nib::app {

// Port of AppDelegate: owns every part of nib and wires them together.
// Everything here runs on the UI thread.
class App {
public:
    static constexpr UINT open_message = WM_APP + 5;  // a second launch asks the first to show itself
    static constexpr const wchar_t* window_class = L"nib.app";

    App();
    ~App();

    // `background`: started at sign-in, so no window -- only the tray.
    int run(bool background);

private:
    static LRESULT CALLBACK proc(HWND, UINT, WPARAM, LPARAM);
    LRESULT handle(UINT, WPARAM, LPARAM);

    void start_engines();
    void adopt_model(const std::optional<std::filesystem::path>& model);
    void start_live();
    void stop_live();
    void register_hotkeys();
    void claim_hotkeys_later();
    void show_menu();
    std::vector<MenuItem> menu();
    std::wstring status_line();

    // Features.
    void check_selection();
    void write_back(const std::u16string& edited);
    void offer_speech_model();
    void report_dictation(const std::u16string& why);
    std::optional<std::u16string> read_selection_for_speech();

    // Control panel host.
    ui::ControlPanel::Host panel_host();
    void open_panel(ui::ControlPanel::Section section = ui::ControlPanel::Section::status);
    HealthContext health();
    void test(Feature f, std::function<void(std::wstring)> done);
    std::wstring restart(Feature f);
    void restart_app();
    void install(const std::string& kind, const CatalogModel& model);
    void free_memory();
    void record_transcript(const std::u16string& text);

    HWND hwnd_ = nullptr;
    std::unique_ptr<Tray> tray_;
    std::unique_ptr<Hotkeys> hotkeys_;
    HICON icon_ = nullptr;

    std::shared_ptr<HarperEngine> harper_;
    std::shared_ptr<SerialQueue> lint_queue_;
    std::shared_ptr<RewriteEngine> rewriter_;
    std::shared_ptr<ModelChecker> model_;
    std::shared_ptr<SerialQueue> model_queue_;
    std::optional<std::filesystem::path> model_path_;

    std::unique_ptr<LiveChecker> live_;
    std::unique_ptr<ui::SuggestionPanel> panel_;
    std::unique_ptr<ui::ControlPanel> control_;
    std::unique_ptr<SpeechController> speech_;
    std::unique_ptr<DictationController> dictation_;
    std::unique_ptr<PracticeController> practice_;
    std::unique_ptr<DictationOverlay> overlay_;
    std::map<std::string, std::unique_ptr<ModelInstaller>> installers_;
    speech::DictationHistory history_;

    // The hotkey panel's target, held between opening and applying.
    std::shared_ptr<SerialQueue> uia_queue_;
    std::optional<text::TextTarget> target_;
    std::map<Feature, std::wstring> failures_;
    bool panel_busy_ = false;
};

}  // namespace nib::app
