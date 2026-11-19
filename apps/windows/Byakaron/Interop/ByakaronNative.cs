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

    // ── Composer (typing: the keyboard's engine, for the editor's Avro typing) ─

    internal const int KeyChar = 0, KeySpace = 1, KeyEnter = 2, KeyTab = 3, KeyBackspace = 4, KeyEscape = 5,
        KeyUp = 6, KeyDown = 7, KeyLeft = 8, KeyRight = 9, KeyPageUp = 10, KeyPageDown = 11, KeyOther = 12;
    internal const uint ModShift = 1, ModCtrl = 2, ModAlt = 4, ModMeta = 8;

    /// <summary>ByakaronKeyResult: <c>Commit</c> is UTF-8, not owned, valid until the next composer call.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyResult
    {
        public int Handled;
        public nint Commit;
    }

    /// <summary>ByakaronComposerState: pointers valid until the next composer call.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct ComposerState
    {
        public int Composing;
        public nint Preedit;
        public int PanelVisible;
        public int Vertical;
        public nint Candidates;
        public nuint CandidateCount;
        public nuint Highlight;
        public nuint Page;
        public nuint PageCount;
        public nint Latin;
        public nint Literal;
    }

    /// <summary>Called on the composer's worker thread when spelling corrections arrive.</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void UpdateFn(nint userdata);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_key")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial KeyResult ComposerKey(nint composer, int kind, uint ch, uint modifiers);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_pick")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial KeyResult ComposerPick(nint composer, nuint index);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_flush")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint ComposerFlush(nint composer);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_reset")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void ComposerReset(nint composer);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_refresh")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void ComposerRefresh(nint composer);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_composer_state")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void ComposerGetState(nint composer, out ComposerState state);

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

    // ── Avro layout (src/Composer/Layout.zig; static strings: do not free) ─

    /// <summary>ByakaronLayoutEntry: "ক" and "k" (or several keys: "ph, f").</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct LayoutEntry
    {
        public nint Bangla;
        public nint Keys;
    }

    [LibraryImport(LibraryName, EntryPoint = "byakaron_layout_section_count")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nuint LayoutSectionCount();

    /// <summary>The section's title and entry count. 0, or -1 past the end.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_layout_section_info")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int LayoutSectionInfo(nuint index, out nint title, out nuint entryCount);

    /// <summary>0, or -1 past the end.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_layout_entry")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int LayoutEntryAt(nuint section, nuint index, out LayoutEntry entry);

    // ── Updates (src/Update.zig) ────────────────────────────────────────────

    /// <summary>byakaron.h's ByakaronRelease; free with <see cref="UpdateFree"/>.</summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Release
    {
        public nint Tag;
        public nint Version;
        public nint Url;
        public nint Sha256;
        public nint Page;
        public ulong Size;
        public int Channel;
    }

    /// <summary>This build's version ("27.0.0-beta.3"); static.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_version")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint Version();

    /// <summary>This build's channel, or -1 for a local build.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_update_build_channel")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UpdateBuildChannel();

    /// <summary>The release feed URL; static.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_update_feed_url")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint UpdateFeedUrl();

    /// <summary>1 with <paramref name="release"/> filled, 0 for nothing newer, -1 for a bad feed.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_update_pick", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UpdatePick(string feedJson, string? currentVersion, int channel, string asset, ref Release release);

    [LibraryImport(LibraryName, EntryPoint = "byakaron_update_free")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial void UpdateFree(ref Release release);

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
