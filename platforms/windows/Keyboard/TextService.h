#pragma once

#include "Globals.h"
#include "Transliterator.h"
#include <string>

class CByakaronTextService :
    public ITfTextInputProcessorEx,
    public ITfThreadMgrEventSink,
    public ITfTextEditSink,
    public ITfKeyEventSink,
    public ITfCompositionSink
{
public:
    CByakaronTextService();
    ~CByakaronTextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppvObj) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor / Ex
    STDMETHODIMP Activate(ITfThreadMgr* ptim, TfClientId tid) override;
    STDMETHODIMP Deactivate() override;
    STDMETHODIMP ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD dwFlags) override;

    // ITfThreadMgrEventSink
    STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr* pdim) override;
    STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr* pdim) override;
    STDMETHODIMP OnSetFocus(ITfDocumentMgr* pdimFocus, ITfDocumentMgr* pdimPrevFocus) override;
    STDMETHODIMP OnPushContext(ITfContext* pic) override;
    STDMETHODIMP OnPopContext(ITfContext* pic) override;

    // ITfTextEditSink
    STDMETHODIMP OnEndEdit(ITfContext* pic, TfEditCookie ecReadOnly, ITfEditRecord* pEditRecord) override;

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL fForeground) override;
    STDMETHODIMP OnTestKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnKeyUp(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext* pic, REFGUID rguid, BOOL* pfEaten) override;

    // ITfCompositionSink
    STDMETHODIMP OnCompositionTerminated(TfEditCookie ecWrite, ITfComposition* pComposition) override;

    ITfThreadMgr* GetThreadMgr() const { return _pThreadMgr; }
    TfClientId GetClientId() const { return _tfClientId; }

private:
    bool IsAvroInputChar(WCHAR ch) const;
    void ResetCompositionState();
    HRESULT EnsureComposition(ITfContext* pic, TfEditCookie ec);
    HRESULT UpdateCompositionText(ITfContext* pic, TfEditCookie ec, const std::wstring& text);
    HRESULT TerminateComposition(TfEditCookie ec);
    HRESULT CommitAndClear(ITfContext* pic);
    BOOL HandleKey(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL testOnly);

    // Edit session helpers invoked via ITfEditSession
    friend class CKeyEditSession;
    friend class CCommitEditSession;

    LONG _refCount = 1;
    ITfThreadMgr* _pThreadMgr = nullptr;
    TfClientId _tfClientId = TF_CLIENTID_NULL;
    DWORD _dwThreadMgrEventSinkCookie = TF_INVALID_COOKIE;
    DWORD _dwTextEditSinkCookie = TF_INVALID_COOKIE;
    ITfContext* _pTextEditSinkContext = nullptr;
    ITfComposition* _pComposition = nullptr;

    std::wstring _latinBuffer;
    Transliterator _transliterator;
    BOOL _activated = FALSE;
};

class CClassFactory : public IClassFactory
{
public:
    CClassFactory() : _refCount(1) { DllAddRef(); }
    ~CClassFactory() { DllRelease(); }

    STDMETHODIMP QueryInterface(REFIID riid, void** ppvObj) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    STDMETHODIMP CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppvObj) override;
    STDMETHODIMP LockServer(BOOL fLock) override;

private:
    LONG _refCount;
};
