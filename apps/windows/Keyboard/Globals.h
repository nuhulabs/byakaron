#pragma once

#include <windows.h>
#include <msctf.h>
#ifdef __MINGW32__
#include "MsctfMingw.h"
#endif

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

// Bangla (Bangladesh) only. We do not register under bn-IN or install
// any physical keyboard layout — just the Byakaron Phonetic TIP profile.
static const LANGID BYAKARON_LANGID = 0x0845; // bn-BD
static const LANGID BYAKARON_LANGIDS[] = { BYAKARON_LANGID };

#define TEXTSERVICE_DESC L"Byakaron Phonetic"
#define TEXTSERVICE_DESC_A "Byakaron Phonetic"
#define TEXTSERVICE_MODEL L"Apartment"

extern HINSTANCE g_hInst;
extern LONG g_dllRefCount;

void DllAddRef();
void DllRelease();
