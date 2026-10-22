using System;
using System.Runtime.InteropServices;

namespace Byakaron.Interop;

/// <summary>
/// Raw C ABI for libbyakaron (see <c>src/ffi/byakaron.h</c>).
/// Returned strings are heap UTF-8 owned by the caller — free with <see cref="StringFree"/>.
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

    /// <summary>Settings JSON; free with <see cref="StringFree"/> (use <see cref="TakeUtf8String"/>).</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_get")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint SettingsGet(nint composer);

    /// <summary>0, or -1 on invalid JSON. Missing fields take their defaults.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_settings_set", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int SettingsSet(nint composer, string json);

    /// <summary>JSON array of personal words; free with <see cref="StringFree"/>.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_get")]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial nint UserDictGet(nint composer);

    /// <summary>1 added, 0 already there, -1 not a valid word.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_add", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UserDictAdd(nint composer, string word);

    /// <summary>1 removed, 0 not there, -1 on error.</summary>
    [LibraryImport(LibraryName, EntryPoint = "byakaron_userdict_remove", StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    internal static partial int UserDictRemove(nint composer, string word);

    // ── Helpers ─────────────────────────────────────────────────────────────

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
