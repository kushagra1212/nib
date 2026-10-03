#pragma once
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include "app/health.hpp"
#include "rewrite/model_catalog.hpp"
#include "ui/surface.hpp"
#include "ui/widgets.hpp"

namespace nib::ui {

// Port of the control panel design: one window, a sidebar, and everything nib
// knows in one findable place -- Status, Models, Voices, Dictation Words,
// Diagnostics. Opening it allocates nothing: every check is passive, and the
// expensive, truthful work is behind Test, for the one feature asked about.
class ControlPanel : public Surface {
public:
    enum class Section { status, models, voices, words, diagnostics };

    struct Host {
        std::function<app::HealthContext()> health;
        std::function<void(app::Feature, std::function<void(std::wstring)>)> test;
        std::function<std::wstring(app::Feature)> restart;
        std::function<void()> restart_app;
        std::function<void(app::Feature)> open_setup;

        // Models: the kind is "rewrite", "dictation" or "voice".
        std::function<void(const std::string& kind, const CatalogModel&)> install;
        std::function<void(const std::string& kind)> cancel_install;
        std::function<void(const std::string& kind, const std::filesystem::path&)> remove;
        std::function<void(const std::string& kind, const std::filesystem::path&)> use;
        std::function<std::optional<std::filesystem::path>(const std::string& kind)> active;

        std::function<std::vector<std::string>()> voices;
        std::function<std::string()> voice;
        std::function<void(const std::string&)> set_voice;
        std::function<void(const std::string&)> preview_voice;

        std::function<std::vector<std::pair<std::u16string, int64_t>>()> history;
        std::function<void(const std::u16string&)> copy;
        std::function<void()> clear_history;

        std::function<std::wstring()> live_report;
        std::function<void(std::function<void(std::wstring)>)> probe_field;
        std::function<std::wstring()> diagnostic_report;
        std::function<std::wstring()> footprint;
        std::function<void()> free_memory;
        std::function<bool()> live_enabled;
        std::function<void(bool)> set_live;
        std::function<bool()> login_enabled;
        std::function<void(bool)> set_login;
    };

    // Progress of a download, pushed in by the app.
    struct Install {
        std::wstring stage;  // "downloading", "verifying", "failed", ...
        double fraction = 0;
        std::wstring message;
        bool busy = false;
    };

    explicit ControlPanel(Host host);
    ~ControlPanel() override;

    void open(Section section = Section::status);
    void refresh();  // re-read everything passive
    void install_progress(const std::string& kind, const Install& progress);

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_move(float x, float y) override;
    void on_mouse_down(float x, float y) override;
    void on_mouse_up(float x, float y) override;
    void on_mouse_leave() override;
    void on_wheel(float delta) override;
    void on_resized() override;
    LRESULT on_message(UINT msg, WPARAM wp, LPARAM lp, bool& handled) override;

private:
    void select(Section s);
    void rebuild();
    void layout_children();
    float build_status(float y);
    float build_models(float y);
    float build_voices(float y);
    float build_words(float y);
    float build_diagnostics(float y);
    void model_rows(const std::string& kind, const std::vector<CatalogModel>& list, float& y);

    // Text drawn in the content area, positioned at build time.
    struct Label {
        std::wstring text;
        Font font;
        Colour colour;
        float x, y, width;
        int max_lines = 0;
    };
    struct Dot {
        float x, y;
        Colour colour;
    };
    struct Bar {
        D2D1_RECT_F rect;
        double fraction;
    };
    struct Panel {
        D2D1_RECT_F rect;
    };

    Host host_;
    Section section_ = Section::status;
    Buttons sidebar_;
    Buttons content_;
    std::vector<Label> labels_;
    std::vector<Dot> dots_;
    std::vector<Bar> bars_;
    std::vector<Panel> panels_;
    float scroll_ = 0;
    float content_height_ = 0;
    std::map<app::Feature, std::wstring> test_results_;
    std::map<std::string, Install> installs_;
    std::wstring probe_output_;

    HWND words_edit_ = nullptr;
    HWND log_edit_ = nullptr;
    HFONT edit_font_ = nullptr;
    HBRUSH edit_brush_ = nullptr;
    D2D1_RECT_F words_rect_{}, log_rect_{};
    UINT_PTR log_timer_ = 0;
};

}  // namespace nib::ui
