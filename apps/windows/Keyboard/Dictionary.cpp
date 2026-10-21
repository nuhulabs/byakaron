#include "Dictionary.h"
#include "Globals.h"
#include <strsafe.h>
#include <algorithm>

static std::string WideToUtf8Dict(const std::wstring& w)
{
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static std::wstring Utf8ToWideDict(const char* u, int len = -1)
{
    if (!u) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, u, len, nullptr, 0);
    if (n <= 0) return {};
    if (len < 0) n -= 1; // drop NUL when null-terminated
    if (n <= 0) return {};
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, u, len < 0 ? -1 : len, w.data(), n);
    return w;
}

static void TrimInPlace(std::wstring& s)
{
    while (!s.empty() && (s.back() == L'\r' || s.back() == L'\n' || s.back() == L' ' || s.back() == L'\t'))
        s.pop_back();
    size_t i = 0;
    while (i < s.size() && (s[i] == L'\r' || s[i] == L'\n' || s[i] == L' ' || s[i] == L'\t'))
        ++i;
    if (i > 0) s.erase(0, i);
}

// Minimal JSON string-array parse: ["a","b"] with escape unescaping.
static std::vector<std::wstring> ParseJsonStringArray(const char* json)
{
    std::vector<std::wstring> out;
    if (!json) return out;
    const char* p = json;
    while (*p && *p != '[') ++p;
    if (*p != '[') return out;
    ++p;
    while (*p)
    {
        while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' || *p == '\t') ++p;
        if (*p == ']') break;
        if (*p != '"') break;
        ++p;

        std::string unescaped;
        while (*p && *p != '"')
        {
            if (*p == '\\' && p[1])
            {
                ++p;
                switch (*p)
                {
                case '"': case '\\': case '/': unescaped.push_back(*p); break;
                case 'n': unescaped.push_back('\n'); break;
                case 'r': unescaped.push_back('\r'); break;
                case 't': unescaped.push_back('\t'); break;
                case 'u': // skip \uXXXX — Bangla comes through as UTF-8 bytes
                    if (p[1] && p[2] && p[3] && p[4]) p += 4;
                    break;
                default: unescaped.push_back(*p); break;
                }
                ++p;
            }
            else
            {
                unescaped.push_back(*p++);
            }
        }

        auto wide = Utf8ToWideDict(unescaped.c_str(), (int)unescaped.size());
        TrimInPlace(wide);
        if (!wide.empty()) out.push_back(std::move(wide));
        if (*p == '"') ++p;
    }
    return out;
}

PhoneticDictionary::PhoneticDictionary() = default;

PhoneticDictionary::~PhoneticDictionary()
{
    if (_ac && _acDestroy)
    {
        _acDestroy(_ac);
        _ac = nullptr;
    }
    if (_ffi)
    {
        FreeLibrary(_ffi);
        _ffi = nullptr;
    }
}

bool PhoneticDictionary::LoadFfi()
{
    if (_ffi && _acCreate && _acDestroy && _acPrefix && _stringFree) return true;

    WCHAR tipPath[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_hInst, tipPath, MAX_PATH)) return false;
    WCHAR* slash = wcsrchr(tipPath, L'\\');
    if (!slash) return false;
    *slash = L'\0';

    WCHAR ffiPath[MAX_PATH] = {};
    if (FAILED(StringCchPrintfW(ffiPath, MAX_PATH, L"%s\\byakaron.dll", tipPath))) return false;

    _ffi = LoadLibraryExW(ffiPath, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!_ffi) return false;

    _acCreate = reinterpret_cast<PFN_ac_create>(GetProcAddress(_ffi, "byakaron_ac_create"));
    _acDestroy = reinterpret_cast<PFN_ac_destroy>(GetProcAddress(_ffi, "byakaron_ac_destroy"));
    _acPrefix = reinterpret_cast<PFN_ac_prefix>(GetProcAddress(_ffi, "byakaron_ac_prefix"));
    _stringFree = reinterpret_cast<PFN_string_free>(GetProcAddress(_ffi, "byakaron_string_free"));
    return _acCreate && _acDestroy && _acPrefix && _stringFree;
}

bool PhoneticDictionary::EnsureReady()
{
    if (_ac) return true;
    if (!LoadFfi()) return false;
    _ac = _acCreate();
    return _ac != nullptr;
}

std::vector<std::wstring> PhoneticDictionary::Suggestions(
    const std::wstring& latin,
    const std::wstring& phonetic,
    int limit)
{
    std::vector<std::wstring> result;
    if (latin.empty() || limit <= 0) return result;

    // 1) Live phonetic first (macOS order).
    if (!phonetic.empty())
    {
        result.push_back(phonetic);
    }

    if (!EnsureReady())
    {
        return result;
    }

    // Lexicon is Bangla-keyed (see byakaron_ac_prefix / macOS PhoneticDictionary).
    if (!phonetic.empty())
    {
        const std::string utf8 = WideToUtf8Dict(phonetic);
        char* json = _acPrefix(_ac, utf8.c_str(), limit);
        if (json)
        {
            auto extras = ParseJsonStringArray(json);
            _stringFree(json);
            for (auto& s : extras)
            {
                if (s.empty()) continue;
                if (std::find(result.begin(), result.end(), s) != result.end()) continue;
                result.push_back(std::move(s));
                if ((int)result.size() >= limit) break;
            }
        }
    }

    return result;
}
