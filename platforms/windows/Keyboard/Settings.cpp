#include "Settings.h"

namespace
{
DWORD ReadDword(const wchar_t* name, DWORD defaultValue)
{
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, ByakaronSettings::kRoot, 0, KEY_READ, &key) != ERROR_SUCCESS)
    {
        return defaultValue;
    }
    DWORD type = 0;
    DWORD data = 0;
    DWORD size = sizeof(data);
    const LONG err = RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(&data), &size);
    RegCloseKey(key);
    if (err != ERROR_SUCCESS || type != REG_DWORD)
    {
        return defaultValue;
    }
    return data;
}

void WriteDword(const wchar_t* name, DWORD value)
{
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, ByakaronSettings::kRoot, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS)
    {
        return;
    }
    RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value));
    RegCloseKey(key);
    ByakaronSettings::NotifyChanged();
}

std::wstring ReadString(const wchar_t* name, const wchar_t* defaultValue)
{
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, ByakaronSettings::kRoot, 0, KEY_READ, &key) != ERROR_SUCCESS)
    {
        return defaultValue;
    }
    WCHAR buf[64] = {};
    DWORD type = 0;
    DWORD size = sizeof(buf);
    const LONG err = RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(buf), &size);
    RegCloseKey(key);
    if (err != ERROR_SUCCESS || type != REG_SZ || buf[0] == L'\0')
    {
        return defaultValue;
    }
    return buf;
}

void WriteString(const wchar_t* name, const wchar_t* value)
{
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, ByakaronSettings::kRoot, 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS)
    {
        return;
    }
    RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value),
        (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
    RegCloseKey(key);
    ByakaronSettings::NotifyChanged();
}
} // namespace

namespace ByakaronSettings
{
bool PhoneticOnly()
{
    return ReadDword(kPhoneticOnly, 0) != 0;
}

void SetPhoneticOnly(bool value)
{
    WriteDword(kPhoneticOnly, value ? 1 : 0);
}

bool OrientationVertical()
{
    return ReadString(kOrientation, L"horizontal") == L"vertical";
}

void SetOrientationVertical(bool vertical)
{
    WriteString(kOrientation, vertical ? L"vertical" : L"horizontal");
}

int CandidatesPerPage()
{
    const int v = (int)ReadDword(kPerPage, 9);
    if (v < 3) return 3;
    if (v > 9) return 9;
    return v;
}

void SetCandidatesPerPage(int value)
{
    if (value < 3) value = 3;
    if (value > 9) value = 9;
    WriteDword(kPerPage, (DWORD)value);
}

void NotifyChanged()
{
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, L"Local\\ByakaronSettingsChanged");
    if (ev)
    {
        SetEvent(ev);
        CloseHandle(ev);
    }
}

HANDLE OpenChangeEvent()
{
    return CreateEventW(nullptr, FALSE, FALSE, L"Local\\ByakaronSettingsChanged");
}
} // namespace ByakaronSettings
