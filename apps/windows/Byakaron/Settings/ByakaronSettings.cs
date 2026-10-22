using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using Byakaron.Interop;
using Microsoft.Win32;

namespace Byakaron.Settings;

/// <summary>
/// The settings every Byakaron keyboard shares (<c>src/Composer/Settings.zig</c>).
/// </summary>
public sealed class KeyboardSettings
{
    public const int MinCandidatesPerPage = 3;
    public const int MaxCandidatesPerPage = 9;

    /// <summary>Avro dictionary mode; off is plain phonetic typing with no list.</summary>
    public bool Suggestions { get; set; } = true;
    public bool SpellingCorrections { get; set; } = true;
    public bool LearnChoices { get; set; } = true;
    public bool BanglaDigits { get; set; } = true;
    public bool NewlineOnEnter { get; set; }
    public bool Vertical { get; set; }
    public int CandidatesPerPage { get; set; } = MaxCandidatesPerPage;
}

/// <summary>
/// Keyboard settings and the personal dictionary in <c>%LOCALAPPDATA%\Byakaron</c>,
/// read and written through a composer on that directory
/// (<c>byakaron_settings_*</c>, <c>byakaron_userdict_*</c>). Running keyboards
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

    public KeyboardSettings Load()
    {
        var result = new KeyboardSettings();
        if (_composer == nint.Zero)
        {
            return result;
        }

        var json = ByakaronNative.TakeUtf8String(ByakaronNative.SettingsGet(_composer));
        if (string.IsNullOrEmpty(json))
        {
            return result;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            result.Suggestions = ReadBool(root, "suggestions", result.Suggestions);
            result.SpellingCorrections = ReadBool(root, "spelling_corrections", result.SpellingCorrections);
            result.LearnChoices = ReadBool(root, "learn_choices", result.LearnChoices);
            result.BanglaDigits = ReadBool(root, "bangla_digits", result.BanglaDigits);
            result.NewlineOnEnter = ReadBool(root, "newline_on_enter", result.NewlineOnEnter);
            result.Vertical =
                root.TryGetProperty("candidate_orientation", out var orientation) &&
                orientation.ValueKind == JsonValueKind.String &&
                orientation.GetString() == "vertical";
            if (root.TryGetProperty("candidates_per_page", out var perPage) && perPage.TryGetInt32(out var n))
            {
                result.CandidatesPerPage = Math.Clamp(n, KeyboardSettings.MinCandidatesPerPage, KeyboardSettings.MaxCandidatesPerPage);
            }
        }
        catch (JsonException)
        {
        }
        return result;
    }

    public bool Save(KeyboardSettings settings)
    {
        if (_composer == nint.Zero)
        {
            return false;
        }

        var buffer = new ArrayBufferWriter<byte>();
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteBoolean("suggestions", settings.Suggestions);
            w.WriteBoolean("spelling_corrections", settings.SpellingCorrections);
            w.WriteBoolean("learn_choices", settings.LearnChoices);
            w.WriteBoolean("bangla_digits", settings.BanglaDigits);
            w.WriteBoolean("newline_on_enter", settings.NewlineOnEnter);
            w.WriteString("candidate_orientation", settings.Vertical ? "vertical" : "horizontal");
            w.WriteNumber(
                "candidates_per_page",
                Math.Clamp(settings.CandidatesPerPage, KeyboardSettings.MinCandidatesPerPage, KeyboardSettings.MaxCandidatesPerPage));
            w.WriteEndObject();
        }
        return ByakaronNative.SettingsSet(_composer, Encoding.UTF8.GetString(buffer.WrittenSpan)) == 0;
    }

    public List<string> UserWords()
    {
        var words = new List<string>();
        if (_composer == nint.Zero)
        {
            return words;
        }

        var json = ByakaronNative.TakeUtf8String(ByakaronNative.UserDictGet(_composer));
        if (string.IsNullOrEmpty(json))
        {
            return words;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in doc.RootElement.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } word)
                    {
                        words.Add(word);
                    }
                }
            }
        }
        catch (JsonException)
        {
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

    private static bool ReadBool(JsonElement root, string name, bool fallback) =>
        root.TryGetProperty(name, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? v.GetBoolean()
            : fallback;

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
            if (phoneticOnly is null && string.IsNullOrEmpty(orientation) && perPage is null)
            {
                return;
            }

            // Only the values that were set; the rest take the shared defaults.
            var buffer = new ArrayBufferWriter<byte>();
            using (var w = new Utf8JsonWriter(buffer))
            {
                w.WriteStartObject();
                if (phoneticOnly is int p)
                {
                    w.WriteBoolean("suggestions", p == 0);
                }
                if (!string.IsNullOrEmpty(orientation))
                {
                    w.WriteString("candidate_orientation", orientation == "vertical" ? "vertical" : "horizontal");
                }
                if (perPage is int n)
                {
                    w.WriteNumber("candidates_per_page", Math.Clamp(n, KeyboardSettings.MinCandidatesPerPage, KeyboardSettings.MaxCandidatesPerPage));
                }
                w.WriteEndObject();
            }
            ByakaronNative.SettingsSet(_composer, Encoding.UTF8.GetString(buffer.WrittenSpan));
        }
        catch (Exception)
        {
            // Migration is best effort; defaults apply.
        }
    }
}
