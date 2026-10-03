#include "ui/gfx.hpp"

#include <shellscalingapi.h>

#include <cmath>
#include <map>

namespace nib::ui {

ID2D1Factory1* d2d() {
    static ComPtr<ID2D1Factory1> factory = [] {
        ComPtr<ID2D1Factory1> f;
        D2D1_FACTORY_OPTIONS options{};
        D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), &options,
                          reinterpret_cast<void**>(f.GetAddressOf()));
        return f;
    }();
    return factory.Get();
}

IDWriteFactory* dwrite() {
    static ComPtr<IDWriteFactory> factory = [] {
        ComPtr<IDWriteFactory> f;
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                            reinterpret_cast<IUnknown**>(f.GetAddressOf()));
        return f;
    }();
    return factory.Get();
}

IDWriteTextFormat* format(Font font) {
    static std::map<Font, ComPtr<IDWriteTextFormat>> cache;
    auto& slot = cache[font];
    if (slot) return slot.Get();

    // macOS draws nib in the system serif. Georgia is the Windows serif built
    // for screens, and keeps the same bookish register; Segoe UI carries the
    // controls, where a serif at 11pt costs legibility.
    const wchar_t* family = L"Georgia";
    float size = 13;
    DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_REGULAR;
    switch (font) {
    case Font::body:      size = 13.5f; break;
    case Font::diff:      size = 14; break;
    case Font::diff_bold: size = 14; weight = DWRITE_FONT_WEIGHT_SEMI_BOLD; break;
    case Font::control:   family = L"Segoe UI"; size = 12; weight = DWRITE_FONT_WEIGHT_SEMI_BOLD; break;
    case Font::caption:   family = L"Segoe UI"; size = 12; break;
    case Font::title:     family = L"Segoe UI"; size = 12; weight = DWRITE_FONT_WEIGHT_SEMI_BOLD; break;
    case Font::heading:   size = 17; weight = DWRITE_FONT_WEIGHT_SEMI_BOLD; break;
    case Font::row_title: size = 14; weight = DWRITE_FONT_WEIGHT_SEMI_BOLD; break;
    case Font::tag:       family = L"Segoe UI"; size = 10; weight = DWRITE_FONT_WEIGHT_BOLD; break;
    case Font::mono:      family = L"Cascadia Mono"; size = 12; break;
    }
    dwrite()->CreateTextFormat(family, nullptr, weight, DWRITE_FONT_STYLE_NORMAL,
                               DWRITE_FONT_STRETCH_NORMAL, size, L"", slot.GetAddressOf());
    if (!slot && font == Font::mono) {
        dwrite()->CreateTextFormat(L"Consolas", nullptr, weight, DWRITE_FONT_STYLE_NORMAL,
                                   DWRITE_FONT_STRETCH_NORMAL, size, L"", slot.GetAddressOf());
    }
    return slot.Get();
}

void TextBlock::draw(ID2D1RenderTarget* rt, float x, float y, Colour colour) const {
    if (!layout) return;
    ComPtr<ID2D1SolidColorBrush> brush;
    rt->CreateSolidColorBrush(colour.d2d(), &brush);
    rt->DrawTextLayout({x, y}, layout.Get(), brush.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

TextBlock layout(std::wstring_view text, Font font, float max_width, int max_lines, bool centred) {
    TextBlock block;
    dwrite()->CreateTextLayout(text.data(), static_cast<UINT32>(text.size()), format(font),
                               max_width, 10'000.f, &block.layout);
    if (!block.layout) return block;
    block.layout->SetWordWrapping(max_width < 9'000.f ? DWRITE_WORD_WRAPPING_WRAP
                                                      : DWRITE_WORD_WRAPPING_NO_WRAP);
    if (centred) block.layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);

    DWRITE_TEXT_METRICS m{};
    block.layout->GetMetrics(&m);
    block.lines = static_cast<int>(m.lineCount);
    block.width = m.widthIncludingTrailingWhitespace;
    block.height = m.height;

    if (max_lines > 0 && block.lines > max_lines) {
        // Trimmed with an ellipsis at the last visible line.
        DWRITE_LINE_METRICS lines[256];
        UINT32 count = 0;
        block.layout->GetLineMetrics(lines, 256, &count);
        float h = 0;
        for (int i = 0; i < max_lines && i < static_cast<int>(count); ++i) h += lines[i].height;
        block.layout->SetMaxHeight(h);
        DWRITE_TRIMMING trim{DWRITE_TRIMMING_GRANULARITY_WORD, 0, 0};
        ComPtr<IDWriteInlineObject> ellipsis;
        dwrite()->CreateEllipsisTrimmingSign(format(font), &ellipsis);
        block.layout->SetTrimming(&trim, ellipsis.Get());
        block.height = h;
        block.lines = max_lines;
    }
    return block;
}

namespace {

ComPtr<ID2D1SolidColorBrush> brush(ID2D1RenderTarget* rt, Colour c) {
    ComPtr<ID2D1SolidColorBrush> b;
    rt->CreateSolidColorBrush(c.d2d(), &b);
    return b;
}

}  // namespace

void fill_round(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius, Colour c) {
    rt->FillRoundedRectangle({r, radius, radius}, brush(rt, c).Get());
}

void stroke_round(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius, Colour c, float width) {
    const float h = width / 2;
    rt->DrawRoundedRectangle({{r.left + h, r.top + h, r.right - h, r.bottom - h}, radius, radius},
                             brush(rt, c).Get(), width);
}

void line(ID2D1RenderTarget* rt, D2D1_POINT_2F a, D2D1_POINT_2F b, Colour c, float width) {
    rt->DrawLine(a, b, brush(rt, c).Get(), width);
}

void aurora(ID2D1RenderTarget* rt, D2D1_RECT_F r, float radius) {
    ComPtr<ID2D1RoundedRectangleGeometry> clip;
    d2d()->CreateRoundedRectangleGeometry({r, radius, radius}, &clip);
    ComPtr<ID2D1Layer> layer;
    rt->CreateLayer(&layer);
    rt->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), clip.Get()), layer.Get());

    rt->FillRectangle(r, brush(rt, colour::base).Get());

    // Three lights at fixed places, as on macOS: verdigris top left, violet
    // low centre, blue right -- at 0.28, under the text rather than behind it.
    struct Light { Colour c; float x, y, radius; };
    const Light plan[] = {
        {{0.22f, 0.78f, 0.72f, 1}, 0.12f, 0.15f, 0.55f},
        {{0.55f, 0.36f, 0.92f, 1}, 0.62f, 0.85f, 0.70f},
        {{0.20f, 0.52f, 0.95f, 1}, 0.95f, 0.25f, 0.60f},
    };
    const float w = r.right - r.left, h = r.bottom - r.top;
    const float extent = std::max(w, h);
    for (const auto& l : plan) {
        D2D1_GRADIENT_STOP stops[3] = {
            {0.f, l.c.with_alpha(0.28f).d2d()},
            {0.45f, l.c.with_alpha(0.28f * 0.35f).d2d()},
            {1.f, l.c.with_alpha(0.f).d2d()},
        };
        ComPtr<ID2D1GradientStopCollection> collection;
        rt->CreateGradientStopCollection(stops, 3, &collection);
        ComPtr<ID2D1RadialGradientBrush> radial;
        const D2D1_POINT_2F centre{r.left + w * l.x, r.top + h * l.y};
        rt->CreateRadialGradientBrush(
            D2D1::RadialGradientBrushProperties(centre, {0, 0}, extent * l.radius, extent * l.radius),
            collection.Get(), &radial);
        rt->FillRectangle(r, radial.Get());
    }
    rt->PopLayer();
    stroke_round(rt, r, radius, colour::control_fill(0.16f));
}

void squiggle(ID2D1RenderTarget* rt, float x0, float x1, float baseline, Colour c, float scale) {
    if (x1 <= x0) return;
    ComPtr<ID2D1PathGeometry> path;
    d2d()->CreatePathGeometry(&path);
    ComPtr<ID2D1GeometrySink> sink;
    path->Open(&sink);
    const float amplitude = 1.4f * scale;
    const float period = 4.f * scale;
    sink->BeginFigure({x0, baseline}, D2D1_FIGURE_BEGIN_HOLLOW);
    bool up = true;
    for (float x = x0; x < x1; x += period / 2) {
        const float nx = std::min(x + period / 2, x1);
        sink->AddQuadraticBezier({{(x + nx) / 2, baseline + (up ? -amplitude : amplitude) * 1.6f},
                                  {nx, baseline}});
        up = !up;
    }
    sink->EndFigure(D2D1_FIGURE_END_OPEN);
    sink->Close();
    rt->DrawGeometry(path.Get(), brush(rt, c).Get(), 1.5f * scale);
}

float scale_for(HWND hwnd) {
    const UINT dpi = hwnd ? GetDpiForWindow(hwnd) : 96;
    return (dpi ? dpi : 96) / 96.f;
}

float scale_for_point(POINT p) {
    HMONITOR monitor = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
    UINT x = 96, y = 96;
    if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y))) return 1.f;
    return x / 96.f;
}

}  // namespace nib::ui
