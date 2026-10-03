#pragma once
#include <functional>
#include <optional>
#include <string>
#include <vector>
#include "lint/suggestion.hpp"
#include "rewrite/rewrite_mode.hpp"
#include "rewrite/rewrite_text.hpp"
#include "ui/surface.hpp"
#include "ui/widgets.hpp"

namespace nib::ui {

// Port of SuggestionPanel: the hotkey surface, for fields where underlines
// cannot be placed. A card: header, the text (editable), the fixes, then the
// actions -- Fix, Clearer, Shorter, Native, Esc, Replace.
class SuggestionPanel : public Surface {
public:
    struct RewriteResult {
        std::optional<std::u16string> text;
        std::u16string error;  // shown when `text` is empty
    };

    struct Callbacks {
        std::function<void(const std::u16string&)> apply;
        // Fills replacements for the visible suggestions, then calls back.
        std::function<void(std::vector<Suggestion>, std::u16string,
                           std::function<void(std::vector<Suggestion>)>)> fill_fixes;
        std::function<void(std::u16string, RewriteMode, std::function<void(RewriteResult)>)> rewrite;
        std::function<void()> closed;
    };

    SuggestionPanel();
    ~SuggestionPanel() override;

    void present(const std::u16string& text, POINT anchor, Callbacks callbacks);
    void show_found(std::vector<Suggestion> found);
    void show_error(const std::wstring& message);
    void dismiss();

protected:
    void paint(ID2D1RenderTarget* rt) override;
    void on_mouse_move(float x, float y) override;
    void on_mouse_down(float x, float y) override;
    void on_mouse_up(float x, float y) override;
    void on_mouse_leave() override;
    bool on_key(WPARAM key) override;
    LRESULT on_message(UINT msg, WPARAM wp, LPARAM lp, bool& handled) override;

private:
    std::u16string current_text() const;
    void set_text(const std::u16string& text);
    void decorate();
    void layout_controls();
    void relayout();
    void set_status(std::wstring text, Colour tint, bool busy = false);
    void apply_fix(size_t index, const std::u16string& replacement);
    void run_rewrite(RewriteMode mode);
    void undo_rewrite();
    void accept();

    static LRESULT CALLBACK edit_proc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);

    HWND edit_ = nullptr;
    Callbacks callbacks_;
    std::vector<Suggestion> suggestions_;
    std::optional<std::u16string> before_rewrite_;
    std::wstring status_;
    Colour status_tint_ = colour::ink_muted;
    bool busy_ = false;
    float text_height_ = 24;
    float rows_top_ = 0;

    Buttons buttons_;          // fixes and actions, rebuilt on every change
    std::vector<size_t> mode_buttons_;
    HFONT font_ = nullptr;
    HBRUSH field_brush_ = nullptr;
    bool rewriting_ = false;
};

}  // namespace nib::ui
