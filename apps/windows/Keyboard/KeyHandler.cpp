#include "TextService.h"
#include "EditSessions.h"
#include "Settings.h"
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
    }
    _dwTextEditSinkCookie = TF_INVALID_COOKIE;

    if (!pdimFocus)
    {
        HideCandidates();
        return S_OK;
    }

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
    _selectedText.clear();
    HideCandidates();
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
    const bool candidatesOpen = _svc->_candidateWindow.IsVisible() && !_svc->_latinBuffer.empty();

    // Ctrl/Alt/Win — never eat (let shortcuts through); commit any buffer first.
    const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    const bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
    const bool win = (GetKeyState(VK_LWIN) & 0x8000) != 0 || (GetKeyState(VK_RWIN) & 0x8000) != 0;
    if (ctrl || alt || win)
    {
        if (!_svc->_latinBuffer.empty() && !_testOnly)
        {
            _svc->CommitBuffer(_ctx, ec);
        }
        return S_OK;
    }

    // Candidate navigation / numbered pick (macOS IMKCandidates behaviour).
    if (candidatesOpen)
    {
        if (vk == VK_ESCAPE)
        {
            _eaten = TRUE;
            if (!_testOnly)
            {
                _svc->TerminateComposition(ec);
                _svc->ResetCompositionState();
            }
            return S_OK;
        }

        if (vk == VK_LEFT || vk == VK_UP || vk == VK_RIGHT || vk == VK_DOWN ||
            vk == VK_PRIOR || vk == VK_NEXT)
        {
            _eaten = TRUE;
            if (!_testOnly)
            {
                const bool vertical = ByakaronSettings::OrientationVertical();
                int sel = _svc->_candidateWindow.SelectedIndex();
                const int count = _svc->_candidateWindow.Count();
                if (vk == VK_LEFT || (vertical && vk == VK_UP) || vk == VK_PRIOR)
                    sel = (sel <= 0) ? count - 1 : sel - 1;
                else if (vk == VK_RIGHT || (vertical && vk == VK_DOWN) || vk == VK_NEXT)
                    sel = (sel >= count - 1) ? 0 : sel + 1;
                else if (!vertical && vk == VK_UP)
                    sel = (sel <= 0) ? count - 1 : sel - 1;
                else if (!vertical && vk == VK_DOWN)
                    sel = (sel >= count - 1) ? 0 : sel + 1;
                _svc->_candidateWindow.SetSelectedIndex(sel);
                _svc->_selectedText = _svc->_candidateWindow.SelectedText();
            }
            return S_OK;
        }

        // Digits 1–9 pick a candidate (while the panel is open).
        int pick = -1;
        if (vk >= '1' && vk <= '9') pick = (int)(vk - '1');
        else if (vk >= VK_NUMPAD1 && vk <= VK_NUMPAD9) pick = (int)(vk - VK_NUMPAD1);
        if (pick >= 0 && pick < _svc->_candidateWindow.Count())
        {
            _eaten = TRUE;
            if (!_testOnly)
            {
                _svc->_candidateWindow.SetSelectedIndex(pick);
                _svc->_selectedText = _svc->_candidateWindow.SelectedText();
                _svc->CommitBuffer(_ctx, ec);
            }
            return S_OK;
        }

        if (vk == VK_SPACE)
        {
            // Commit highlighted candidate; let Space fall through (macOS).
            _eaten = FALSE;
            if (!_testOnly)
            {
                _svc->CommitBuffer(_ctx, ec);
            }
            return S_OK;
        }

        if (vk == VK_RETURN)
        {
            _eaten = TRUE;
            if (!_testOnly)
            {
                _svc->CommitBuffer(_ctx, ec);
            }
            return S_OK;
        }

        // Backspace falls through to buffer editing below.
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
                _svc->_selectedText = bangla;
                _svc->EnsureComposition(_ctx, ec);
                _svc->UpdateCompositionText(_ctx, ec, bangla);
                _svc->RefreshCandidates(_ctx, ec);
            }
        }
        return S_OK;
    }

    if (vk == VK_RETURN || vk == VK_SPACE)
    {
        if (_svc->_latinBuffer.empty()) return S_OK;
        _eaten = (vk == VK_RETURN) ? TRUE : FALSE;
        if (!_testOnly)
        {
            _svc->CommitBuffer(_ctx, ec);
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
            _svc->CommitBuffer(_ctx, ec);
        }
        return S_OK; // not eaten — insert the punctuation/etc. normally
    }

    _eaten = TRUE;
    if (!_testOnly)
    {
        _svc->_latinBuffer.push_back(ch);
        std::wstring bangla = _svc->_transliterator.ToBangla(_svc->_latinBuffer);
        _svc->_selectedText = bangla;
        _svc->EnsureComposition(_ctx, ec);
        _svc->UpdateCompositionText(_ctx, ec, bangla);
        _svc->RefreshCandidates(_ctx, ec);
    }
    return S_OK;
}

STDMETHODIMP CCommitEditSession::DoEditSession(TfEditCookie ec)
{
    if (_svc->_latinBuffer.empty()) return S_OK;
    _svc->CommitBuffer(_ctx, ec);
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

void CByakaronTextService::HideCandidates()
{
    _candidateWindow.End();
}

std::wstring CByakaronTextService::TextToCommit()
{
    if (!_selectedText.empty()) return _selectedText;
    if (_candidateWindow.IsVisible())
    {
        auto sel = _candidateWindow.SelectedText();
        if (!sel.empty()) return sel;
    }
    return _transliterator.ToBangla(_latinBuffer);
}

void CByakaronTextService::CommitBuffer(ITfContext* pic, TfEditCookie ec)
{
    if (_latinBuffer.empty()) return;
    std::wstring text = TextToCommit();
    EnsureComposition(pic, ec);
    UpdateCompositionText(pic, ec, text);
    TerminateComposition(ec);
    ResetCompositionState();
}

bool CByakaronTextService::GetCompositionScreenRect(ITfContext* pic, TfEditCookie ec, RECT* out) const
{
    if (!pic || !out || !_pComposition) return false;

    ITfRange* range = nullptr;
    if (FAILED(_pComposition->GetRange(&range)) || !range) return false;

    ITfContextView* view = nullptr;
    if (FAILED(pic->GetActiveView(&view)) || !view)
    {
        range->Release();
        return false;
    }

    BOOL clipped = FALSE;
    const HRESULT hr = view->GetTextExt(ec, range, out, &clipped);
    view->Release();
    range->Release();
    return SUCCEEDED(hr) && (out->right > out->left || out->bottom > out->top);
}

void CByakaronTextService::RefreshCandidates(ITfContext* pic, TfEditCookie ec)
{
    if (ByakaronSettings::PhoneticOnly() || _latinBuffer.empty())
    {
        HideCandidates();
        return;
    }

    const std::wstring bangla = _transliterator.ToBangla(_latinBuffer);
    const int limit = ByakaronSettings::CandidatesPerPage();
    auto list = _dictionary.Suggestions(_latinBuffer, bangla, limit);

    // Only surface the TSF candidate UI when there is more than one choice.
    if (list.size() <= 1)
    {
        HideCandidates();
        _selectedText = bangla;
        return;
    }

    _candidateWindow.SetCandidates(list, 0, ByakaronSettings::OrientationVertical());
    _selectedText = list[0];

    int x = 0, y = 0;
    RECT rc = {};
    if (GetCompositionScreenRect(pic, ec, &rc))
    {
        x = rc.left;
        y = rc.bottom + 2;
    }
    else
    {
        POINT pt = {};
        GetCaretPos(&pt);
        HWND fg = GetForegroundWindow();
        if (fg) ClientToScreen(fg, &pt);
        x = pt.x;
        y = pt.y + 24;
    }

    // Negotiates with ITfUIElementMgr; host may draw (UI-less) or allow our tip UI.
    _candidateWindow.BeginAt(x, y);
}

void CByakaronTextService::ResetCompositionState()
{
    _latinBuffer.clear();
    _selectedText.clear();
    HideCandidates();
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
