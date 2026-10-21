#include "CandidateWindow.h"
#include "TextService.h"
#include <strsafe.h>

namespace
{
constexpr wchar_t kClassName[] = L"ByakaronCandidateWindow";
constexpr int kPadX = 10;
constexpr int kPadY = 4;

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

STDMETHODIMP CandidateWindow::SetSelection(UINT nIndex)
{
    SetSelectedIndex((int)nIndex);
    return S_OK;
}

STDMETHODIMP CandidateWindow::Finalize()
{
    if (_finalizeCb && _svc) _finalizeCb(_svc, true);
    End();
    return S_OK;
}

STDMETHODIMP CandidateWindow::Abort()
{
    if (_finalizeCb && _svc) _finalizeCb(_svc, false);
    End();
    return S_OK;
}

bool CandidateWindow::EnsureWindow()
{
    if (_hwnd) return true;

    WNDCLASSEXW wc = { sizeof(wc) };
    if (!GetClassInfoExW(g_hInst, kClassName, &wc))
    {
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
        wc.lpfnWndProc = WndProc;
        wc.hInstance = g_hInst;
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        wc.lpszClassName = kClassName;
        if (!RegisterClassExW(&wc)) return false;
    }

    _hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
        kClassName,
        L"",
        WS_POPUP | WS_BORDER,
        0, 0, 0, 0,
        nullptr,
        nullptr,
        g_hInst,
        this);

    return _hwnd != nullptr;
}

void CandidateWindow::SetCandidates(const std::vector<std::wstring>& items, int selectedIndex, bool vertical)
{
    _items = items;
    _vertical = vertical;
    _selection = 0;
    if (!_items.empty())
    {
        if (selectedIndex < 0) selectedIndex = 0;
        if (selectedIndex >= (int)_items.size()) selectedIndex = (int)_items.size() - 1;
        _selection = (UINT)selectedIndex;
    }
    _pageIndex[0] = 0;
    _pageCount = 1;
    _updatedFlags =
        TF_CLUIE_DOCUMENTMGR |
        TF_CLUIE_COUNT |
        TF_CLUIE_SELECTION |
        TF_CLUIE_STRING |
        TF_CLUIE_PAGEINDEX |
        TF_CLUIE_CURRENTPAGE;

    if (_inShowMode)
    {
        CallUpdateUIElement();
        if (_hostAllowsTipUi && _hwnd)
        {
            Layout();
            InvalidateRect(_hwnd, nullptr, TRUE);
        }
    }
}

void CandidateWindow::SetSelectedIndex(int index)
{
    if (_items.empty()) return;
    if (index < 0) index = 0;
    if (index >= (int)_items.size()) index = (int)_items.size() - 1;
    if ((UINT)index == _selection) return;
    _selection = (UINT)index;
    _updatedFlags = TF_CLUIE_SELECTION;
    CallUpdateUIElement();
    if (_hwnd && _visible) InvalidateRect(_hwnd, nullptr, TRUE);
}

std::wstring CandidateWindow::SelectedText() const
{
    if (_selection >= _items.size()) return {};
    return _items[_selection];
}

void CandidateWindow::BeginAt(int x, int y)
{
    if (_items.empty())
    {
        End();
        return;
    }

    BOOL bShow = TRUE;
    if (!_inShowMode)
    {
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

    if (_hostAllowsTipUi)
    {
        EnsureWindow();
        Layout();
        if (_hwnd)
        {
            SetWindowPos(_hwnd, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            _visible = true;
            InvalidateRect(_hwnd, nullptr, TRUE);
        }
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
    if (_hwnd && _inShowMode && _hostAllowsTipUi)
    {
        ShowWindow(_hwnd, SW_SHOWNA);
        _visible = true;
    }
}

void CandidateWindow::Layout()
{
    if (!_hwnd || _items.empty()) return;

    HDC hdc = GetDC(_hwnd);
    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HFONT old = (HFONT)SelectObject(hdc, font);

    int maxText = 0;
    for (size_t i = 0; i < _items.size(); ++i)
    {
        WCHAR label[512];
        StringCchPrintfW(label, 512, L"%d. %s", (int)i + 1, _items[i].c_str());
        SIZE sz = {};
        GetTextExtentPoint32W(hdc, label, (int)wcslen(label), &sz);
        if (sz.cx > maxText) maxText = sz.cx;
        if (sz.cy + kPadY * 2 > _itemH) _itemH = sz.cy + kPadY * 2;
    }
    SelectObject(hdc, old);
    ReleaseDC(_hwnd, hdc);

    _itemW = maxText + kPadX * 2;
    int w = 0, h = 0;
    if (_vertical)
    {
        w = _itemW;
        h = _itemH * (int)_items.size();
    }
    else
    {
        w = _itemW * (int)_items.size();
        h = _itemH;
    }
    SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, w + 2, h + 2, SWP_NOMOVE | SWP_NOACTIVATE);
}

void CandidateWindow::OnPaint(HDC hdc)
{
    RECT rc = {};
    GetClientRect(_hwnd, &rc);
    FillRect(hdc, &rc, (HBRUSH)(COLOR_WINDOW + 1));

    HFONT font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HFONT old = (HFONT)SelectObject(hdc, font);
    SetBkMode(hdc, TRANSPARENT);

    for (size_t i = 0; i < _items.size(); ++i)
    {
        RECT item = {};
        if (_vertical)
        {
            item.left = 0;
            item.top = (int)i * _itemH;
            item.right = rc.right;
            item.bottom = item.top + _itemH;
        }
        else
        {
            item.left = (int)i * _itemW;
            item.top = 0;
            item.right = item.left + _itemW;
            item.bottom = rc.bottom;
        }

        if ((UINT)i == _selection)
        {
            HBRUSH brush = CreateSolidBrush(GetSysColor(COLOR_HIGHLIGHT));
            FillRect(hdc, &item, brush);
            DeleteObject(brush);
            SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
        }
        else
        {
            SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT));
        }

        WCHAR label[512];
        StringCchPrintfW(label, 512, L"%d. %s", (int)i + 1, _items[i].c_str());
        DrawTextW(hdc, label, -1, &item, DT_SINGLELINE | DT_VCENTER | DT_CENTER | DT_NOPREFIX);
    }

    SelectObject(hdc, old);
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
    case WM_PAINT:
    {
        PAINTSTRUCT ps = {};
        HDC hdc = BeginPaint(hwnd, &ps);
        self->OnPaint(hdc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_DESTROY:
        self->_hwnd = nullptr;
        self->_visible = false;
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}
