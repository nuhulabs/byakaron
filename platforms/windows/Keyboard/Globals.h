#pragma once

#include <windows.h>
#include <msctf.h>
#include <ctffunc.h>

// Byakaron Bangla phonetic IME (Avro) — TSF TIP, NOT InScript.
// InScript is a physical key layout; Byakaron is Latin→Bangla composition.

// {B1A7C0DE-5E11-4B00-9A00-B1A7C0DE5E11}
static const CLSID CLSID_ByakaronTextService =
{
    0xB1A7C0DE, 0x5E11, 0x4B00,
    { 0x9A, 0x00, 0xB1, 0xA7, 0xC0, 0xDE, 0x5E, 0x11 }
};

// {B1A7C0DE-5E11-4B00-9A01-B1A7C0DE5E11}
static const GUID GUID_ByakaronProfile =
{
    0xB1A7C0DE, 0x5E11, 0x4B00,
    { 0x9A, 0x01, 0xB1, 0xA7, 0xC0, 0xDE, 0x5E, 0x11 }
};

// Register under both common Bangla LANGIDs so Win+Space can select us
// whether the user added Bangla (Bangladesh) or Bangla (India).
static const LANGID BYAKARON_LANGIDS[] = {
    0x0845, // bn-BD
    0x0445, // bn-IN
};

#define TEXTSERVICE_DESC L"Byakaron Phonetic"
#define TEXTSERVICE_DESC_A "Byakaron Phonetic"
#define TEXTSERVICE_MODEL L"Apartment"

extern HINSTANCE g_hInst;
extern LONG g_dllRefCount;

void DllAddRef();
void DllRelease();
