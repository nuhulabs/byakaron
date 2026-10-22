#include "Composer.h"
#include "Globals.h"
#include <strsafe.h>
#include <cstring>

std::string WideToUtf8(const std::wstring& w)
{
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring Utf8ToWide(const char* u)
{
    if (!u || !*u) return {};
    const int len = (int)strlen(u); // explicit length: no NUL to make room for
    const int n = MultiByteToWideChar(CP_UTF8, 0, u, len, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, u, len, w.data(), n);
    return w;
}

template <typename T>
static bool Resolve(HMODULE module, const char* name, T& out)
{
    out = reinterpret_cast<T>(GetProcAddress(module, name));
    return out != nullptr;
}

Composer::~Composer()
{
    Destroy();
    if (_ffi)
    {
        FreeLibrary(_ffi);
        _ffi = nullptr;
    }
}

bool Composer::LoadFfi()
{
    if (_ffi) return _create != nullptr;

    WCHAR tipPath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_hInst, tipPath, MAX_PATH)) return false;
    WCHAR* slash = wcsrchr(tipPath, L'\\');
    if (!slash) return false;
    *slash = L'\0';

    WCHAR ffiPath[MAX_PATH] = {};
    if (FAILED(StringCchPrintfW(ffiPath, MAX_PATH, L"%s\\byakaron.dll", tipPath))) return false;

    // LOAD_WITH_ALTERED_SEARCH_PATH: resolve byakaron.dll deps from its folder.
    _ffi = LoadLibraryExW(ffiPath, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!_ffi) return false;

    const bool ok =
        Resolve(_ffi, "byakaron_composer_create", _create) &&
        Resolve(_ffi, "byakaron_composer_destroy", _destroy) &&
        Resolve(_ffi, "byakaron_composer_key", _key) &&
        Resolve(_ffi, "byakaron_composer_pick", _pick) &&
        Resolve(_ffi, "byakaron_composer_flush", _flush) &&
        Resolve(_ffi, "byakaron_composer_reset", _reset) &&
        Resolve(_ffi, "byakaron_composer_refresh", _refresh) &&
        Resolve(_ffi, "byakaron_composer_state", _state) &&
        Resolve(_ffi, "byakaron_settings_get", _settingsGet) &&
        Resolve(_ffi, "byakaron_settings_set", _settingsSet) &&
        Resolve(_ffi, "byakaron_string_free", _stringFree);
    if (!ok) _create = nullptr; // an older byakaron.dll: stay unusable
    return ok;
}

bool Composer::Create(const std::wstring& dataDir, const std::wstring& spellDb, ByakaronUpdateFn onUpdate, void* userdata)
{
    if (_composer) return true;
    if (dataDir.empty() || !LoadFfi()) return false;
    const std::string dir = WideToUtf8(dataDir);
    const std::string db = WideToUtf8(spellDb);
    _composer = _create(dir.c_str(), db.empty() ? nullptr : db.c_str(), onUpdate, userdata);
    return _composer != nullptr;
}

void Composer::Destroy()
{
    // Joins the spell-correction worker: no on_update after this returns.
    if (_composer && _destroy) _destroy(_composer);
    _composer = nullptr;
}

Composer::Result Composer::TakeResult(const ByakaronKeyResult& r)
{
    Result out;
    out.handled = r.handled != 0;
    out.commit = Utf8ToWide(r.commit); // valid only until the next call
    return out;
}

Composer::Result Composer::Key(int kind, unsigned int ch, unsigned int modifiers)
{
    if (!_composer) return {};
    return TakeResult(_key(_composer, kind, ch, modifiers));
}

Composer::Result Composer::Pick(size_t index)
{
    if (!_composer) return {};
    return TakeResult(_pick(_composer, index));
}

std::wstring Composer::Flush()
{
    if (!_composer) return {};
    return Utf8ToWide(_flush(_composer));
}

void Composer::Reset()
{
    if (_composer) _reset(_composer);
}

void Composer::Refresh()
{
    if (_composer) _refresh(_composer);
}

Composer::State Composer::GetState()
{
    State s;
    if (!_composer) return s;
    ByakaronComposerState st = {};
    _state(_composer, &st);
    s.composing = st.composing != 0;
    s.preedit = Utf8ToWide(st.preedit);
    s.panelVisible = st.panel_visible != 0;
    s.vertical = st.vertical != 0;
    s.candidates.reserve(st.candidate_count);
    for (size_t i = 0; i < st.candidate_count; ++i) s.candidates.push_back(Utf8ToWide(st.candidates[i]));
    s.highlight = st.highlight;
    s.page = st.page;
    s.pageCount = st.page_count;
    return s;
}

bool Composer::Composing()
{
    if (!_composer) return false;
    ByakaronComposerState st = {};
    _state(_composer, &st);
    return st.composing != 0;
}

std::string Composer::SettingsJson()
{
    if (!_composer) return {};
    char* json = _settingsGet(_composer);
    if (!json) return {};
    std::string out(json);
    _stringFree(json);
    return out;
}

bool Composer::SetSettingsJson(const std::string& json)
{
    if (!_composer) return false;
    return _settingsSet(_composer, json.c_str()) == 0;
}
