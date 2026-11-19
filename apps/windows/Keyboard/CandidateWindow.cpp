#include "CandidateWindow.h"
#include "TextService.h"
#include <d2d1.h>
#include <dwrite.h>
#include <algorithm>
#include <cmath>
#include <strsafe.h>
#include <windowsx.h>

// The pill panel: the composer's page as numbered pills with the highlighted
// one filled, chevrons to page, a click to pick. The look is the Linux and
// macOS panel (BYK_CSS in apps/linux/App/main.c, apps/macos/Core/Composer/
// CandidatePanel.swift): change them together. Drawn with Direct2D and
// DirectWrite into a per-pixel-alpha layered window, so the corners are
// round and anti-aliased, Bangla is shaped, and light, dark and high
// contrast follow the system.

namespace
{
constexpr wchar_t kClassName[] = L"ByakaronCandidateWindow";

// Metrics at 96 DPI, in the Linux panel's terms.
constexpr float kWordSize = 16.0f;      // the candidate
constexpr float kNumberSize = 11.0f;    // its number
constexpr float kPillPadding = 2.0f;    // panel edge to pills
constexpr float kItemPadding = 9.0f;    // pill edge to text
constexpr float kNumberGap = 4.0f;
constexpr float kChevronWidth = 16.0f;
constexpr float kShadow = 8.0f;         // room around the panel for its shadow
constexpr UINT32 kAccent = 0x0A84FF;    // the selected pill

template <class T> void SafeRelease(T*& p)
{
    if (p) { p->Release(); p = nullptr; }
}

D2D1_COLOR_F Rgb(UINT32 rgb, float a = 1.0f)
{
    return D2D1::ColorF(rgb, a);
}

D2D1_COLOR_F FromColorRef(COLORREF c, float a = 1.0f)
{
    return D2D1::ColorF(GetRValue(c) / 255.0f, GetGValue(c) / 255.0f, GetBValue(c) / 255.0f, a);
}

// Apps use the dark theme (Settings → Personalization → Colors).
bool AppsUseDarkTheme()
{
    DWORD light = 1, size = sizeof(light);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size) != ERROR_SUCCESS)
        return false;
    return light == 0;
}

bool HighContrast()
{
    HIGHCONTRASTW hc = { sizeof(hc) };
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0) && (hc.dwFlags & HCF_HIGHCONTRASTON);
}

struct Palette
{
    D2D1_COLOR_F background, border, text, number, hover, selected, selectedText, selectedNumber, shadow;
};

Palette CurrentPalette()
{
    if (HighContrast())
    {
        const COLORREF fg = GetSysColor(COLOR_WINDOWTEXT);
        return {
            FromColorRef(GetSysColor(COLOR_WINDOW)), FromColorRef(fg), FromColorRef(fg), FromColorRef(fg),
            FromColorRef(fg, 0.15f), FromColorRef(GetSysColor(COLOR_HIGHLIGHT)),
            FromColorRef(GetSysColor(COLOR_HIGHLIGHTTEXT)), FromColorRef(GetSysColor(COLOR_HIGHLIGHTTEXT)),
            D2D1::ColorF(0, 0.0f),
        };
    }
    if (AppsUseDarkTheme())
    {
        // Windows' dark surface, lifted 4% toward the text like the Linux pill.
        return {
            Rgb(0x2B2B2B), Rgb(0xFFFFFF, 0.12f), Rgb(0xFFFFFF), Rgb(0xFFFFFF, 0.6f), Rgb(0xFFFFFF, 0.09f),
            Rgb(kAccent), Rgb(0xFFFFFF), Rgb(0xFFFFFF, 0.9f), Rgb(0x000000, 0.10f),
        };
    }
    return {
        Rgb(0xF6F6F6), Rgb(0x000000, 0.12f), Rgb(0x1A1A1A), Rgb(0x000000, 0.6f), Rgb(0x000000, 0.09f),
        Rgb(kAccent), Rgb(0xFFFFFF), Rgb(0xFFFFFF, 0.9f), Rgb(0x000000, 0.05f),
    };
}

// Width and height of `text` in `format`, unwrapped.
D2D1_SIZE_F Measure(IDWriteFactory* dw, IDWriteTextFormat* format, const std::wstring& text)
{
    IDWriteTextLayout* layout = nullptr;
    D2D1_SIZE_F size = { 0, 0 };
    if (SUCCEEDED(dw->CreateTextLayout(text.c_str(), (UINT32)text.size(), format, 10000.0f, 10000.0f, &layout)))
    {
        DWRITE_TEXT_METRICS m = {};
        if (SUCCEEDED(layout->GetMetrics(&m))) size = { m.widthIncludingTrailingWhitespace, m.height };
        layout->Release();
    }
    return size;
}

// {B1A7C0DE-5E11-4B00-9A02-B1A7C0DE5E11}
static const GUID GUID_ByakaronCandidateUI =
{
    0xB1A7C0DE, 0x5E11, 0x4B00,
    { 0x9A, 0x02, 0xB1, 0xA7, 0xC0, 0xDE, 0x5E, 0x11 }
};
}

CandidateWindow::CandidateWindow(CByakaronTextService* svc)
    : _svc(svc)
{
}

CandidateWindow::~CandidateWindow()
{
    End();
    if (_hwnd)
    {
        DestroyWindow(_hwnd);
        _hwnd = nullptr;
    }
    ReleaseGraphics();
}

bool CandidateWindow::Box::Contains(float x, float y) const
{
    return x >= left && x < right && y >= top && y < bottom;
}

STDMETHODIMP CandidateWindow::QueryInterface(REFIID riid, void** ppvObj)
{
    if (!ppvObj) return E_INVALIDARG;
    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown) ||
        IsEqualIID(riid, IID_ITfUIElement) ||
        IsEqualIID(riid, IID_ITfCandidateListUIElement) ||
        IsEqualIID(riid, IID_ITfCandidateListUIElementBehavior))
    {
        *ppvObj = static_cast<ITfCandidateListUIElementBehavior*>(this);
    }
    else
    {
        return E_NOINTERFACE;
    }

    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CandidateWindow::AddRef()
{
    return (ULONG)InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) CandidateWindow::Release()
{
    // Lifetime is owned by CByakaronTextService (member); never delete here.
    return (ULONG)InterlockedDecrement(&_refCount);
}

STDMETHODIMP CandidateWindow::GetDescription(BSTR* pbstrDescription)
{
    if (!pbstrDescription) return E_INVALIDARG;
    *pbstrDescription = SysAllocString(L"Byakaron Candidate List");
    return *pbstrDescription ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP CandidateWindow::GetGUID(GUID* pguid)
{
    if (!pguid) return E_INVALIDARG;
    *pguid = GUID_ByakaronCandidateUI;
    return S_OK;
}

STDMETHODIMP CandidateWindow::Show(BOOL bShow)
{
    // Host (or TSF) may ask us to show/hide our own UI.
    _hostAllowsTipUi = bShow ? true : _hostAllowsTipUi;
    ShowTipWindow(bShow);
    return S_OK;
}

STDMETHODIMP CandidateWindow::IsShown(BOOL* pbShow)
{
    if (!pbShow) return E_INVALIDARG;
    *pbShow = (_inShowMode && _visible) ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP CandidateWindow::GetUpdatedFlags(DWORD* pdwFlags)
{
    if (!pdwFlags) return E_INVALIDARG;
    *pdwFlags = _updatedFlags;
    return S_OK;
}

STDMETHODIMP CandidateWindow::GetDocumentMgr(ITfDocumentMgr** ppdim)
{
    if (!ppdim) return E_INVALIDARG;
    *ppdim = nullptr;
    if (!_svc || !_svc->GetThreadMgr()) return E_FAIL;
    return _svc->GetThreadMgr()->GetFocus(ppdim);
}

STDMETHODIMP CandidateWindow::GetCount(UINT* puCount)
{
    if (!puCount) return E_INVALIDARG;
    *puCount = (UINT)_items.size();
    return S_OK;
}

STDMETHODIMP CandidateWindow::GetSelection(UINT* puIndex)
{
    if (!puIndex) return E_INVALIDARG;
    if (_items.empty()) return S_FALSE;
    *puIndex = _selection;
    return S_OK;
}

STDMETHODIMP CandidateWindow::GetString(UINT uIndex, BSTR* pstr)
{
    if (!pstr) return E_INVALIDARG;
    *pstr = nullptr;
    if (uIndex >= _items.size()) return E_INVALIDARG;
    *pstr = SysAllocString(_items[uIndex].c_str());
    return *pstr ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP CandidateWindow::GetPageIndex(UINT* pIndex, UINT uSize, UINT* puPageCnt)
{
    if (!puPageCnt) return E_INVALIDARG;
    *puPageCnt = _pageCount;
    if (pIndex && uSize > 0)
    {
        pIndex[0] = _pageIndex[0];
    }
    return S_OK;
}

STDMETHODIMP CandidateWindow::SetPageIndex(UINT* pIndex, UINT uPageCnt)
{
    if (!pIndex || uPageCnt == 0) return E_INVALIDARG;
    _pageIndex[0] = pIndex[0];
    _pageCount = 1;
    return S_OK;
}

STDMETHODIMP CandidateWindow::GetCurrentPage(UINT* puPage)
{
    if (!puPage) return E_INVALIDARG;
    *puPage = 0;
    return S_OK;
}

// A UI-less host chose a candidate of the page it was given: the composer
// commits it (it owns highlighting and paging).
STDMETHODIMP CandidateWindow::SetSelection(UINT nIndex)
{
    if (nIndex >= _items.size()) return E_INVALIDARG;
    if (_svc) _svc->OnCandidatePicked(nIndex);
    return S_OK;
}

STDMETHODIMP CandidateWindow::Finalize()
{
    if (_svc) _svc->OnCandidateFinalize(true);
    End();
    return S_OK;
}

STDMETHODIMP CandidateWindow::Abort()
{
    if (_svc) _svc->OnCandidateFinalize(false);
    End();
    return S_OK;
}

bool CandidateWindow::EnsureWindow()
{
    if (_hwnd) return true;

    WNDCLASSEXW wc = { sizeof(wc) };
    if (!GetClassInfoExW(g_hInst, kClassName, &wc))
    {
        wc.lpfnWndProc = WndProc;
        wc.hInstance = g_hInst;
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.lpszClassName = kClassName;
        if (!RegisterClassExW(&wc)) return false;
    }

    // Layered: the pixels, alpha and all, come from Render.
    _hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
        kClassName,
        L"",
        WS_POPUP,
        0, 0, 0, 0,
        nullptr,
        nullptr,
        g_hInst,
        this);

    return _hwnd != nullptr;
}

bool CandidateWindow::EnsureGraphics()
{
    if (!_d2d && FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory),
                                          nullptr, reinterpret_cast<void**>(&_d2d))))
        return false;
    if (!_dwrite && FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                               reinterpret_cast<IUnknown**>(&_dwrite))))
        return false;
    if (!_target)
    {
        // Software: a few pills do not need the GPU, and this runs inside
        // whatever app is being typed in.
        const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f, 96.0f);
        if (FAILED(_d2d->CreateDCRenderTarget(&props, &_target))) return false;
    }
    return true;
}

void CandidateWindow::ReleaseGraphics()
{
    SafeRelease(_wordFormat);
    SafeRelease(_numberFormat);
    SafeRelease(_target);
    SafeRelease(_dwrite);
    SafeRelease(_d2d);
    _formatScale = 0;
}

// Pixels per 96 DPI pixel where the panel goes, as this thread sees them: a
// DPI-unaware app is scaled by Windows, so it gets 1.
float CandidateWindow::ScaleAt(const RECT& anchor) const
{
    using GetThreadCtxFn = HANDLE(WINAPI*)();
    using GetAwarenessFn = int(WINAPI*)(HANDLE);
    using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
    static const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    static const auto getCtx = user32 ? (GetThreadCtxFn)GetProcAddress(user32, "GetThreadDpiAwarenessContext") : nullptr;
    static const auto getAwareness = user32 ? (GetAwarenessFn)GetProcAddress(user32, "GetAwarenessFromDpiAwarenessContext") : nullptr;

    int awareness = -1;
    if (getCtx && getAwareness) awareness = getAwareness(getCtx());
    if (awareness == 0) return 1.0f; // DPI_AWARENESS_UNAWARE
    if (awareness == 2)              // DPI_AWARENESS_PER_MONITOR_AWARE
    {
        static const HMODULE shcore = LoadLibraryExW(L"shcore.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        static const auto getDpi = shcore ? (GetDpiForMonitorFn)GetProcAddress(shcore, "GetDpiForMonitor") : nullptr;
        UINT x = 0, y = 0;
        if (getDpi && SUCCEEDED(getDpi(MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST), 0, &x, &y)) && y)
            return y / 96.0f;
    }
    HDC screen = GetDC(nullptr);
    const int dpi = screen ? GetDeviceCaps(screen, LOGPIXELSY) : 96;
    if (screen) ReleaseDC(nullptr, screen);
    return (dpi > 0 ? dpi : 96) / 96.0f;
}

void CandidateWindow::Present(const std::vector<std::wstring>& items, int highlight, bool vertical,
                              size_t page, size_t pageCount, const RECT& anchor)
{
    if (items.empty())
    {
        End();
        return;
    }

    _items = items;
    _vertical = vertical;
    _page = page;
    _pageTotal = pageCount > 0 ? pageCount : 1;
    _anchor = anchor;
    _hover = -1;
    if (highlight < 0) highlight = 0;
    if (highlight >= (int)_items.size()) highlight = (int)_items.size() - 1;
    _selection = (UINT)highlight;
    _pageIndex[0] = 0;
    _pageCount = 1;
    _updatedFlags =
        TF_CLUIE_DOCUMENTMGR |
        TF_CLUIE_COUNT |
        TF_CLUIE_SELECTION |
        TF_CLUIE_STRING |
        TF_CLUIE_PAGEINDEX |
        TF_CLUIE_CURRENTPAGE;

    if (!_inShowMode)
    {
        BOOL bShow = TRUE;
        ITfUIElementMgr* mgr = nullptr;
        if (_svc && _svc->GetThreadMgr() &&
            SUCCEEDED(_svc->GetThreadMgr()->QueryInterface(IID_ITfUIElementMgr, (void**)&mgr)) && mgr)
        {
            mgr->BeginUIElement(this, &bShow, &_uiElementId);
            // When bShow is FALSE the host draws candidates from this UIElement.
            if (!bShow)
            {
                mgr->UpdateUIElement(_uiElementId);
            }
            mgr->Release();
        }
        _hostAllowsTipUi = (bShow != FALSE);
        _inShowMode = true;
    }
    else
    {
        CallUpdateUIElement();
    }

    if (_hostAllowsTipUi && EnsureWindow())
    {
        Render();
        ShowWindow(_hwnd, SW_SHOWNA);
        _visible = true;
    }
    else
    {
        ShowTipWindow(FALSE);
    }
}

void CandidateWindow::End()
{
    if (!_inShowMode) return;

    ShowTipWindow(FALSE);

    ITfUIElementMgr* mgr = nullptr;
    if (_svc && _svc->GetThreadMgr() &&
        SUCCEEDED(_svc->GetThreadMgr()->QueryInterface(IID_ITfUIElementMgr, (void**)&mgr)) && mgr)
    {
        if (_uiElementId != (DWORD)-1)
        {
            mgr->EndUIElement(_uiElementId);
        }
        mgr->Release();
    }

    _uiElementId = (DWORD)-1;
    _inShowMode = false;
    _hostAllowsTipUi = true;
    _items.clear();
    _selection = 0;
    _hover = -1;
}

void CandidateWindow::CallUpdateUIElement()
{
    if (!_inShowMode) return;
    // When we show our own window, UpdateUIElement is optional; when UI-less, required.
    if (_hostAllowsTipUi && _visible) return;

    ITfUIElementMgr* mgr = nullptr;
    if (_svc && _svc->GetThreadMgr() &&
        SUCCEEDED(_svc->GetThreadMgr()->QueryInterface(IID_ITfUIElementMgr, (void**)&mgr)) && mgr)
    {
        if (_uiElementId != (DWORD)-1)
        {
            mgr->UpdateUIElement(_uiElementId);
        }
        mgr->Release();
    }
}

void CandidateWindow::ShowTipWindow(BOOL show)
{
    if (!show)
    {
        if (_hwnd) ShowWindow(_hwnd, SW_HIDE);
        _visible = false;
        return;
    }
    if (_hwnd && _inShowMode && _hostAllowsTipUi && !_items.empty())
    {
        Render();
        ShowWindow(_hwnd, SW_SHOWNA);
        _visible = true;
    }
}

void CandidateWindow::Render()
{
    if (!_hwnd || _items.empty() || !EnsureGraphics()) return;

    const float scale = ScaleAt(_anchor);
    if (scale != _formatScale)
    {
        SafeRelease(_wordFormat);
        SafeRelease(_numberFormat);
        // Segoe UI for the digits; DirectWrite falls back to Nirmala UI for Bangla.
        if (FAILED(_dwrite->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                             DWRITE_FONT_STRETCH_NORMAL, kWordSize * scale, L"bn-BD", &_wordFormat)) ||
            FAILED(_dwrite->CreateTextFormat(L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                             DWRITE_FONT_STRETCH_NORMAL, kNumberSize * scale, L"en-US", &_numberFormat)))
        {
            SafeRelease(_wordFormat);
            SafeRelease(_numberFormat);
            return;
        }
        _wordFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        _numberFormat->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        _formatScale = scale;
    }

    // ── Measure ──
    const float shadow = std::ceil(kShadow * scale);
    const float pad = kPillPadding * scale;
    const float itemPad = kItemPadding * scale;
    const float gap = kNumberGap * scale;

    std::vector<D2D1_SIZE_F> numbers, words;
    float lineHeight = 0, widest = 0;
    for (size_t i = 0; i < _items.size(); ++i)
    {
        numbers.push_back(Measure(_dwrite, _numberFormat, std::to_wstring(i + 1)));
        words.push_back(Measure(_dwrite, _wordFormat, _items[i]));
        lineHeight = std::max(lineHeight, words.back().height);
        widest = std::max(widest, numbers.back().width + gap + words.back().width);
    }
    const float itemH = std::ceil(lineHeight + 4 * scale);

    // ── Place, in window pixels (the shadow margin first) ──
    _itemBoxes.clear();
    float x = shadow + pad, y = shadow + pad;
    for (size_t i = 0; i < _items.size(); ++i)
    {
        const float w = _vertical ? std::ceil(widest + 2 * itemPad)
                                  : std::ceil(numbers[i].width + gap + words[i].width + 2 * itemPad);
        _itemBoxes.push_back({ x, y, x + w, y + itemH });
        if (_vertical) y += itemH; else x += w;
    }
    float right = 0, bottom = 0;
    for (const Box& b : _itemBoxes) { right = std::max(right, b.right); bottom = std::max(bottom, b.bottom); }

    _hasPages = _pageTotal > 1;
    if (_hasPages)
    {
        const float cx = right + 2 * scale, mid = (shadow + pad + bottom) / 2, h = 12 * scale;
        _upBox = { cx, mid - h, cx + kChevronWidth * scale, mid };
        _downBox = { cx, mid, cx + kChevronWidth * scale, mid + h };
        right = _downBox.right + 2 * scale;
    }
    const Box panel = { shadow, shadow, right + pad, bottom + pad };
    const int width = (int)std::ceil(panel.right + shadow);
    const int height = (int)std::ceil(panel.bottom + shadow);

    // ── Where: the first word's text under the caret, below the word or above it ──
    POINT at = { _anchor.left - (LONG)std::lround(panel.left + pad + itemPad),
                 _anchor.bottom + (LONG)std::lround(2 * scale - shadow) };
    MONITORINFO mi = { sizeof(mi) };
    if (GetMonitorInfoW(MonitorFromRect(&_anchor, MONITOR_DEFAULTTONEAREST), &mi))
    {
        const RECT& work = mi.rcWork;
        if (at.y + height - shadow > work.bottom)
            at.y = _anchor.top - (LONG)std::lround(2 * scale + panel.bottom);
        at.x = std::max<LONG>(work.left - (LONG)shadow, std::min<LONG>(at.x, work.right - width + (LONG)shadow));
    }

    // ── Draw into a premultiplied 32-bit DIB ──
    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = width;
    bi.bmiHeader.biHeight = -height; // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP bmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ oldBmp = bmp ? SelectObject(mem, bmp) : nullptr;

    const RECT bounds = { 0, 0, width, height };
    bool drawn = false;
    if (bmp && SUCCEEDED(_target->BindDC(mem, &bounds)))
    {
        const Palette c = CurrentPalette();
        ID2D1SolidColorBrush* brush = nullptr;
        _target->CreateSolidColorBrush(c.text, &brush);
        _target->BeginDraw();
        _target->Clear(D2D1::ColorF(0, 0.0f));
        // Text on a transparent surface: grayscale, ClearType needs an opaque one.
        _target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);

        auto rounded = [](const Box& b, float r) {
            return D2D1::RoundedRect(D2D1::RectF(b.left, b.top, b.right, b.bottom), r, r);
        };
        const float panelRadius = _vertical ? 12 * scale : (panel.bottom - panel.top) / 2;

        if (brush)
        {
            // A soft shadow: rings fading out, a little lower than the panel.
            brush->SetColor(c.shadow);
            for (float spread = shadow; spread >= 1.0f; spread -= std::max(1.0f, scale))
            {
                const Box ring = { panel.left - spread, panel.top - spread + scale, panel.right + spread, panel.bottom + spread + scale };
                brush->SetOpacity(0.35f * (1.0f - spread / (shadow + 1)));
                _target->FillRoundedRectangle(rounded(ring, panelRadius + spread), brush);
            }
            brush->SetOpacity(1.0f);

            brush->SetColor(c.background);
            _target->FillRoundedRectangle(rounded(panel, panelRadius), brush);
            brush->SetColor(c.border);
            const Box edge = { panel.left + 0.5f, panel.top + 0.5f, panel.right - 0.5f, panel.bottom - 0.5f };
            _target->DrawRoundedRectangle(rounded(edge, panelRadius - 0.5f), brush, 1.0f);

            for (size_t i = 0; i < _items.size(); ++i)
            {
                const Box& b = _itemBoxes[i];
                const bool selected = i == _selection;
                if (selected || (int)i == _hover)
                {
                    brush->SetColor(selected ? c.selected : c.hover);
                    _target->FillRoundedRectangle(rounded(b, (b.bottom - b.top) / 2), brush);
                }
                const float wordTop = (b.top + b.bottom - words[i].height) / 2;
                const std::wstring n = std::to_wstring(i + 1);
                brush->SetColor(selected ? c.selectedNumber : c.number);
                // The number sits a little high, like a superscript beside the word.
                _target->DrawText(n.c_str(), (UINT32)n.size(), _numberFormat,
                                  D2D1::RectF(b.left + itemPad, wordTop + 2 * scale, b.right, b.bottom), brush,
                                  D2D1_DRAW_TEXT_OPTIONS_NONE);
                brush->SetColor(selected ? c.selectedText : c.text);
                _target->DrawText(_items[i].c_str(), (UINT32)_items[i].size(), _wordFormat,
                                  D2D1::RectF(b.left + itemPad + numbers[i].width + gap, wordTop, b.right + 1000, b.bottom + 100),
                                  brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
            }

            if (_hasPages)
            {
                auto chevron = [&](const Box& b, bool up, bool enabled) {
                    D2D1_COLOR_F col = c.text;
                    col.a *= enabled ? 0.7f : 0.25f;
                    brush->SetColor(col);
                    const float cx = (b.left + b.right) / 2, cy = (b.top + b.bottom) / 2;
                    const float w = 3.5f * scale, h = 2.0f * scale * (up ? -1 : 1);
                    _target->DrawLine(D2D1::Point2F(cx - w, cy - h), D2D1::Point2F(cx, cy + h), brush, 1.4f * scale);
                    _target->DrawLine(D2D1::Point2F(cx, cy + h), D2D1::Point2F(cx + w, cy - h), brush, 1.4f * scale);
                };
                chevron(_upBox, true, _page > 0);
                chevron(_downBox, false, _page + 1 < _pageTotal);
            }
        }
        const HRESULT hr = _target->EndDraw();
        SafeRelease(brush);
        if (hr == (HRESULT)D2DERR_RECREATE_TARGET) SafeRelease(_target);
        drawn = SUCCEEDED(hr);
    }

    if (drawn)
    {
        POINT src = { 0, 0 };
        SIZE size = { width, height };
        BLENDFUNCTION blend = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
        UpdateLayeredWindow(_hwnd, screen, &at, &size, mem, &src, 0, &blend, ULW_ALPHA);
        SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    if (oldBmp) SelectObject(mem, oldBmp);
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
}

void CandidateWindow::OnMouseMove(int x, int y)
{
    if (!_trackingMouse)
    {
        TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE, _hwnd, 0 };
        _trackingMouse = TrackMouseEvent(&tme) != FALSE;
    }
    int hover = -1;
    for (size_t i = 0; i < _itemBoxes.size(); ++i)
        if (_itemBoxes[i].Contains((float)x, (float)y)) hover = (int)i;
    if (hover != _hover)
    {
        _hover = hover;
        Render();
    }
}

void CandidateWindow::OnClick(int x, int y)
{
    if (!_svc) return;
    for (size_t i = 0; i < _itemBoxes.size(); ++i)
    {
        // A click picks that pill (the composer commits it).
        if (_itemBoxes[i].Contains((float)x, (float)y))
        {
            _svc->OnCandidatePicked((UINT)i);
            return;
        }
    }
    if (!_hasPages) return;
    const float slop = 2.0f;
    const Box up = { _upBox.left - slop, _upBox.top - slop, _upBox.right + slop, _upBox.bottom };
    const Box down = { _downBox.left - slop, _downBox.top, _downBox.right + slop, _downBox.bottom + slop };
    if (up.Contains((float)x, (float)y) && _page > 0) _svc->OnCandidatePage(false);
    else if (down.Contains((float)x, (float)y) && _page + 1 < _pageTotal) _svc->OnCandidatePage(true);
}

LRESULT CALLBACK CandidateWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    CandidateWindow* self = nullptr;
    if (msg == WM_NCCREATE)
    {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        self = reinterpret_cast<CandidateWindow*>(cs->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)self);
        self->_hwnd = hwnd;
    }
    else
    {
        self = reinterpret_cast<CandidateWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }

    if (!self) return DefWindowProcW(hwnd, msg, wParam, lParam);

    switch (msg)
    {
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
        self->OnMouseMove(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_MOUSELEAVE:
        self->_trackingMouse = false;
        if (self->_hover != -1)
        {
            self->_hover = -1;
            self->Render();
        }
        return 0;
    case WM_LBUTTONDOWN:
        self->OnClick(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
    case WM_SYSCOLORCHANGE:
    case WM_DPICHANGED:
        // Light/dark, high contrast or scale changed while the panel is up.
        if (self->_visible) self->Render();
        return msg == WM_DPICHANGED ? 0 : DefWindowProcW(hwnd, msg, wParam, lParam);
    case WM_DESTROY:
        self->_hwnd = nullptr;
        self->_visible = false;
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}
