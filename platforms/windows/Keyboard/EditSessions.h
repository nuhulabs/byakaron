#pragma once

#include "TextService.h"
#include <new>

class CKeyEditSession : public ITfEditSession
{
public:
    CKeyEditSession(CByakaronTextService* svc, ITfContext* ctx, WPARAM wParam, LPARAM lParam, BOOL testOnly)
        : _ref(1), _svc(svc), _ctx(ctx), _wParam(wParam), _lParam(lParam), _testOnly(testOnly), _eaten(FALSE)
    {
        _svc->AddRef();
        _ctx->AddRef();
    }

    ~CKeyEditSession()
    {
        _svc->Release();
        _ctx->Release();
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

    STDMETHODIMP DoEditSession(TfEditCookie ec) override;

    BOOL Eaten() const { return _eaten; }

private:
    LONG _ref;
    CByakaronTextService* _svc;
    ITfContext* _ctx;
    WPARAM _wParam;
    LPARAM _lParam;
    BOOL _testOnly;
    BOOL _eaten;
};

class CCommitEditSession : public ITfEditSession
{
public:
    CCommitEditSession(CByakaronTextService* svc, ITfContext* ctx)
        : _ref(1), _svc(svc), _ctx(ctx)
    {
        _svc->AddRef();
        _ctx->AddRef();
    }

    ~CCommitEditSession()
    {
        _svc->Release();
        _ctx->Release();
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

    STDMETHODIMP DoEditSession(TfEditCookie ec) override;

private:
    LONG _ref;
    CByakaronTextService* _svc;
    ITfContext* _ctx;
};
