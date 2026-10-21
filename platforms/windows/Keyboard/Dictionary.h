#pragma once

#include <windows.h>
#include <string>
#include <vector>

// Zig autocomplete lexicon (byakaron_ac_*) — mirrors macOS PhoneticDictionary.
class PhoneticDictionary
{
public:
    PhoneticDictionary();
    ~PhoneticDictionary();

    PhoneticDictionary(const PhoneticDictionary&) = delete;
    PhoneticDictionary& operator=(const PhoneticDictionary&) = delete;

    bool EnsureReady();
    std::vector<std::wstring> Suggestions(const std::wstring& latin, const std::wstring& phonetic, int limit);

private:
    bool LoadFfi();

    HMODULE _ffi = nullptr;
    void* _ac = nullptr;

    using PFN_ac_create = void* (__cdecl*)();
    using PFN_ac_destroy = void (__cdecl*)(void*);
    using PFN_ac_prefix = char* (__cdecl*)(void*, const char*, int);
    using PFN_string_free = void (__cdecl*)(char*);

    PFN_ac_create _acCreate = nullptr;
    PFN_ac_destroy _acDestroy = nullptr;
    PFN_ac_prefix _acPrefix = nullptr;
    PFN_string_free _stringFree = nullptr;
};
