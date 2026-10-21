#include "Transliterator.h"
#include <strsafe.h>

#ifndef BYAKARON_MODE_AVRO
#define BYAKARON_MODE_AVRO 0
#endif

static std::string WideToUtf8(const std::wstring& w)
{
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static std::wstring Utf8ToWide(const char* u)
{
    if (!u || !*u) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, u, -1, nullptr, 0);
    if (n <= 1) return {};
    std::wstring w(n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, u, -1, w.data(), n);
    return w;
}

Transliterator::Transliterator() = default;

Transliterator::~Transliterator()
{
    if (_engine && _destroy)
    {
        _destroy(_engine);
        _engine = nullptr;
    }
    if (_ffi)
    {
        FreeLibrary(_ffi);
        _ffi = nullptr;
    }
}

bool Transliterator::LoadFfi()
{
    if (_ffi && _create && _transliterate && _destroy && _stringFree)
    {
        return true;
    }

    WCHAR tipPath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_hInst, tipPath, MAX_PATH))
    {
        return false;
    }

    WCHAR* slash = wcsrchr(tipPath, L'\\');
    if (!slash)
    {
        return false;
    }
    *slash = L'\0';

    WCHAR ffiPath[MAX_PATH] = {};
    if (FAILED(StringCchPrintfW(ffiPath, MAX_PATH, L"%s\\byakaron.dll", tipPath)))
    {
        return false;
    }

    // LOAD_WITH_ALTERED_SEARCH_PATH: resolve byakaron.dll deps from its folder.
    _ffi = LoadLibraryExW(ffiPath, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!_ffi)
    {
        return false;
    }

    _create = reinterpret_cast<PFN_create>(GetProcAddress(_ffi, "byakaron_engine_create"));
    _transliterate = reinterpret_cast<PFN_transliterate>(GetProcAddress(_ffi, "byakaron_engine_transliterate"));
    _destroy = reinterpret_cast<PFN_destroy>(GetProcAddress(_ffi, "byakaron_engine_destroy"));
    _stringFree = reinterpret_cast<PFN_string_free>(GetProcAddress(_ffi, "byakaron_string_free"));

    return _create && _transliterate && _destroy && _stringFree;
}

bool Transliterator::EnsureReady()
{
    if (_engine)
    {
        return true;
    }
    if (!LoadFfi())
    {
        return false;
    }
    _engine = _create(BYAKARON_MODE_AVRO);
    return _engine != nullptr;
}

std::wstring Transliterator::ToBangla(const std::wstring& latin)
{
    if (latin.empty())
    {
        return {};
    }
    if (!EnsureReady())
    {
        return latin;
    }

    const std::string utf8 = WideToUtf8(latin);
    char* out = _transliterate(_engine, utf8.c_str());
    if (!out)
    {
        return {};
    }
    std::wstring result = Utf8ToWide(out);
    _stringFree(out);
    return result;
}
