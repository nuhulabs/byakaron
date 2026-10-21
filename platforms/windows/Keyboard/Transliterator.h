#pragma once

#include "Globals.h"
#include <string>

// Thin wrapper around Zig FFI (byakaron.dll) Avro engine.
// Loads the DLL by absolute path next to ByakaronIME.dll so activation works
// when TSF injects the TIP into arbitrary host processes.
class Transliterator
{
public:
    Transliterator();
    ~Transliterator();

    Transliterator(const Transliterator&) = delete;
    Transliterator& operator=(const Transliterator&) = delete;

    bool EnsureReady();
    std::wstring ToBangla(const std::wstring& latin);

private:
    bool LoadFfi();

    HMODULE _ffi = nullptr;
    void* _engine = nullptr; // ByakaronEngine*

    using PFN_create = void* (__cdecl*)(int);
    using PFN_transliterate = char* (__cdecl*)(void*, const char*);
    using PFN_destroy = void (__cdecl*)(void*);
    using PFN_string_free = void (__cdecl*)(char*);

    PFN_create _create = nullptr;
    PFN_transliterate _transliterate = nullptr;
    PFN_destroy _destroy = nullptr;
    PFN_string_free _stringFree = nullptr;
};
