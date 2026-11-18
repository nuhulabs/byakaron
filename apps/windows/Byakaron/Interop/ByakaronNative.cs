using System;
using System.Runtime.InteropServices;

namespace Byakaron.Interop;

/// <summary>
/// Raw C ABI for libbyakaron (see <c>src/ffi/byakaron.h</c>).
/// Returned strings are heap UTF-8 owned by the caller — free with <see cref="StringFree"/> —
/// except the settings manifest's and the user dictionary's words, which are not freed.
/// </summary>
internal static partial class ByakaronNative
{
    // Must not be "byakaron" — that collides with the managed Byakaron.dll on
    // Windows (case-insensitive FS) and replaces the IL assembly at runtime.
    private const string LibraryName = "byakaron_ffi";

    // ── Memory ──────────────────────────────────────────────────────────────

    [LibraryImport(LibraryName, EntryPoint = "byakaron_string_free")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void StringFree(nint ptr);

    // ── Spell ───────────────────────────────────────────────────────────────

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_create", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint SpellCreate(string dbPath);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_destroy")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void SpellDestroy(nint spell);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_is_correct", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SpellIsCorrect(nint spell, string word);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_suggest", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint SpellSuggest(nint spell, string word, int limit);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_suggest_ctx", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint SpellSuggestCtx(
        nint spell,
        string word,
        string prev2,
        string prev1,
        string next,
        int limit);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_spell_check", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint SpellCheck(nint spell, string text);

    // ── Composer (keyboard settings + personal dictionary) ─────────────────

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_create", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint ComposerCreate(string dataDir, string? spellDb, nint onUpdate, nint userdata);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_destroy")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void ComposerDestroy(nint composer);

    /// <summary>One setting by key as a number (toggle 0/1, choice index, number). 0, or -1 for an unknown key.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_setting_get", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SettingGet(nint composer, string key, out int value);

    /// <summary>Clamps to the field's range and saves. 0, or -1 for an unknown key.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_setting_set", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SettingSet(nint composer, string key, int value);

    /// <summary>Re-reads the personal dictionary and returns how many words it has.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_count")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nuint UserDictCount(nint composer);

    /// <summary>The index-th word (UTF-8, not owned), or 0 past the end. Valid until the next non-word call.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_word")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint UserDictWord(nint composer, nuint index);

    /// <summary>1 added, 0 already there, -1 not a valid word.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_add", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UserDictAdd(nint composer, string word);

    /// <summary>1 removed, 0 not there, -1 on error.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_remove", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UserDictRemove(nint composer, string word);

    // ── Settings manifest (static strings: do not free) ─────────────────────

    internal const uint PlatformWindows = 8;

    /// <summary>ByakaronSettingsSection.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct SettingsSection
    {
        public nint Id;
        public nint Title;
        public nint Hint;
    }

    /// <summary>ByakaronSettingsField.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct SettingsField
    {
        public nint Key;
        public nuint Section;
        public int Control;
        public nint Title;
        public nint Hint;
        public int Min;
        public int Max;
        public nuint OptionCount;
        public nint OptionValues;
        public nint OptionLabels;
        public uint Platforms;
    }

    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_section_count")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nuint SettingsSectionCount();

    /// <summary>0, or -1 past the end.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_section_info", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SettingsSectionInfo(nuint index, string? lang, out SettingsSection section);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_field_count")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nuint SettingsFieldCount();

    /// <summary>0, or -1 past the end.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_field_info", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SettingsFieldInfo(nuint index, string? lang, out SettingsField field);

    // ── Helpers ─────────────────────────────────────────────────────────────

    /// <summary>A static or borrowed UTF-8 C string (not freed); null for a null pointer.</summary>
    internal static string? Utf8String(nint ptr) =>
        ptr == nint.Zero ? null : Marshal.PtrToStringUTF8(ptr);

    /// <summary>Read a NUL-terminated UTF-8 C string and free it with the Zig allocator.</summary>
    internal static string? TakeUtf8String(nint ptr)
    {
        if (ptr == nint.Zero)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStringUTF8(ptr);
        }
        finally
        {
            StringFree(ptr);
        }
    }
}
