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

    // Only the values that were set; the rest take the shared defaults. The
    // core clamps candidates_per_page.
    DWORD dword = 0;
    std::wstring text;
    if (ReadDword(key, L"PhoneticOnlyMode", &dword))
        composer.SetSetting("suggestions", dword ? 0 : 1);
    if (ReadString(key, L"CandidateOrientation", &text))
        composer.SetSetting("candidate_orientation", text == L"vertical" ? 1 : 0);
    if (ReadDword(key, L"CandidatesPerPage", &dword))
        composer.SetSetting("candidates_per_page", (int)dword);
    RegCloseKey(key);
}
} // namespace ByakaronSettings
