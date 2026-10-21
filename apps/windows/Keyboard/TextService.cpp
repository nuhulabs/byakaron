#include "TextService.h"
#include "EditSessions.h"
#include <msctf.h>
#include <new>

// ── Class factory ───────────────────────────────────────────────────────────

STDMETHODIMP CClassFactory::QueryInterface(REFIID riid, void** ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory))
    {
        *ppvObj = static_cast<IClassFactory*>(this);
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) CClassFactory::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) CClassFactory::Release()
{
    LONG c = InterlockedDecrement(&_refCount);
    if (c == 0) delete this;
    return c;
}

STDMETHODIMP CClassFactory::CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;
    if (pUnkOuter != nullptr) return CLASS_E_NOAGGREGATION;

    CByakaronTextService* svc = new (std::nothrow) CByakaronTextService();
    if (!svc) return E_OUTOFMEMORY;

    HRESULT hr = svc->QueryInterface(riid, ppvObj);
    svc->Release();
    return hr;
}

STDMETHODIMP CClassFactory::LockServer(BOOL fLock)
{
    if (fLock) DllAddRef();
    else DllRelease();
    return S_OK;
}

// ── Text service IUnknown / Activate ───────────────────────────────────────

CByakaronTextService::CByakaronTextService()
    : _candidateWindow(this)
{
    DllAddRef();
}

CByakaronTextService::~CByakaronTextService()
{
    Deactivate();
    DllRelease();
}

STDMETHODIMP CByakaronTextService::QueryInterface(REFIID riid, void** ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfTextInputProcessor))
        *ppvObj = static_cast<ITfTextInputProcessor*>(this);
    else if (IsEqualIID(riid, IID_ITfTextInputProcessorEx))
        *ppvObj = static_cast<ITfTextInputProcessorEx*>(this);
    else if (IsEqualIID(riid, IID_ITfThreadMgrEventSink))
        *ppvObj = static_cast<ITfThreadMgrEventSink*>(this);
    else if (IsEqualIID(riid, IID_ITfTextEditSink))
        *ppvObj = static_cast<ITfTextEditSink*>(this);
    else if (IsEqualIID(riid, IID_ITfKeyEventSink))
        *ppvObj = static_cast<ITfKeyEventSink*>(this);
    else if (IsEqualIID(riid, IID_ITfCompositionSink))
        *ppvObj = static_cast<ITfCompositionSink*>(this);
    else
        return E_NOINTERFACE;

    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CByakaronTextService::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) CByakaronTextService::Release()
{
    LONG c = InterlockedDecrement(&_refCount);
    if (c == 0) delete this;
    return c;
}

STDMETHODIMP CByakaronTextService::Activate(ITfThreadMgr* ptim, TfClientId tid)
{
    return ActivateEx(ptim, tid, 0);
}

STDMETHODIMP CByakaronTextService::ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD /*dwFlags*/)
{
    _pThreadMgr = ptim;
    if (_pThreadMgr) _pThreadMgr->AddRef();
    _tfClientId = tid;
    _activated = TRUE;
    _transliterator.EnsureReady();
    _dictionary.EnsureReady();

    ITfSource* source = nullptr;
    if (SUCCEEDED(_pThreadMgr->QueryInterface(IID_ITfSource, (void**)&source)) && source)
    {
        source->AdviseSink(IID_ITfThreadMgrEventSink, (ITfThreadMgrEventSink*)this, &_dwThreadMgrEventSinkCookie);
        source->Release();
    }

    ITfKeystrokeMgr* keyMgr = nullptr;
    if (SUCCEEDED(_pThreadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keyMgr)) && keyMgr)
    {
        keyMgr->AdviseKeyEventSink(_tfClientId, (ITfKeyEventSink*)this, TRUE);
        keyMgr->Release();
    }

    ITfDocumentMgr* docMgr = nullptr;
    if (SUCCEEDED(_pThreadMgr->GetFocus(&docMgr)) && docMgr)
    {
        OnSetFocus(docMgr, nullptr);
        docMgr->Release();
    }

    return S_OK;
}

STDMETHODIMP CByakaronTextService::Deactivate()
{
    if (!_activated) return S_OK;

    ResetCompositionState();
    _candidateWindow.End();

    ITfKeystrokeMgr* keyMgr = nullptr;
    if (_pThreadMgr && SUCCEEDED(_pThreadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keyMgr)) && keyMgr)
    {
        keyMgr->UnadviseKeyEventSink(_tfClientId);
        keyMgr->Release();
    }

    if (_pTextEditSinkContext)
    {
        ITfSource* src = nullptr;
        if (SUCCEEDED(_pTextEditSinkContext->QueryInterface(IID_ITfSource, (void**)&src)) && src)
        {
            if (_dwTextEditSinkCookie != TF_INVALID_COOKIE)
                src->UnadviseSink(_dwTextEditSinkCookie);
            src->Release();
        }
        _pTextEditSinkContext->Release();
        _pTextEditSinkContext = nullptr;
        _dwTextEditSinkCookie = TF_INVALID_COOKIE;
    }

    ITfSource* source = nullptr;
    if (_pThreadMgr && SUCCEEDED(_pThreadMgr->QueryInterface(IID_ITfSource, (void**)&source)) && source)
    {
        if (_dwThreadMgrEventSinkCookie != TF_INVALID_COOKIE)
            source->UnadviseSink(_dwThreadMgrEventSinkCookie);
        source->Release();
    }
    _dwThreadMgrEventSinkCookie = TF_INVALID_COOKIE;

    if (_pThreadMgr)
    {
        _pThreadMgr->Release();
        _pThreadMgr = nullptr;
    }
    _tfClientId = TF_CLIENTID_NULL;
    _activated = FALSE;
    return S_OK;
}
