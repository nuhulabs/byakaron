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

    bool EnsureWindow();
    void SetCandidates(const std::vector<std::wstring>& items, int selectedIndex, bool vertical);
    void BeginAt(int x, int y);
    void End();
    bool IsActive() const { return _inShowMode; }
    bool IsVisible() const { return _inShowMode && (_hostAllowsTipUi ? _visible : true); }

    int SelectedIndex() const { return (int)_selection; }
    void SetSelectedIndex(int index);
    int Count() const { return (int)_items.size(); }
    std::wstring SelectedText() const;

    // Called by text service when Behavior::Finalize/Abort need composition action.
    using FinalizeCallback = void (*)(CByakaronTextService* svc, bool commit);
    void SetFinalizeCallback(FinalizeCallback cb) { _finalizeCb = cb; }

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    void OnPaint(HDC hdc);
    void Layout();
    void ShowTipWindow(BOOL show);
    void NotifyUpdate();
    void CallUpdateUIElement();

    CByakaronTextService* _svc = nullptr;
    FinalizeCallback _finalizeCb = nullptr;

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
