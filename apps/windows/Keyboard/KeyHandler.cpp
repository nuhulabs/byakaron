#include "TextService.h"
#include "EditSessions.h"
#include "Settings.h"
#include <memory>
#include <new>

namespace
{
constexpr UINT WM_BYAKARON_UPDATE = WM_APP + 1;
constexpr wchar_t kNotifyClassName[] = L"ByakaronNotifyWindow";

bool IsShortcut(unsigned int mods)
{
    return (mods & (BYAKARON_MOD_CTRL | BYAKARON_MOD_ALT | BYAKARON_MOD_META)) != 0;
}

// COM identity: TSF need not hand back the same interface pointer.
bool SameObject(IUnknown* a, IUnknown* b)
{
    if (!a || !b) return false;
    if (a == b) return true;
    IUnknown* ua = nullptr;
    IUnknown* ub = nullptr;
    a->QueryInterface(IID_IUnknown, (void**)&ua);
    b->QueryInterface(IID_IUnknown, (void**)&ub);
    const bool same = ua && ua == ub;
    if (ua) ua->Release();
    if (ub) ub->Release();
    return same;
}

// Put the caret after range.
void CaretAfter(ITfContext* pic, TfEditCookie ec, ITfRange* range)
{
    ITfRange* end = nullptr;
    if (FAILED(range->Clone(&end)) || !end) return;
    end->Collapse(ec, TF_ANCHOR_END);
    TF_SELECTION sel = {};
    sel.range = end;
    sel.style.ase = TF_AE_NONE;
    sel.style.fInterimChar = FALSE;
    pic->SetSelection(ec, 1, &sel);
    end->Release();
}

void SetTextAndCaret(ITfContext* pic, TfEditCookie ec, ITfRange* range, const std::wstring& text)
{
    range->SetText(ec, 0, text.c_str(), (LONG)text.size());
    CaretAfter(pic, ec, range);
}
} // namespace

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
    // Focus moved to another document: the word typed so far is committed where it was.
    CommitPendingWord();

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

STDMETHODIMP CByakaronTextService::OnCompositionTerminated(TfEditCookie /*ecWrite*/, ITfComposition* pComposition)
{
    // The application ended our composition (a click elsewhere, ...). Its text
    // (the preedit) stays in the document; commit the same word in the
    // composer so it is learned and the next key starts a new one.
    if (!_pComposition || !SameObject(pComposition, _pComposition)) return S_OK;
    _pComposition->Release();
    _pComposition = nullptr;
    _composer.Flush();
    _candidateWindow.End();
    return S_OK;
}

// ── Key event sink ──────────────────────────────────────────────────────────

STDMETHODIMP CByakaronTextService::OnSetFocus(BOOL fForeground)
{
    if (!fForeground) CommitPendingWord();
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

CByakaronTextService::KeyInput CByakaronTextService::MapKey(WPARAM wParam, LPARAM lParam)
{
    KeyInput key;
    const UINT vk = (UINT)wParam;
    switch (vk)
    {
    // Pure modifier / lock keys never reach the composer.
    case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
    case VK_MENU: case VK_LMENU: case VK_RMENU:
    case VK_LWIN: case VK_RWIN:
    case VK_CAPITAL: case VK_NUMLOCK: case VK_SCROLL:
    case VK_PROCESSKEY:
        return key;
    default:
        break;
    }

    key.send = true;
    if (GetKeyState(VK_SHIFT) & 0x8000) key.mods |= BYAKARON_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) key.mods |= BYAKARON_MOD_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) key.mods |= BYAKARON_MOD_ALT;
    if ((GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000)) key.mods |= BYAKARON_MOD_META;

    switch (vk)
    {
    case VK_SPACE: key.kind = BYAKARON_KEY_SPACE; return key;
    case VK_RETURN: key.kind = BYAKARON_KEY_ENTER; return key;
    case VK_TAB: key.kind = BYAKARON_KEY_TAB; return key;
    case VK_BACK: key.kind = BYAKARON_KEY_BACKSPACE; return key;
    case VK_ESCAPE: key.kind = BYAKARON_KEY_ESCAPE; return key;
    case VK_UP: key.kind = BYAKARON_KEY_UP; return key;
    case VK_DOWN: key.kind = BYAKARON_KEY_DOWN; return key;
    case VK_LEFT: key.kind = BYAKARON_KEY_LEFT; return key;
    case VK_RIGHT: key.kind = BYAKARON_KEY_RIGHT; return key;
    case VK_PRIOR: key.kind = BYAKARON_KEY_PAGE_UP; return key;
    case VK_NEXT: key.kind = BYAKARON_KEY_PAGE_DOWN; return key;
    default:
        break;
    }

    // Printable ASCII from the active layout (Shift / Caps Lock applied);
    // anything else is BYAKARON_KEY_OTHER.
    BYTE state[256] = {};
    if (!GetKeyboardState(state)) return key;
    WCHAR chars[4] = {};
    // 0x4: leave the keyboard state (dead keys) alone — this also runs for OnTestKeyDown.
    const int n = ToUnicode(vk, (UINT)((lParam >> 16) & 0xFF), state, chars, 4, 0x4);
    if (n == 1 && chars[0] >= 0x21 && chars[0] <= 0x7e)
    {
        key.kind = BYAKARON_KEY_CHAR;
        key.ch = chars[0];
    }
    return key;
}

// Whether byakaron_composer_key would consume the key or commit text for it,
// worked out without calling it (OnTestKeyDown must not change state; OnKeyDown
// follows only when this says yes).
BOOL CByakaronTextService::WouldEat(const KeyInput& key)
{
    // While composing every key edits, moves, commits or drops the word.
    if (_composer.Composing()) return TRUE;
    if (key.kind != BYAKARON_KEY_CHAR || IsShortcut(key.mods)) return FALSE;
    // Outside a word, digits pass through unless they become Bangla digits.
    if (key.ch >= '0' && key.ch <= '9')
        return ByakaronSettings::JsonBool(_composer.SettingsJson(), "bangla_digits", true) ? TRUE : FALSE;
    return TRUE;
}

BOOL CByakaronTextService::HandleKey(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL testOnly)
{
    if (!pic || !_composer.Ready()) return FALSE;
    const KeyInput key = MapKey(wParam, lParam);
    if (!key.send) return FALSE;
    if (testOnly) return WouldEat(key);

    auto handled = std::make_shared<bool>(false);
    RunEditSession(pic, _tfClientId, Owner(), [this, pic, key, handled](TfEditCookie ec)
    {
        const Composer::Result r = _composer.Key(key.kind, key.ch, key.mods);
        Apply(pic, ec, r.commit);
        *handled = r.handled;
    }, TF_ES_SYNC);
    // Not handled: the application gets the key too (after the commit).
    return *handled ? TRUE : FALSE;
}

// ── Composer state -> document and candidate UI ─────────────────────────────

void CByakaronTextService::Apply(ITfContext* pic, TfEditCookie ec, const std::wstring& commit)
{
    if (!commit.empty()) InsertCommit(pic, ec, commit);
    Redraw(pic, ec);
}

void CByakaronTextService::InsertCommit(ITfContext* pic, TfEditCookie ec, const std::wstring& text)
{
    if (_pComposition)
    {
        // The committed word replaces the inline preedit.
        SetCompositionText(pic, ec, text);
        EndComposition(ec);
        return;
    }

    ITfInsertAtSelection* insert = nullptr;
    if (FAILED(pic->QueryInterface(IID_ITfInsertAtSelection, (void**)&insert)) || !insert) return;
    ITfRange* range = nullptr;
    if (SUCCEEDED(insert->InsertTextAtSelection(ec, 0, text.c_str(), (LONG)text.size(), &range)) && range)
    {
        CaretAfter(pic, ec, range);
        range->Release();
    }
    insert->Release();
}

void CByakaronTextService::Redraw(ITfContext* pic, TfEditCookie ec)
{
    const Composer::State st = _composer.GetState();
    if (st.composing)
    {
        if (SUCCEEDED(EnsureComposition(pic, ec))) SetCompositionText(pic, ec, st.preedit);
    }
    else if (_pComposition)
    {
        // The word was dropped (Esc, Backspace to empty): clear the inline text
        // first, or ending the composition would leave it in the document.
        SetCompositionText(pic, ec, std::wstring());
        EndComposition(ec);
    }

    if (!st.composing || !st.panelVisible || st.candidates.empty())
    {
        _candidateWindow.End();
        return;
    }
    const POINT at = CandidateOrigin(pic, ec);
    // Negotiates with ITfUIElementMgr; the host may draw it (UI-less) or let us.
    _candidateWindow.Present(st.candidates, (int)st.highlight, st.vertical, at.x, at.y);
}

POINT CByakaronTextService::CandidateOrigin(ITfContext* pic, TfEditCookie ec) const
{
    POINT at = {};
    RECT rc = {};
    if (GetCompositionScreenRect(pic, ec, &rc))
    {
        at.x = rc.left;
        at.y = rc.bottom + 2;
        return at;
    }
    GetCaretPos(&at);
    HWND fg = GetForegroundWindow();
    if (fg) ClientToScreen(fg, &at);
    at.y += 24;
    return at;
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

// ── Work that arrives outside a key event ───────────────────────────────────

void CByakaronTextService::EditComposition(std::function<void(ITfContext*, TfEditCookie)> fn)
{
    ITfContext* ctx = nullptr;
    if (!CompositionContext(&ctx)) return;
    RunEditSession(ctx, _tfClientId, Owner(), [this, ctx, fn](TfEditCookie ec)
    {
        // Possibly deferred: skip if that composition has ended meanwhile.
        ITfContext* now = nullptr;
        if (!CompositionContext(&now)) return;
        const bool same = SameObject(now, ctx);
        now->Release();
        if (same) fn(ctx, ec);
    }, TF_ES_ASYNCDONTCARE);
    ctx->Release();
}

void CByakaronTextService::OnCandidatePicked(UINT index)
{
    EditComposition([this, index](ITfContext* ctx, TfEditCookie ec)
    {
        Apply(ctx, ec, _composer.Pick(index).commit);
    });
}

void CByakaronTextService::OnCandidateFinalize(bool commit)
{
    EditComposition([this, commit](ITfContext* ctx, TfEditCookie ec)
    {
        if (commit)
        {
            Apply(ctx, ec, _composer.Flush());
            return;
        }
        _composer.Reset();
        Apply(ctx, ec, std::wstring());
    });
}

void CByakaronTextService::OnComposerUpdated()
{
    if (!_composer.Ready()) return;
    if (!_pComposition)
    {
        _composer.Refresh();
        return;
    }
    EditComposition([this](ITfContext* ctx, TfEditCookie ec)
    {
        _composer.Refresh();
        Redraw(ctx, ec);
    });
}

void CByakaronTextService::CommitPendingWord()
{
    _candidateWindow.End();
    const std::wstring text = _composer.Flush();
    if (!_pComposition) return;

    ITfContext* ctx = nullptr;
    const bool haveCtx = CompositionContext(&ctx);
    // The session owns the composition from here, so a key arriving before it
    // runs starts a fresh word instead of editing this one.
    std::shared_ptr<ITfComposition> comp(_pComposition, [](ITfComposition* c) { c->Release(); });
    _pComposition = nullptr;
    if (!haveCtx) return;

    RunEditSession(ctx, _tfClientId, nullptr, [comp, ctx, text](TfEditCookie ec)
    {
        ITfRange* range = nullptr;
        if (SUCCEEDED(comp->GetRange(&range)) && range)
        {
            SetTextAndCaret(ctx, ec, range, text);
            range->Release();
        }
        comp->EndComposition(ec);
    }, TF_ES_ASYNCDONTCARE);
    ctx->Release();
}

// ── on_update hop: spell worker thread -> this thread ───────────────────────

void CByakaronTextService::OnComposerUpdate(void* userdata)
{
    // Spell worker thread: touch nothing but the window handle.
    HWND hwnd = static_cast<HWND>(userdata);
    if (hwnd) PostMessageW(hwnd, WM_BYAKARON_UPDATE, 0, 0);
}

LRESULT CALLBACK CByakaronTextService::NotifyWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_NCCREATE)
    {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
    }
    else if (msg == WM_BYAKARON_UPDATE)
    {
        auto* self = reinterpret_cast<CByakaronTextService*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (self) self->OnComposerUpdated();
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

bool CByakaronTextService::CreateNotifyWindow()
{
    if (_hwndNotify) return true;

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    if (!GetClassInfoExW(g_hInst, kNotifyClassName, &wc))
    {
        wc = {};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = NotifyWndProc;
        wc.hInstance = g_hInst;
        wc.lpszClassName = kNotifyClassName;
        if (!RegisterClassExW(&wc)) return false;
    }

    _hwndNotify = CreateWindowExW(0, kNotifyClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, g_hInst, this);
    return _hwndNotify != nullptr;
}

void CByakaronTextService::DestroyNotifyWindow()
{
    if (!_hwndNotify) return;
    SetWindowLongPtrW(_hwndNotify, GWLP_USERDATA, 0);
    DestroyWindow(_hwndNotify);
    _hwndNotify = nullptr;
}

// ── Composition helpers ─────────────────────────────────────────────────────

bool CByakaronTextService::CompositionContext(ITfContext** out) const
{
    *out = nullptr;
    if (!_pComposition) return false;
    ITfRange* range = nullptr;
    if (FAILED(_pComposition->GetRange(&range)) || !range) return false;
    const HRESULT hr = range->GetContext(out);
    range->Release();
    return SUCCEEDED(hr) && *out;
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
    if (SUCCEEDED(hr) && !_pComposition) hr = E_FAIL; // S_OK with NULL: the app refused
    return hr;
}

HRESULT CByakaronTextService::SetCompositionText(ITfContext* pic, TfEditCookie ec, const std::wstring& text)
{
    if (!_pComposition) return E_FAIL;

    ITfRange* range = nullptr;
    if (FAILED(_pComposition->GetRange(&range)) || !range) return E_FAIL;
    SetTextAndCaret(pic, ec, range, text);
    range->Release();
    return S_OK;
}

void CByakaronTextService::EndComposition(TfEditCookie ec)
{
    if (!_pComposition) return;
    _pComposition->EndComposition(ec);
    _pComposition->Release();
    _pComposition = nullptr;
}
