using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Byakaron.Interop;
using Byakaron.Settings;
using Byakaron.Spell;

namespace Byakaron.Typing;

/// <summary>What the composer wants drawn, copied out of its state.</summary>
public sealed record ComposerSnapshot(
    bool Composing,
    string Preedit,
    bool PanelVisible,
    bool Vertical,
    IReadOnlyList<string> Candidates,
    int Highlight,
    int Page,
    int PageCount)
{
    public static readonly ComposerSnapshot Idle = new(false, "", false, false, Array.Empty<string>(), 0, 0, 0);
}

/// <summary>A key's result: the text to insert (may be empty) and whether the key was used.</summary>
public readonly record struct ComposerResult(bool Handled, string Commit);

/// <summary>
/// The installed keyboard's engine (src/Composer.zig) for the editor's "Avro
/// typing": the same settings, learned choices and personal dictionary as the
/// keyboard (they share <see cref="ByakaronSettings.DataDirectory"/>), so the
/// keyboard's typing and suggestions can be tried in the app. The macOS app's
/// AppComposer does the same. UI thread only.
/// </summary>
public sealed class AvroComposer : IDisposable
{
    private nint _handle;
    // Kept alive as long as the composer may call it.
    private readonly ByakaronNative.UpdateFn _onUpdateNative;

    private AvroComposer(nint handle, ByakaronNative.UpdateFn onUpdate)
    {
        _handle = handle;
        _onUpdateNative = onUpdate;
    }

    /// <summary>
    /// Open the composer; null when byakaron_ffi.dll is unavailable. <paramref name="onUpdate"/>
    /// runs on a worker thread when spelling corrections arrive: hop to the UI
    /// thread, then <see cref="Refresh"/> and redraw.
    /// </summary>
    public static AvroComposer? Open(Action onUpdate)
    {
        try
        {
            ByakaronNative.UpdateFn callback = _ => onUpdate();
            var handle = ByakaronNative.ComposerCreate(
                ByakaronSettings.DataDirectory,
                SpellEngine.ResolveSpellDbPath(),
                Marshal.GetFunctionPointerForDelegate(callback),
                nint.Zero);
            return handle == nint.Zero ? null : new AvroComposer(handle, callback);
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

    public ComposerResult Key(int kind, uint ch, uint modifiers) =>
        Result(ByakaronNative.ComposerKey(_handle, kind, ch, modifiers));

    public ComposerResult Pick(int index) =>
        Result(ByakaronNative.ComposerPick(_handle, (nuint)index));

    /// <summary>Commit the word being typed; the text to insert.</summary>
    public string Flush() => Utf8(ByakaronNative.ComposerFlush(_handle));

    public void Reset() => ByakaronNative.ComposerReset(_handle);

    public void Refresh() => ByakaronNative.ComposerRefresh(_handle);

    public ComposerSnapshot State()
    {
        ByakaronNative.ComposerGetState(_handle, out var st);
        var candidates = new string[(int)st.CandidateCount];
        for (var i = 0; i < candidates.Length; i++)
        {
            candidates[i] = Utf8(Marshal.ReadIntPtr(st.Candidates, i * IntPtr.Size));
        }
        return new ComposerSnapshot(
            st.Composing != 0,
            Utf8(st.Preedit),
            st.PanelVisible != 0,
            st.Vertical != 0,
            candidates,
            (int)st.Highlight,
            (int)st.Page,
            (int)st.PageCount);
    }

    private static ComposerResult Result(ByakaronNative.KeyResult r) => new(r.Handled != 0, Utf8(r.Commit));

    private static string Utf8(nint p) => p == nint.Zero ? string.Empty : Marshal.PtrToStringUTF8(p) ?? string.Empty;

    public void Dispose()
    {
        if (_handle == nint.Zero) return;
        ByakaronNative.ComposerDestroy(_handle);
        _handle = nint.Zero;
        GC.KeepAlive(_onUpdateNative);
    }
}
