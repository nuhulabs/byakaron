using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Byakaron.Settings;

/// <summary>
/// Shared HKCU settings for the WinUI app and ByakaronIME.dll.
/// Mirrors macOS ByakaronSettings (suite: dev.nuhu.labs.Byakaron.shared).
/// </summary>
public static class ByakaronSettings
{
    public const string RootKey = @"Software\Byakaron";
    public const string PhoneticOnlyModeKey = "PhoneticOnlyMode";
    public const string CandidateOrientationKey = "CandidateOrientation";
    public const string CandidatesPerPageKey = "CandidatesPerPage";
    private const string ChangeEventName = @"Local\ByakaronSettingsChanged";

    public static bool PhoneticOnlyMode
    {
        get => ReadDword(PhoneticOnlyModeKey, 0) != 0;
        set => WriteDword(PhoneticOnlyModeKey, value ? 1u : 0u);
    }

    /// <summary>"horizontal" or "vertical".</summary>
    public static string CandidateOrientation
    {
        get => ReadString(CandidateOrientationKey, "horizontal");
        set => WriteString(CandidateOrientationKey, value is "vertical" ? "vertical" : "horizontal");
    }

    public static bool OrientationVertical
    {
        get => string.Equals(CandidateOrientation, "vertical", StringComparison.OrdinalIgnoreCase);
        set => CandidateOrientation = value ? "vertical" : "horizontal";
    }

    public static int CandidatesPerPage
    {
        get
        {
            var v = (int)ReadDword(CandidatesPerPageKey, 9);
            if (v < 3) return 3;
            if (v > 9) return 9;
            return v;
        }
        set
        {
            if (value < 3) value = 3;
            if (value > 9) value = 9;
            WriteDword(CandidatesPerPageKey, (uint)value);
        }
    }

    public static void NotifyChanged()
    {
        var handle = CreateEventW(IntPtr.Zero, false, false, ChangeEventName);
        if (handle != IntPtr.Zero)
        {
            SetEvent(handle);
            CloseHandle(handle);
        }
    }

    private static uint ReadDword(string name, uint defaultValue)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RootKey, writable: false);
        if (key?.GetValue(name) is int i) return unchecked((uint)i);
        if (key?.GetValue(name) is long l) return unchecked((uint)l);
        return defaultValue;
    }

    private static void WriteDword(string name, uint value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RootKey);
        key.SetValue(name, unchecked((int)value), RegistryValueKind.DWord);
        NotifyChanged();
    }

    private static string ReadString(string name, string defaultValue)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RootKey, writable: false);
        return key?.GetValue(name) as string ?? defaultValue;
    }

    private static void WriteString(string name, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RootKey);
        key.SetValue(name, value, RegistryValueKind.String);
        NotifyChanged();
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateEventW(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetEvent(IntPtr hEvent);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
