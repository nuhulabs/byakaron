#include "Globals.h"
#include "TextService.h"
#include <new>
#include <strsafe.h>
#include <msctf.h>

HINSTANCE g_hInst = nullptr;
LONG g_dllRefCount = 0;

void DllAddRef() { InterlockedIncrement(&g_dllRefCount); }
void DllRelease() { InterlockedDecrement(&g_dllRefCount); }

typedef BOOL(WINAPI* PFN_InstallLayoutOrTip)(LPCWSTR psz, DWORD dwFlags);
#ifndef ILOT_UNINSTALL
#define ILOT_UNINSTALL 0x00000001
#endif

static HRESULT RegisterProfiles();
static HRESULT UnregisterProfiles();
static HRESULT RegisterCategories();
static HRESULT UnregisterCategories();
static HRESULT RegisterServer();
static HRESULT UnregisterServer();
static void EnableTip(BOOL enable);
static void StringFromGuid(REFGUID guid, WCHAR* buf, size_t cch);

static const GUID c_rgCategories[] =
{
    GUID_TFCAT_TIP_KEYBOARD,
    GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
};

BOOL APIENTRY DllMain(HINSTANCE hInst, DWORD reason, LPVOID /*reserved*/)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_hInst = hInst;
        DisableThreadLibraryCalls(hInst);
    }
    return TRUE;
}

STDAPI DllCanUnloadNow()
{
    return g_dllRefCount > 0 ? S_FALSE : S_OK;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;
    if (!IsEqualCLSID(rclsid, CLSID_ByakaronTextService))
        return CLASS_E_CLASSNOTAVAILABLE;

    CClassFactory* factory = new (std::nothrow) CClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    HRESULT hr = factory->QueryInterface(riid, ppvObj);
    factory->Release();
    return hr;
}

STDAPI DllRegisterServer()
{
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool needUninit = SUCCEEDED(hr);
    if (hr == S_FALSE) { /* already initialized */ }

    hr = RegisterServer();
    if (SUCCEEDED(hr)) hr = RegisterProfiles();
    if (SUCCEEDED(hr)) hr = RegisterCategories();
    if (SUCCEEDED(hr)) EnableTip(TRUE);

    if (needUninit && hr != S_FALSE) CoUninitialize();
    return hr;
}

STDAPI DllUnregisterServer()
{
    HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    EnableTip(FALSE);
    UnregisterCategories();
    UnregisterProfiles();
    UnregisterServer();
    if (SUCCEEDED(hrInit)) CoUninitialize();
    return S_OK;
}

static void StringFromGuid(REFGUID guid, WCHAR* buf, size_t cch)
{
    StringCchPrintfW(buf, cch,
        L"{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
        guid.Data1, guid.Data2, guid.Data3,
        guid.Data4[0], guid.Data4[1], guid.Data4[2], guid.Data4[3],
        guid.Data4[4], guid.Data4[5], guid.Data4[6], guid.Data4[7]);
}

static HRESULT RegisterServer()
{
    WCHAR clsid[64] = {};
    StringFromGuid(CLSID_ByakaronTextService, clsid, 64);

    WCHAR keyPath[256] = {};
    StringCchPrintfW(keyPath, 256, L"CLSID\\%s", clsid);

    HKEY hKey = nullptr;
    LONG err = RegCreateKeyExW(HKEY_CLASSES_ROOT, keyPath, 0, nullptr, 0, KEY_WRITE, nullptr, &hKey, nullptr);
    if (err != ERROR_SUCCESS) return HRESULT_FROM_WIN32(err);

    RegSetValueExW(hKey, nullptr, 0, REG_SZ, (const BYTE*)TEXTSERVICE_DESC,
        (DWORD)((wcslen(TEXTSERVICE_DESC) + 1) * sizeof(WCHAR)));

    HKEY hSub = nullptr;
    err = RegCreateKeyExW(hKey, L"InProcServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &hSub, nullptr);
    if (err == ERROR_SUCCESS)
    {
        WCHAR module[MAX_PATH] = {};
        GetModuleFileNameW(g_hInst, module, MAX_PATH);
        RegSetValueExW(hSub, nullptr, 0, REG_SZ, (const BYTE*)module,
            (DWORD)((wcslen(module) + 1) * sizeof(WCHAR)));
        RegSetValueExW(hSub, L"ThreadingModel", 0, REG_SZ, (const BYTE*)TEXTSERVICE_MODEL,
            (DWORD)((wcslen(TEXTSERVICE_MODEL) + 1) * sizeof(WCHAR)));
        RegCloseKey(hSub);
    }
    RegCloseKey(hKey);
    return S_OK;
}

static HRESULT UnregisterServer()
{
    WCHAR clsid[64] = {};
    StringFromGuid(CLSID_ByakaronTextService, clsid, 64);
    WCHAR keyPath[256] = {};
    StringCchPrintfW(keyPath, 256, L"CLSID\\%s\\InProcServer32", clsid);
    RegDeleteKeyW(HKEY_CLASSES_ROOT, keyPath);
    StringCchPrintfW(keyPath, 256, L"CLSID\\%s", clsid);
    RegDeleteKeyW(HKEY_CLASSES_ROOT, keyPath);
    return S_OK;
}

static HRESULT RegisterProfiles()
{
    ITfInputProcessorProfiles* profiles = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
        IID_ITfInputProcessorProfiles, (void**)&profiles);
    if (FAILED(hr) || !profiles) return hr;

    WCHAR module[MAX_PATH] = {};
    GetModuleFileNameW(g_hInst, module, MAX_PATH);

    hr = profiles->Register(CLSID_ByakaronTextService);
    if (FAILED(hr))
    {
        profiles->Release();
        return hr;
    }

    const DWORD caps = TF_IPP_CAPS_IMMERSIVESUPPORT | TF_IPP_CAPS_SYSTRAYSUPPORT;
    ITfInputProcessorProfileMgr* mgr = nullptr;
    profiles->QueryInterface(IID_ITfInputProcessorProfileMgr, (void**)&mgr);

    for (LANGID langid : BYAKARON_LANGIDS)
    {
        profiles->AddLanguageProfile(
            CLSID_ByakaronTextService,
            langid,
            GUID_ByakaronProfile,
            TEXTSERVICE_DESC,
            (ULONG)wcslen(TEXTSERVICE_DESC),
            module,
            (ULONG)wcslen(module),
            0);

        // Make sure the profile is enabled for this user/language.
        profiles->EnableLanguageProfile(
            CLSID_ByakaronTextService,
            langid,
            GUID_ByakaronProfile,
            TRUE);

        if (mgr)
        {
            mgr->RegisterProfile(
                CLSID_ByakaronTextService,
                langid,
                GUID_ByakaronProfile,
                TEXTSERVICE_DESC,
                (ULONG)wcslen(TEXTSERVICE_DESC),
                module,
                (ULONG)wcslen(module),
                0,
                nullptr,
                0,
                TRUE,
                caps);
        }
    }

    if (mgr) mgr->Release();

    // Drop legacy Bangla (India) profile from earlier installs.
    profiles->EnableLanguageProfile(
        CLSID_ByakaronTextService,
        0x0445,
        GUID_ByakaronProfile,
        FALSE);

    profiles->Release();
    return S_OK;
}

static HRESULT RegisterCategories()
{
    ITfCategoryMgr* catMgr = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
        IID_ITfCategoryMgr, (void**)&catMgr);
    if (FAILED(hr) || !catMgr) return hr;

    for (const GUID& cat : c_rgCategories)
    {
        hr = catMgr->RegisterCategory(CLSID_ByakaronTextService, cat, CLSID_ByakaronTextService);
        if (FAILED(hr)) break;
    }

    catMgr->Release();
    return hr;
}

static HRESULT UnregisterCategories()
{
    ITfCategoryMgr* catMgr = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
        IID_ITfCategoryMgr, (void**)&catMgr);
    if (FAILED(hr) || !catMgr) return hr;

    for (const GUID& cat : c_rgCategories)
    {
        catMgr->UnregisterCategory(CLSID_ByakaronTextService, cat, CLSID_ByakaronTextService);
    }

    catMgr->Release();
    return S_OK;
}

static HRESULT UnregisterProfiles()
{
    ITfInputProcessorProfiles* profiles = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
        IID_ITfInputProcessorProfiles, (void**)&profiles);
    if (FAILED(hr) || !profiles) return hr;

    profiles->Unregister(CLSID_ByakaronTextService);
    profiles->Release();
    return S_OK;
}

static void InstallOrRemoveTip(PFN_InstallLayoutOrTip fn, LANGID langid, BOOL enable)
{
    WCHAR clsid[64] = {};
    WCHAR profile[64] = {};
    StringFromGuid(CLSID_ByakaronTextService, clsid, 64);
    StringFromGuid(GUID_ByakaronProfile, profile, 64);

    WCHAR tip[256] = {};
    // Format: <LangID>:{CLSID}{ProfileGUID} — TIP only, not a keyboard layout.
    StringCchPrintfW(tip, 256, L"%04X:%s%s", langid, clsid, profile);
    fn(tip, enable ? 0 : ILOT_UNINSTALL);
}

static void EnableTip(BOOL enable)
{
    HMODULE input = LoadLibraryW(L"input.dll");
    if (!input) return;
    auto fn = (PFN_InstallLayoutOrTip)GetProcAddress(input, "InstallLayoutOrTip");
    if (fn)
    {
        // Always strip legacy bn-IN registration from earlier builds.
        InstallOrRemoveTip(fn, 0x0445, FALSE);

        for (LANGID langid : BYAKARON_LANGIDS)
        {
            InstallOrRemoveTip(fn, langid, enable);
        }
    }
    FreeLibrary(input);
}
