#include "text/uia.hpp"

#include <oleauto.h>

#include <algorithm>
#include <cwctype>

namespace nib::text {
namespace {

std::wstring bstr_value(IUIAutomationElement* e, PROPERTYID id) {
    VARIANT v;
    VariantInit(&v);
    std::wstring out;
    if (SUCCEEDED(e->GetCurrentPropertyValue(id, &v)) && v.vt == VT_BSTR && v.bstrVal) {
        out.assign(v.bstrVal, SysStringLen(v.bstrVal));
    }
    VariantClear(&v);
    return out;
}

bool bool_value(IUIAutomationElement* e, PROPERTYID id) {
    VARIANT v;
    VariantInit(&v);
    bool out = false;
    if (SUCCEEDED(e->GetCurrentPropertyValue(id, &v)) && v.vt == VT_BOOL) out = v.boolVal != VARIANT_FALSE;
    VariantClear(&v);
    return out;
}

std::u16string from_bstr(BSTR b) {
    if (!b) return {};
    return std::u16string(reinterpret_cast<const char16_t*>(b), SysStringLen(b));
}

std::wstring lower(std::wstring_view s) {
    std::wstring out(s);
    for (auto& c : out) c = static_cast<wchar_t>(std::towlower(c));
    return out;
}

std::vector<RECT> rects_from(SAFEARRAY* array) {
    std::vector<RECT> out;
    if (!array) return out;
    double* data = nullptr;
    if (SUCCEEDED(SafeArrayAccessData(array, reinterpret_cast<void**>(&data)))) {
        LONG lo = 0, hi = -1;
        SafeArrayGetLBound(array, 1, &lo);
        SafeArrayGetUBound(array, 1, &hi);
        const LONG count = hi - lo + 1;
        for (LONG i = 0; i + 3 < count; i += 4) {
            RECT r{static_cast<LONG>(data[i]), static_cast<LONG>(data[i + 1]),
                   static_cast<LONG>(data[i] + data[i + 2]), static_cast<LONG>(data[i + 1] + data[i + 3])};
            out.push_back(r);
        }
        SafeArrayUnaccessData(array);
    }
    SafeArrayDestroy(array);
    return out;
}

const wchar_t* role_name(CONTROLTYPEID type) {
    switch (type) {
    case UIA_EditControlTypeId:     return L"edit";
    case UIA_DocumentControlTypeId: return L"document";
    case UIA_ComboBoxControlTypeId: return L"combo box";
    case UIA_TextControlTypeId:     return L"text";
    case UIA_GroupControlTypeId:    return L"group";
    case UIA_CustomControlTypeId:   return L"custom";
    case UIA_PaneControlTypeId:     return L"pane";
    case UIA_WindowControlTypeId:   return L"window";
    default:                        return L"other";
    }
}

}  // namespace

bool mentions_secret(std::wstring_view label) {
    static const wchar_t* hints[] = {
        L"password", L"passcode", L"passphrase", L"secret", L"token", L"api key", L"apikey",
        L"private key", L"credential", L"cvv", L"pin", L"otp", L"verification code",
        L"security code", L"card number"};
    const auto l = lower(label);
    return std::any_of(std::begin(hints), std::end(hints),
                       [&](const wchar_t* h) { return l.find(h) != std::wstring::npos; });
}

bool may_read(const Field& f) {
    if (f.password) return false;
    if (mentions_secret(f.label)) return false;
    if (f.read_only) return false;
    // Roles that hold editable prose. Chromium and Electron expose a
    // contenteditable as a group or custom element carrying a text pattern, so
    // an editable text pattern counts whatever the role says.
    switch (f.control_type) {
    case UIA_EditControlTypeId:
    case UIA_DocumentControlTypeId:
    case UIA_ComboBoxControlTypeId:
        return true;
    default:
        return f.has_text;
    }
}

std::wstring process_name(DWORD pid) {
    std::wstring out;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return out;
    wchar_t path[MAX_PATH];
    DWORD n = MAX_PATH;
    if (QueryFullProcessImageNameW(p, 0, path, &n)) {
        out.assign(path, n);
        const auto slash = out.find_last_of(L"\\/");
        if (slash != std::wstring::npos) out = out.substr(slash + 1);
    }
    CloseHandle(p);
    return out;
}

bool is_elevated_window(HWND hwnd) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (!pid) return false;
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    // Refused outright is itself the sign: nib can open any process at its own
    // level.
    if (!p) return true;
    bool elevated = false;
    HANDLE token = nullptr;
    if (OpenProcessToken(p, TOKEN_QUERY, &token)) {
        TOKEN_ELEVATION e{};
        DWORD size = 0;
        if (GetTokenInformation(token, TokenElevation, &e, sizeof e, &size)) elevated = e.TokenIsElevated;
        CloseHandle(token);
    }
    CloseHandle(p);
    if (!elevated) return false;
    // Only a problem if nib itself is not elevated.
    HANDLE mine = nullptr;
    TOKEN_ELEVATION self{};
    DWORD size = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mine)) {
        GetTokenInformation(mine, TokenElevation, &self, sizeof self, &size);
        CloseHandle(mine);
    }
    return !self.TokenIsElevated;
}

Uia::Uia() {
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_ = SUCCEEDED(hr);
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&automation_)))) {
        CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&automation_));
    }
}

Uia& Uia::for_this_thread() {
    thread_local Uia instance;
    return instance;
}

Uia::~Uia() {
    automation_.Reset();
    if (com_) CoUninitialize();
}

std::optional<Field> Uia::focused() {
    if (!automation_) return std::nullopt;
    ComPtr<IUIAutomationElement> e;
    if (FAILED(automation_->GetFocusedElement(&e)) || !e) return std::nullopt;
    return describe(e.Get());
}

std::optional<Field> Uia::describe(IUIAutomationElement* element) {
    if (!element) return std::nullopt;
    Field f;
    f.element = element;
    element->get_CurrentControlType(&f.control_type);
    f.role = role_name(f.control_type);
    f.password = bool_value(element, UIA_IsPasswordPropertyId);

    std::wstring label;
    for (PROPERTYID id : {UIA_NamePropertyId, UIA_HelpTextPropertyId, UIA_FullDescriptionPropertyId,
                          UIA_LocalizedControlTypePropertyId}) {
        const auto part = bstr_value(element, id);
        if (part.empty() || id == UIA_LocalizedControlTypePropertyId) continue;
        if (!label.empty()) label += L' ';
        label += part;
    }
    f.label = label;

    int pid = 0;
    element->get_CurrentProcessId(&pid);
    f.pid = static_cast<DWORD>(pid);
    f.app = process_name(f.pid);

    UIA_HWND handle = nullptr;
    element->get_CurrentNativeWindowHandle(&handle);
    HWND hwnd = static_cast<HWND>(handle);
    if (!hwnd) hwnd = GetForegroundWindow();
    f.window = hwnd ? GetAncestor(hwnd, GA_ROOT) : nullptr;

    ComPtr<IUIAutomationTextPattern> text;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&text))) && text) {
        f.has_text = true;
    }
    ComPtr<IUIAutomationValuePattern> value;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value))) && value) {
        f.has_value = true;
        BOOL ro = FALSE;
        value->get_CurrentIsReadOnly(&ro);
        f.read_only = ro != FALSE;
    } else if (f.has_text) {
        // A text pattern with no value pattern is read-only unless it says
        // otherwise; Chromium's contenteditable advertises it.
        f.read_only = bool_value(element, UIA_ValueIsReadOnlyPropertyId)
                      && f.control_type != UIA_DocumentControlTypeId
                      && f.control_type != UIA_EditControlTypeId;
    }
    return f;
}

std::optional<std::u16string> Uia::text(const Field& field) {
    if (!field.element) return std::nullopt;
    ComPtr<IUIAutomationTextPattern> pattern;
    if (field.has_text
        && SUCCEEDED(field.element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern)))
        && pattern) {
        ComPtr<IUIAutomationTextRange> doc;
        if (SUCCEEDED(pattern->get_DocumentRange(&doc)) && doc) {
            BSTR b = nullptr;
            if (SUCCEEDED(doc->GetText(-1, &b))) {
                auto out = from_bstr(b);
                SysFreeString(b);
                return out;
            }
        }
    }
    ComPtr<IUIAutomationValuePattern> value;
    if (field.has_value
        && SUCCEEDED(field.element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value)))
        && value) {
        BSTR b = nullptr;
        if (SUCCEEDED(value->get_CurrentValue(&b))) {
            auto out = from_bstr(b);
            SysFreeString(b);
            return out;
        }
    }
    return std::nullopt;
}

std::optional<Uia::Selection> Uia::selection(const Field& field) {
    if (!field.element || !field.has_text) return std::nullopt;
    ComPtr<IUIAutomationTextPattern> pattern;
    if (FAILED(field.element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) || !pattern) {
        return std::nullopt;
    }
    ComPtr<IUIAutomationTextRangeArray> ranges;
    if (FAILED(pattern->GetSelection(&ranges)) || !ranges) return std::nullopt;
    int count = 0;
    ranges->get_Length(&count);
    if (count < 1) return std::nullopt;
    ComPtr<IUIAutomationTextRange> sel;
    if (FAILED(ranges->GetElement(0, &sel)) || !sel) return std::nullopt;

    Selection out;
    BSTR b = nullptr;
    if (SUCCEEDED(sel->GetText(-1, &b))) {
        out.text = from_bstr(b);
        SysFreeString(b);
    }
    out.range = {0, static_cast<int32_t>(out.text.size())};

    // The offset is measured as the length of the text before the selection:
    // a range from the document start to the selection start.
    ComPtr<IUIAutomationTextRange> doc, before;
    if (SUCCEEDED(pattern->get_DocumentRange(&doc)) && doc && SUCCEEDED(doc->Clone(&before)) && before) {
        if (SUCCEEDED(before->MoveEndpointByRange(TextPatternRangeEndpoint_End, sel.Get(),
                                                  TextPatternRangeEndpoint_Start))) {
            BSTR head = nullptr;
            if (SUCCEEDED(before->GetText(-1, &head))) {
                out.range.location = static_cast<int32_t>(SysStringLen(head));
                out.absolute = true;
                SysFreeString(head);
            }
        }
    }
    return out;
}

ComPtr<IUIAutomationTextRange> Uia::range_for(const Field& field, nib_range range) {
    ComPtr<IUIAutomationTextPattern> pattern;
    if (!field.element || !field.has_text
        || FAILED(field.element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) || !pattern) {
        return nullptr;
    }
    ComPtr<IUIAutomationTextRange> doc, r;
    if (FAILED(pattern->get_DocumentRange(&doc)) || !doc || FAILED(doc->Clone(&r)) || !r) return nullptr;

    // Collapse to the start, then walk both ends by characters. A text
    // pattern's character unit is a UTF-16 unit in Edit, RichEdit and
    // Chromium, which is what the offsets are.
    r->MoveEndpointByRange(TextPatternRangeEndpoint_End, r.Get(), TextPatternRangeEndpoint_Start);
    int moved = 0;
    if (range.location > 0) {
        r->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, range.location, &moved);
        r->MoveEndpointByRange(TextPatternRangeEndpoint_Start, r.Get(), TextPatternRangeEndpoint_End);
    }
    if (range.length > 0) {
        r->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, range.length, &moved);
    }
    return r;
}

std::vector<RECT> Uia::bounds(const Field& field, nib_range range) {
    auto r = range_for(field, range);
    if (!r) return {};
    SAFEARRAY* array = nullptr;
    if (FAILED(r->GetBoundingRectangles(&array))) return {};
    auto rects = rects_from(array);
    // An app that declines answers with nothing or with zero-sized boxes;
    // neither can be drawn under.
    rects.erase(std::remove_if(rects.begin(), rects.end(),
                               [](const RECT& x) { return x.right - x.left < 1 || x.bottom - x.top < 2; }),
                rects.end());
    return rects;
}

std::vector<RECT> Uia::selection_bounds(const Field& field) {
    ComPtr<IUIAutomationTextPattern> pattern;
    if (!field.element || !field.has_text
        || FAILED(field.element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) || !pattern) {
        return {};
    }
    ComPtr<IUIAutomationTextRangeArray> ranges;
    if (FAILED(pattern->GetSelection(&ranges)) || !ranges) return {};
    ComPtr<IUIAutomationTextRange> sel;
    if (FAILED(ranges->GetElement(0, &sel)) || !sel) return {};
    SAFEARRAY* array = nullptr;
    if (FAILED(sel->GetBoundingRectangles(&array))) return {};
    return rects_from(array);
}

std::optional<RECT> Uia::frame(const Field& field) {
    if (!field.element) return std::nullopt;
    RECT r{};
    if (FAILED(field.element->get_CurrentBoundingRectangle(&r))) return std::nullopt;
    if (r.right - r.left < 2 || r.bottom - r.top < 2) return std::nullopt;
    return r;
}

bool Uia::select(const Field& field, nib_range range) {
    auto r = range_for(field, range);
    return r && SUCCEEDED(r->Select());
}

bool Uia::set_value(const Field& field, const std::u16string& value) {
    ComPtr<IUIAutomationValuePattern> pattern;
    if (!field.element
        || FAILED(field.element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&pattern))) || !pattern) {
        return false;
    }
    BSTR b = SysAllocStringLen(reinterpret_cast<const OLECHAR*>(value.data()), static_cast<UINT>(value.size()));
    const bool ok = SUCCEEDED(pattern->SetValue(b));
    SysFreeString(b);
    return ok;
}

bool Uia::focus(const Field& field) {
    return field.element && SUCCEEDED(field.element->SetFocus());
}

}  // namespace nib::text
