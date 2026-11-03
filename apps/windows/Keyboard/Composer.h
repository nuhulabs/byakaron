#pragma once

#include <windows.h>
#include <string>
#include <vector>
#include "byakaron.h"

// UTF-16 <-> UTF-8 for the C ABI.
std::string WideToUtf8(const std::wstring& w);
std::wstring Utf8ToWide(const char* u);

// The whole keyboard (byakaron_composer_* in byakaron.dll, see src/Composer.zig):
// Avro candidates, paging, learning, personal words, spelling corrections and
// the shared settings. The text service only maps keys in and draws state out.
// byakaron.dll is loaded by absolute path next to ByakaronIME.dll so activation
// works when TSF injects the TIP into arbitrary host processes.
// Not thread-safe: use it from the text service's thread only.
class Composer
{
public:
    struct Result
    {
        bool handled = false;
        std::wstring commit;
    };

    struct State
    {
        bool composing = false;
        std::wstring preedit;
        bool panelVisible = false;
        bool vertical = false;
        std::vector<std::wstring> candidates; // the current page
        size_t highlight = 0;                 // index within the page
        size_t page = 0;
        size_t pageCount = 0;
    };

    Composer() = default;
    ~Composer();

    Composer(const Composer&) = delete;
    Composer& operator=(const Composer&) = delete;

    // spellDb may be empty. onUpdate(userdata) runs on a worker thread.
    bool Create(const std::wstring& dataDir, const std::wstring& spellDb, ByakaronUpdateFn onUpdate, void* userdata);
    void Destroy();
    bool Ready() const { return _composer != nullptr; }

    Result Key(int kind, unsigned int ch, unsigned int modifiers);
    Result Pick(size_t index);
    std::wstring Flush();
    void Reset();
    void Refresh();
    State GetState();
    bool Composing();

    // byakaron_settings_get / set (JSON, see src/Composer/Settings.zig).
    std::string SettingsJson();
    bool SetSettingsJson(const std::string& json);

private:
    bool LoadFfi();
    Result TakeResult(const ByakaronKeyResult& r);

    HMODULE _ffi = nullptr;
    ByakaronComposer* _composer = nullptr;

    // Signatures straight from byakaron.h.
    decltype(&byakaron_composer_create) _create = nullptr;
    decltype(&byakaron_composer_destroy) _destroy = nullptr;
    decltype(&byakaron_composer_key) _key = nullptr;
    decltype(&byakaron_composer_pick) _pick = nullptr;
    decltype(&byakaron_composer_flush) _flush = nullptr;
    decltype(&byakaron_composer_reset) _reset = nullptr;
    decltype(&byakaron_composer_refresh) _refresh = nullptr;
    decltype(&byakaron_composer_state) _state = nullptr;
    decltype(&byakaron_settings_get) _settingsGet = nullptr;
    decltype(&byakaron_settings_set) _settingsSet = nullptr;
    decltype(&byakaron_string_free) _stringFree = nullptr;
};
