#pragma once

#include "Globals.h"
#include <string>
#include <vector>

class CByakaronTextService;

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

    // Show one page of candidates (labels 1..N) with `highlight` selected, at
    // screen x, y; End hides it. Both report to TSF for UI-less hosts.
    void Present(const std::vector<std::wstring>& items, int highlight, bool vertical, int x, int y);
    void End();

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    void OnPaint(HDC hdc);
    int HitTest(int x, int y) const;
    void Layout();
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
    int _itemW = 0;
    int _itemH = 28;
};
