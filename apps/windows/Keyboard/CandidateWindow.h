#pragma once

#include "Globals.h"
#include <string>
#include <vector>

class CByakaronTextService;
struct ID2D1Factory;
struct ID2D1DCRenderTarget;
struct IDWriteFactory;
struct IDWriteTextFormat;

// Official TSF candidate UI (SampleIME / UI-less mode pattern):
// ITfUIElement + ITfCandidateListUIElement + ITfCandidateListUIElementBehavior,
// negotiated via ITfUIElementMgr. Fallback HWND only when the host allows TIP UI.
class CandidateWindow : public ITfCandidateListUIElementBehavior
{
public:
    explicit CandidateWindow(CByakaronTextService* svc);
    ~CandidateWindow();

    CandidateWindow(const CandidateWindow&) = delete;
    CandidateWindow& operator=(const CandidateWindow&) = delete;

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppvObj) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfUIElement
    STDMETHODIMP GetDescription(BSTR* pbstrDescription) override;
    STDMETHODIMP GetGUID(GUID* pguid) override;
    STDMETHODIMP Show(BOOL bShow) override;
    STDMETHODIMP IsShown(BOOL* pbShow) override;

    // ITfCandidateListUIElement
    STDMETHODIMP GetUpdatedFlags(DWORD* pdwFlags) override;
    STDMETHODIMP GetDocumentMgr(ITfDocumentMgr** ppdim) override;
    STDMETHODIMP GetCount(UINT* puCount) override;
    STDMETHODIMP GetSelection(UINT* puIndex) override;
    STDMETHODIMP GetString(UINT uIndex, BSTR* pstr) override;
    STDMETHODIMP GetPageIndex(UINT* pIndex, UINT uSize, UINT* puPageCnt) override;
    STDMETHODIMP SetPageIndex(UINT* pIndex, UINT uPageCnt) override;
    STDMETHODIMP GetCurrentPage(UINT* puPage) override;

    // ITfCandidateListUIElementBehavior
    STDMETHODIMP SetSelection(UINT nIndex) override;
    STDMETHODIMP Finalize() override;
    STDMETHODIMP Abort() override;

    // Show one page of candidates (labels 1..N) with `highlight` selected,
    // just below `anchor` (the word being typed, in screen pixels; above it
    // when there is no room below). `page` of `pageCount` draws the paging
    // chevrons. End hides it. Both report to TSF for UI-less hosts.
    void Present(const std::vector<std::wstring>& items, int highlight, bool vertical,
                 size_t page, size_t pageCount, const RECT& anchor);
    void End();

private:
    // A rectangle in window pixels.
    struct Box { float left, top, right, bottom; bool Contains(float x, float y) const; };

    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    bool EnsureGraphics();
    void ReleaseGraphics();
    // Measure, place and draw the panel, then hand the pixels to the window.
    void Render();
    float ScaleAt(const RECT& anchor) const;
    void OnMouseMove(int x, int y);
    void OnClick(int x, int y);
    void ShowTipWindow(BOOL show);
    void CallUpdateUIElement();

    CByakaronTextService* _svc = nullptr;

    LONG _refCount = 1;
    HWND _hwnd = nullptr;
    std::vector<std::wstring> _items;
    UINT _selection = 0;
    UINT _pageIndex[1] = { 0 };
    UINT _pageCount = 1;
    DWORD _updatedFlags = 0;
    DWORD _uiElementId = (DWORD)-1;
    bool _inShowMode = false;
    bool _hostAllowsTipUi = true;
    bool _visible = false;
    bool _vertical = false;

    // What the pill panel draws (see CandidateWindow.cpp).
    size_t _page = 0;
    size_t _pageTotal = 1;
    RECT _anchor = {};
    int _hover = -1;
    bool _trackingMouse = false;
    std::vector<Box> _itemBoxes;
    Box _upBox = {}, _downBox = {};
    bool _hasPages = false;

    ID2D1Factory* _d2d = nullptr;
    ID2D1DCRenderTarget* _target = nullptr;
    IDWriteFactory* _dwrite = nullptr;
    IDWriteTextFormat* _wordFormat = nullptr;
    IDWriteTextFormat* _numberFormat = nullptr;
    float _formatScale = 0;
};
