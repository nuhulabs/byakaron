#pragma once

#include "TextService.h"
#include <functional>
#include <new>

// An ITfEditSession that runs a callback with the granted cookie. Holds the
// context (and, if given, the text service) until TSF is done with it.
class CEditSession final : public ITfEditSession
{
public:
    using Fn = std::function<void(TfEditCookie)>;

    CEditSession(ITfContext* ctx, IUnknown* owner, Fn fn)
        : _ref(1), _ctx(ctx), _owner(owner), _fn(std::move(fn))
    {
        _ctx->AddRef();
        if (_owner) _owner->AddRef();
    }

    ~CEditSession()
    {
        _ctx->Release();
        if (_owner) _owner->Release();
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (ppv == nullptr) return E_INVALIDARG;
        *ppv = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession))
        {
            *ppv = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&_ref); }

    STDMETHODIMP_(ULONG) Release() override
    {
        LONG c = InterlockedDecrement(&_ref);
        if (c == 0) delete this;
        return c;
    }

    STDMETHODIMP DoEditSession(TfEditCookie ec) override
    {
        if (_fn) _fn(ec);
        return S_OK;
    }

private:
    LONG _ref;
    ITfContext* _ctx;
    IUnknown* _owner;
    Fn _fn;
};

// Request a read/write edit session on ctx. Returns the request's failure, or
// the session's result (TF_S_ASYNC when TSF queued it).
inline HRESULT RunEditSession(ITfContext* ctx, TfClientId tid, IUnknown* owner, CEditSession::Fn fn, DWORD flags)
{
    if (!ctx) return E_INVALIDARG;
    CEditSession* session = new (std::nothrow) CEditSession(ctx, owner, std::move(fn));
    if (!session) return E_OUTOFMEMORY;
    HRESULT hrSession = E_FAIL;
    const HRESULT hr = ctx->RequestEditSession(tid, session, flags | TF_ES_READWRITE, &hrSession);
    session->Release();
    return FAILED(hr) ? hr : hrSession;
}
