#include "TextService.h"
#include "EditSessions.h"
#include <new>

// ── Thread mgr / text edit sinks ────────────────────────────────────────────

STDMETHODIMP CByakaronTextService::OnInitDocumentMgr(ITfDocumentMgr* /*pdim*/)
{
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnUninitDocumentMgr(ITfDocumentMgr* /*pdim*/)
{
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnSetFocus(ITfDocumentMgr* pdimFocus, ITfDocumentMgr* /*pdimPrevFocus*/)
{
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

    if (!pdimFocus) return S_OK;

    ITfContext* ctx = nullptr;
    if (FAILED(pdimFocus->GetTop(&ctx)) || !ctx) return S_OK;

    ITfSource* src = nullptr;
    if (SUCCEEDED(ctx->QueryInterface(IID_ITfSource, (void**)&src)) && src)
    {
        if (SUCCEEDED(src->AdviseSink(IID_ITfTextEditSink, (ITfTextEditSink*)this, &_dwTextEditSinkCookie)))
        {
            _pTextEditSinkContext = ctx;
            _pTextEditSinkContext->AddRef();
        }
        src->Release();
    }
    ctx->Release();
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnPushContext(ITfContext* /*pic*/) { return S_OK; }
STDMETHODIMP CByakaronTextService::OnPopContext(ITfContext* /*pic*/) { return S_OK; }

STDMETHODIMP CByakaronTextService::OnEndEdit(ITfContext* /*pic*/, TfEditCookie /*ecReadOnly*/, ITfEditRecord* /*pEditRecord*/)
{
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnCompositionTerminated(TfEditCookie /*ecWrite*/, ITfComposition* /*pComposition*/)
{
    if (_pComposition)
    {
        _pComposition->Release();
        _pComposition = nullptr;
    }
    _latinBuffer.clear();
    return S_OK;
}

// ── Key event sink ──────────────────────────────────────────────────────────

STDMETHODIMP CByakaronTextService::OnSetFocus(BOOL /*fForeground*/)
{
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnTestKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten)
{
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = HandleKey(pic, wParam, lParam, TRUE);
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnTestKeyUp(ITfContext* /*pic*/, WPARAM /*wParam*/, LPARAM /*lParam*/, BOOL* pfEaten)
{
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = FALSE;
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten)
{
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = HandleKey(pic, wParam, lParam, FALSE);
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnKeyUp(ITfContext* /*pic*/, WPARAM /*wParam*/, LPARAM /*lParam*/, BOOL* pfEaten)
{
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = FALSE;
    return S_OK;
}

STDMETHODIMP CByakaronTextService::OnPreservedKey(ITfContext* /*pic*/, REFGUID /*rguid*/, BOOL* pfEaten)
{
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = FALSE;
    return S_OK;
}

BOOL CByakaronTextService::HandleKey(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL testOnly)
{
    if (!pic) return FALSE;

    CKeyEditSession* session = new (std::nothrow) CKeyEditSession(this, pic, wParam, lParam, testOnly);
    if (!session) return FALSE;

    HRESULT hr = S_OK;
    HRESULT hrSession = E_FAIL;
    hr = pic->RequestEditSession(_tfClientId, session, TF_ES_SYNC | TF_ES_READWRITE, &hrSession);
    BOOL eaten = SUCCEEDED(hr) && SUCCEEDED(hrSession) && session->Eaten();
    session->Release();
    return eaten;
}

STDMETHODIMP CKeyEditSession::DoEditSession(TfEditCookie ec)
{
    _eaten = FALSE;
    const UINT vk = (UINT)_wParam;

    // Ctrl/Alt/Win — never eat (let shortcuts through); commit any buffer first.
    const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
    const bool win = (GetKeyState(VK_LWIN) & 0x8000) != 0 || (GetKeyState(VK_RWIN) & 0x8000) != 0;
    if (ctrl || alt || win)
    {
        if (!_svc->_latinBuffer.empty() && !_testOnly)
        {
            std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
            _svc->EnsureComposition(_ctx, ec);
            _svc->UpdateCompositionText(_ctx, ec, bangla);
            _svc->TerminateComposition(ec);
            _svc->ResetCompositionState();
        }
        return S_OK;
    }

    if (vk == VK_ESCAPE)
    {
        if (_svc->_latinBuffer.empty()) return S_OK;
        _eaten = TRUE;
        if (!_testOnly)
        {
            _svc->TerminateComposition(ec);
            _svc->ResetCompositionState();
        }
        return S_OK;
    }

    if (vk == VK_BACK)
    {
        if (_svc->_latinBuffer.empty()) return S_OK;
        _eaten = TRUE;
        if (!_testOnly)
        {
            _svc->_latinBuffer.pop_back();
            if (_svc->_latinBuffer.empty())
            {
                _svc->TerminateComposition(ec);
                _svc->ResetCompositionState();
            }
            else
            {
                std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
                _svc->EnsureComposition(_ctx, ec);
                _svc->UpdateCompositionText(_ctx, ec, bangla);
            }
        }
        return S_OK;
    }

    if (vk == VK_RETURN || vk == VK_SPACE)
    {
        if (_svc->_latinBuffer.empty()) return S_OK;
        // Commit Bangla; let Space fall through to insert a space (macOS behaviour).
        _eaten = (vk == VK_RETURN) ? TRUE : FALSE;
        if (!_testOnly)
        {
            std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
            _svc->EnsureComposition(_ctx, ec);
            _svc->UpdateCompositionText(_ctx, ec, bangla);
            _svc->TerminateComposition(ec);
            _svc->ResetCompositionState();
        }
        // For Space: eaten=FALSE so the app also receives Space after commit.
        // Actually if we return FALSE from OnKeyDown, space goes to app. Good.
        // But we already committed in this sync session. If eaten=FALSE, host may get the key too.
        if (vk == VK_SPACE)
        {
            // Commit happened; do not eat so a space character is typed after Bangla word.
            _eaten = FALSE;
        }
        return S_OK;
    }

    // Map VK to character (Latin Avro alphabet).
    BYTE state[256] = {};
    GetKeyboardState(state);
    WCHAR chars[4] = {};
    int n = ToUnicode((UINT)vk, (UINT)((_lParam >> 16) & 0xFF), state, chars, 4, 0);
    if (n <= 0) return S_OK;

    WCHAR ch = chars[0];
    if (!_svc->IsAvroInputChar(ch))
    {
        if (!_svc->_latinBuffer.empty() && !_testOnly)
        {
            std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
            _svc->EnsureComposition(_ctx, ec);
            _svc->UpdateCompositionText(_ctx, ec, bangla);
            _svc->TerminateComposition(ec);
            _svc->ResetCompositionState();
        }
        return S_OK; // not eaten — insert the punctuation/etc. normally
    }

    _eaten = TRUE;
    if (!_testOnly)
    {
        _svc->_latinBuffer.push_back(ch);
        std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
        _svc->EnsureComposition(_ctx, ec);
        _svc->UpdateCompositionText(_ctx, ec, bangla);
    }
    return S_OK;
}

STDMETHODIMP CCommitEditSession::DoEditSession(TfEditCookie ec)
{
    if (_svc->_latinBuffer.empty()) return S_OK;
    std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
    _svc->EnsureComposition(_ctx, ec);
    _svc->UpdateCompositionText(_ctx, ec, bangla);
    _svc->TerminateComposition(ec);
    _svc->ResetCompositionState();
    return S_OK;
}

// ── Composition helpers ─────────────────────────────────────────────────────

bool CByakaronTextService::IsAvroInputChar(WCHAR ch) const
{
    if ((ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z')) return true;
    if (ch >= L'0' && ch <= L'9') return true;
    switch (ch)
    {
    case L'.': case L',': case L'`': case L':': case L'^': case L'$':
        return true;
    default:
        return false;
    }
}

void CByakaronTextService::ResetCompositionState()
{
    _latinBuffer.clear();
    if (_pComposition)
    {
        _pComposition->Release();
        _pComposition = nullptr;
    }
}

HRESULT CByakaronTextService::EnsureComposition(ITfContext* pic, TfEditCookie ec)
{
    if (_pComposition) return S_OK;

    ITfInsertAtSelection* insert = nullptr;
    if (FAILED(pic->QueryInterface(IID_ITfInsertAtSelection, (void**)&insert)) || !insert)
        return E_FAIL;

    ITfRange* range = nullptr;
    HRESULT hr = insert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &range);
    insert->Release();
    if (FAILED(hr) || !range) return E_FAIL;

    ITfContextComposition* ctxComp = nullptr;
    hr = pic->QueryInterface(IID_ITfContextComposition, (void**)&ctxComp);
    if (FAILED(hr) || !ctxComp)
    {
        range->Release();
        return E_FAIL;
    }

    hr = ctxComp->StartComposition(ec, range, (ITfCompositionSink*)this, &_pComposition);
    ctxComp->Release();
    range->Release();
    return hr;
}

HRESULT CByakaronTextService::UpdateCompositionText(ITfContext* /*pic*/, TfEditCookie ec, const std::wstring& text)
{
    if (!_pComposition) return E_FAIL;

    ITfRange* range = nullptr;
    if (FAILED(_pComposition->GetRange(&range)) || !range) return E_FAIL;

    range->SetText(ec, 0, text.c_str(), (LONG)text.size());

    // Place caret at end.
    ITfRange* clone = nullptr;
    if (SUCCEEDED(range->Clone(&clone)) && clone)
    {
        clone->Collapse(ec, TF_ANCHOR_END);
        ITfContext* ctx = nullptr;
        // Selection via ITfContext from composition range's context would be nicer;
        // use the sink context we already hold.
        if (_pTextEditSinkContext)
        {
            TF_SELECTION sel = {};
            sel.range = clone;
            sel.style.ase = TF_AE_NONE;
            sel.style.fInterimChar = FALSE;
            _pTextEditSinkContext->SetSelection(ec, 1, &sel);
        }
        clone->Release();
    }

    range->Release();
    return S_OK;
}

HRESULT CByakaronTextService::TerminateComposition(TfEditCookie ec)
{
    if (!_pComposition) return S_OK;
    _pComposition->EndComposition(ec);
    _pComposition->Release();
    _pComposition = nullptr;
    return S_OK;
}
