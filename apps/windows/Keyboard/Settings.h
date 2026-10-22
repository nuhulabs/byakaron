#pragma once

#include <windows.h>
#include <string>

class Composer;

// Where the keyboard keeps and finds its data. The settings themselves live in
// settings.json (read and written by the composer), shared with the WinUI app.
namespace ByakaronSettings
{
    // %LOCALAPPDATA%\Byakaron: settings.json, selections.json, user-words.txt.
    // Empty on failure.
    std::wstring DataDir();

    // spell.db shipped with the install ({app}\native\spell.db beside {app}\ime\,
    // or next to ByakaronIME.dll); empty when there is none.
    std::wstring SpellDbPath();

    // One-time: while settings.json does not exist, carry the old
    // HKCU\Software\Byakaron values (PhoneticOnlyMode, CandidateOrientation,
    // CandidatesPerPage) over into it. The registry is not read otherwise.
    void MigrateLegacy(Composer& composer);

    // A boolean field of a settings JSON object, or fallback.
    bool JsonBool(const std::string& json, const char* key, bool fallback);
}
