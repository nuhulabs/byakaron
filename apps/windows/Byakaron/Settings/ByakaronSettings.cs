using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using Byakaron.Interop;
using Microsoft.Win32;

namespace Byakaron.Settings;

/// <summary>BYAKARON_CONTROL_*: how a field is drawn and what its number means.</summary>
public enum SettingControl
{
    Toggle = 0,
    Choice = 1,
    Number = 2,
}

/// <summary>A group of settings, with an optional footer.</summary>
public sealed record SettingsSection(string Id, string Title, string? Hint, IReadOnlyList<SettingsField> Fields);

/// <summary>
/// One setting from the shared manifest (<c>src/Composer/Settings.zig</c>):
/// read and write it with <see cref="ByakaronSettings.Get"/> and <see cref="ByakaronSettings.Set"/>.
/// </summary>
public sealed record SettingsField(
    string Key,
    SettingControl Control,
    string Title,
    string? Hint,
    int Min,
    int Max,
    IReadOnlyList<string> Options);

/// <summary>
/// Keyboard settings and the personal dictionary in <c>%LOCALAPPDATA%\Byakaron</c>,
/// read and written through a composer on that directory
/// (<c>byakaron_setting_*</c>, <c>byakaron_userdict_*</c>). Running keyboards
/// pick changes up at their next word.
/// </summary>
public sealed class ByakaronSettings : IDisposable
{
    private const string LegacyRootKey = @"Software\Byakaron";

    private nint _composer;

    private ByakaronSettings(nint composer)
    {
        _composer = composer;
    }

    public static string DataDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Byakaron");

    /// <summary>Open the data directory; null when byakaron_ffi.dll is unavailable.</summary>
    public static ByakaronSettings? Open()
    {
        try
        {
            var dir = DataDirectory;
            var firstRun = !File.Exists(Path.Combine(dir, "settings.json"));
            var composer = ByakaronNative.ComposerCreate(dir, null, nint.Zero, nint.Zero);
            if (composer == nint.Zero)
            {
                return null;
            }

            var settings = new ByakaronSettings(composer);
            if (firstRun)
            {
                settings.MigrateLegacy();
            }
            return settings;
        }
        catch (DllNotFoundException)
        {
            return null;
        }
        catch (EntryPointNotFoundException)
        {
            return null;
        }
    }

    /// <summary>
    /// The sections and the Windows fields of the shared settings manifest, in
    /// the UI language. Empty when byakaron_ffi.dll is unavailable.
    /// </summary>
    public static List<SettingsSection> Manifest()
    {
        var result = new List<SettingsSection>();
        try
        {
            var lang = CultureInfo.CurrentUICulture.Name;
            var sectionCount = ByakaronNative.SettingsSectionCount();
            var fields = new List<SettingsField>[(int)sectionCount];
            for (var i = 0; i < fields.Length; i++)
            {
                fields[i] = new List<SettingsField>();
            }

            var fieldCount = ByakaronNative.SettingsFieldCount();
            for (nuint i = 0; i < fieldCount; i++)
            {
                if (ByakaronNative.SettingsFieldInfo(i, lang, out var f) != 0 ||
                    (f.Platforms & ByakaronNative.PlatformWindows) == 0 ||
                    f.Section >= sectionCount)
                {
                    continue;
                }

                var options = new List<string>();
                for (var o = 0; o < (int)f.OptionCount; o++)
                {
                    var label = Marshal.ReadIntPtr(f.OptionLabels, o * nint.Size);
                    options.Add(ByakaronNative.Utf8String(label) ?? string.Empty);
                }
                fields[(int)f.Section].Add(new SettingsField(
                    ByakaronNative.Utf8String(f.Key) ?? string.Empty,
                    (SettingControl)f.Control,
                    ByakaronNative.Utf8String(f.Title) ?? string.Empty,
                    ByakaronNative.Utf8String(f.Hint),
                    f.Min,
                    f.Max,
                    options));
            }

            for (nuint i = 0; i < sectionCount; i++)
            {
                if (fields[(int)i].Count == 0 || ByakaronNative.SettingsSectionInfo(i, lang, out var s) != 0)
                {
                    continue;
                }
                result.Add(new SettingsSection(
                    ByakaronNative.Utf8String(s.Id) ?? string.Empty,
                    ByakaronNative.Utf8String(s.Title) ?? string.Empty,
                    ByakaronNative.Utf8String(s.Hint),
                    fields[(int)i]));
            }
        }
        catch (DllNotFoundException)
        {
        }
        catch (EntryPointNotFoundException)
        {
        }
        return result;
    }

    /// <summary>A setting as a number (toggle 0/1, choice index, number), or null.</summary>
    public int? Get(string key) =>
        _composer != nint.Zero && ByakaronNative.SettingGet(_composer, key, out var value) == 0 ? value : null;

    /// <summary>Saves the setting; the core clamps it to the field's range.</summary>
    public bool Set(string key, int value) =>
        _composer != nint.Zero && ByakaronNative.SettingSet(_composer, key, value) == 0;

    public List<string> UserWords()
    {
        var words = new List<string>();
        if (_composer == nint.Zero)
        {
            return words;
        }

        var count = ByakaronNative.UserDictCount(_composer);
        for (nuint i = 0; i < count; i++)
        {
            if (ByakaronNative.Utf8String(ByakaronNative.UserDictWord(_composer, i)) is { Length: > 0 } word)
            {
                words.Add(word);
            }
        }
        return words;
    }

    /// <summary>1 added, 0 already there, -1 not a valid word.</summary>
    public int AddUserWord(string word) =>
        _composer == nint.Zero ? -1 : ByakaronNative.UserDictAdd(_composer, word);

    public bool RemoveUserWord(string word) =>
        _composer != nint.Zero && ByakaronNative.UserDictRemove(_composer, word) == 1;

    public void Dispose()
    {
        if (_composer != nint.Zero)
        {
            ByakaronNative.ComposerDestroy(_composer);
            _composer = nint.Zero;
        }
    }

    /// <summary>
    /// One-time, before settings.json exists: carry the old HKCU\Software\Byakaron
    /// values over. The registry is not read otherwise.
    /// </summary>
    private void MigrateLegacy()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(LegacyRootKey, writable: false);
            if (key is null)
            {
                return;
            }

            var phoneticOnly = key.GetValue("PhoneticOnlyMode") as int?;
            var orientation = key.GetValue("CandidateOrientation") as string;
            var perPage = key.GetValue("CandidatesPerPage") as int?;

            // Only the values that were set; the rest take the shared defaults.
            // The core clamps candidates_per_page.
            if (phoneticOnly is int p)
            {
                Set("suggestions", p == 0 ? 1 : 0);
            }
            if (!string.IsNullOrEmpty(orientation))
            {
                Set("candidate_orientation", orientation == "vertical" ? 1 : 0);
            }
            if (perPage is int n)
            {
                Set("candidates_per_page", n);
            }
        }
        catch (Exception)
        {
            // Migration is best effort; defaults apply.
        }
    }
}
