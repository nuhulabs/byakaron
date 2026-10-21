#pragma once

#include <windows.h>
#include <string>

// Shared HKCU settings — WinUI app and ByakaronIME.dll both read/write these.
// Mirrors macOS ByakaronSettings suite (dev.nuhu.labs.Byakaron.shared).
namespace ByakaronSettings
{
    inline constexpr wchar_t kRoot[] = L"Software\\Byakaron";

    // When true, commit phonetic only — no candidate panel (macOS phoneticOnly).
    inline constexpr wchar_t kPhoneticOnly[] = L"PhoneticOnlyMode";
    // "horizontal" | "vertical"
    inline constexpr wchar_t kOrientation[] = L"CandidateOrientation";
    // 3..9
    inline constexpr wchar_t kPerPage[] = L"CandidatesPerPage";

    bool PhoneticOnly();
    void SetPhoneticOnly(bool value);

    bool OrientationVertical();
    void SetOrientationVertical(bool vertical);

    int CandidatesPerPage();
    void SetCandidatesPerPage(int value);

    // Named event so a running IME can refresh without polling heavily.
    void NotifyChanged();
    HANDLE OpenChangeEvent();
}
