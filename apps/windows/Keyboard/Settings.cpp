#include "Settings.h"
#include "Composer.h"
#include "Globals.h"

namespace
{
constexpr wchar_t kLegacyRoot[] = L"Software\\Byakaron";

bool ReadDword(HKEY key, const wchar_t* name, DWORD* out)
{
    DWORD type = 0;
    DWORD data = 0;
    DWORD size = sizeof(data);
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(&data), &size) != ERROR_SUCCESS ||
        type != REG_DWORD)
    {
        return false;
    }
    *out = data;
    return true;
}

bool ReadString(HKEY key, const wchar_t* name, std::wstring* out)
{
    WCHAR buf[64] = {};
    DWORD type = 0;
    DWORD size = sizeof(buf) - sizeof(WCHAR); // keep a NUL even if the value has none
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(buf), &size) != ERROR_SUCCESS ||
        type != REG_SZ || buf[0] == L'\0')
    {
        return false;
    }
    *out = buf;
    return true;
}

bool FileExists(const std::wstring& path)
{
    const DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

// Folder holding ByakaronIME.dll, without a trailing backslash.
std::wstring ModuleDir()
{
    WCHAR path[MAX_PATH] = {};
    const DWORD n = GetModuleFileNameW(g_hInst, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::wstring dir(path, n);
    const size_t slash = dir.find_last_of(L'\\');
    if (slash == std::wstring::npos) return {};
    dir.resize(slash);
    return dir;
}
} // namespace

namespace ByakaronSettings
{
std::wstring DataDir()
{
    WCHAR base[MAX_PATH] = {};
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    return std::wstring(base) + L"\\Byakaron";
}

std::wstring SpellDbPath()
{
    const std::wstring dir = ModuleDir();
    if (dir.empty()) return {};
    const std::wstring here = dir + L"\\Byakaron.db";
    if (FileExists(here)) return here;

    // Installed layout (Byakaron.iss): {app}\ime\ByakaronIME.dll, {app}\native\Byakaron.db.
    const size_t slash = dir.find_last_of(L'\\');
    if (slash == std::wstring::npos) return {};
    const std::wstring shipped = dir.substr(0, slash) + L"\\native\\Byakaron.db";
    return FileExists(shipped) ? shipped : std::wstring();
}

void MigrateLegacy(Composer& composer)
{
    const std::wstring dir = DataDir();
    if (dir.empty() || FileExists(dir + L"\\settings.json")) return;

    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kLegacyRoot, 0, KEY_READ, &key) != ERROR_SUCCESS) return;

    // Only the values that were set; the rest take the shared defaults.
    std::string json;
    auto add = [&json](const std::string& field)
    {
        json += json.empty() ? "{" : ",";
        json += field;
    };
    DWORD dword = 0;
    std::wstring text;
    if (ReadDword(key, L"PhoneticOnlyMode", &dword))
        add(std::string("\"suggestions\":") + (dword ? "false" : "true"));
    if (ReadString(key, L"CandidateOrientation", &text))
        add(std::string("\"candidate_orientation\":\"") + (text == L"vertical" ? "vertical" : "horizontal") + "\"");
    if (ReadDword(key, L"CandidatesPerPage", &dword))
    {
        if (dword < 3) dword = 3;
        if (dword > 9) dword = 9;
        add("\"candidates_per_page\":" + std::to_string(dword));
    }
    RegCloseKey(key);

    if (json.empty()) return;
    json += "}";
    composer.SetSettingsJson(json);
}

bool JsonBool(const std::string& json, const char* key, bool fallback)
{
    const std::string needle = std::string("\"") + key + "\"";
    size_t at = json.find(needle);
    if (at == std::string::npos) return fallback;
    at += needle.size();
    while (at < json.size() && (json[at] == ' ' || json[at] == '\t' || json[at] == '\r' || json[at] == '\n' || json[at] == ':'))
        ++at;
    if (json.compare(at, 4, "true") == 0) return true;
    if (json.compare(at, 5, "false") == 0) return false;
    return fallback;
}
} // namespace ByakaronSettings
