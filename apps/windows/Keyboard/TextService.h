#pragma once

#include "Globals.h"
#include "Composer.h"
#include "CandidateWindow.h"
#include <functional>
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

    // Candidate UI -> composer: a click on our window, or a UI-less host's
    // ITfCandidateListUIElementBehavior (SetSelection picks; Finalize commits
    // the word, Abort drops it).
    void OnCandidatePicked(UINT index);
    void OnCandidateFinalize(bool commit);

private:
    // An OS key event as byakaron_composer_key takes it; send is false for
    // keys the composer never sees (Shift alone, Caps Lock, ...).
    struct KeyInput
    {
        bool send = false;
        int kind = BYAKARON_KEY_OTHER;
        unsigned int ch = 0;
        unsigned int mods = 0;
    };
    static KeyInput MapKey(WPARAM wParam, LPARAM lParam);
    BOOL WouldEat(const KeyInput& key);
    BOOL HandleKey(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL testOnly);

    // Inside an edit session: insert commit, then draw the composer's state.
    void Apply(ITfContext* pic, TfEditCookie ec, const std::wstring& commit);
    void Redraw(ITfContext* pic, TfEditCookie ec);
    void InsertCommit(ITfContext* pic, TfEditCookie ec, const std::wstring& text);
    POINT CandidateOrigin(ITfContext* pic, TfEditCookie ec) const;

    // Run fn in an edit session on the open composition's context, if it is
    // still the open composition when the session runs.
    void EditComposition(std::function<void(ITfContext*, TfEditCookie)> fn);
    // Focus leaving / deactivation: commit the word being typed.
    void CommitPendingWord();
    void OnComposerUpdated();
    IUnknown* Owner() { return static_cast<ITfTextInputProcessorEx*>(this); }

    HRESULT EnsureComposition(ITfContext* pic, TfEditCookie ec);
    HRESULT SetCompositionText(ITfContext* pic, TfEditCookie ec, const std::wstring& text);
    void EndComposition(TfEditCookie ec);
    bool CompositionContext(ITfContext** out) const;
    bool GetCompositionScreenRect(ITfContext* pic, TfEditCookie ec, RECT* out) const;

    // on_update arrives on the spell worker thread; it posts to this
    // message-only window, owned by the text service's thread.
    static void OnComposerUpdate(void* userdata);
    static LRESULT CALLBACK NotifyWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    bool CreateNotifyWindow();
    void DestroyNotifyWindow();

    LONG _refCount = 1;
    ITfThreadMgr* _pThreadMgr = nullptr;
    TfClientId _tfClientId = TF_CLIENTID_NULL;
    DWORD _dwThreadMgrEventSinkCookie = TF_INVALID_COOKIE;
    DWORD _dwTextEditSinkCookie = TF_INVALID_COOKIE;
    ITfContext* _pTextEditSinkContext = nullptr;
    ITfComposition* _pComposition = nullptr;

    Composer _composer;
    CandidateWindow _candidateWindow;
    HWND _hwndNotify = nullptr;
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
