using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Byakaron.Interop;

namespace Byakaron.Spell;

/// <summary>
/// Bengali spell-checking engine backed by the Zig SymSpell lexicon (<c>spell.db</c>).
/// Mirrors the macOS <c>SpellEngine</c>: FFI for correctness/suggestions; session
/// Ignore/Learn words stay in managed code.
/// </summary>
public sealed class SpellEngine : IDisposable
{
    private nint _handle;
    private readonly HashSet<string> _learned = new(StringComparer.Ordinal);
    private readonly object _gate = new();
    private bool _disposed;

    public SpellEngine(string dbPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dbPath);
        if (!File.Exists(dbPath))
        {
            throw new FileNotFoundException("spell.db not found", dbPath);
        }

        _handle = ByakaronNative.SpellCreate(dbPath);
        if (_handle == nint.Zero)
        {
            throw new InvalidOperationException($"byakaron_spell_create failed for '{dbPath}'");
        }
    }

    /// <summary>
    /// Open bundled <c>native/spell.db</c> next to the app (staged by build_zig.ps1).
    /// Returns null if the file is missing or the engine fails to open.
    /// </summary>
    public static SpellEngine? LoadFromAppDirectory()
    {
        var path = ResolveSpellDbPath();
        if (path is null)
        {
            return null;
        }

        try
        {
            return new SpellEngine(path);
        }
        catch
        {
            return null;
        }
    }

    public static string? ResolveSpellDbPath()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, "native", "spell.db"),
            Path.Combine(baseDir, "spell.db"),
        };

        foreach (var path in candidates)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        return null;
    }

    /// <summary>
    /// True when the word is in the dictionary or has been learned this session.
    /// Tokens with no Bengali letters are treated as correct.
    /// </summary>
    public bool IsCorrect(string word)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (string.IsNullOrEmpty(word))
        {
            return true;
        }

        if (!ContainsBengaliLetter(word))
        {
            return true;
        }

        lock (_gate)
        {
            if (_learned.Contains(word))
            {
                return true;
            }

            return ByakaronNative.SpellIsCorrect(_handle, word) == 1;
        }
    }

    public void Learn(string word)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (string.IsNullOrEmpty(word))
        {
            return;
        }

        lock (_gate)
        {
            _learned.Add(word);
        }
    }

    public bool IsLearned(string word)
    {
        lock (_gate)
        {
            return _learned.Contains(word);
        }
    }

    /// <summary>
    /// Ranked correction candidates. Optional neighbors boost ranking via
    /// bigram/trigram frequencies in spell.db (same as macOS suggest_ctx).
    /// </summary>
    public IReadOnlyList<string> Suggestions(
        string word,
        string prev2 = "",
        string prev1 = "",
        string next = "",
        int limit = 8)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (string.IsNullOrEmpty(word))
        {
            return Array.Empty<string>();
        }

        string? json;
        lock (_gate)
        {
            var ptr = ByakaronNative.SpellSuggestCtx(
                _handle,
                word,
                prev2 ?? string.Empty,
                prev1 ?? string.Empty,
                next ?? string.Empty,
                limit);
            json = ByakaronNative.TakeUtf8String(ptr);
        }

        if (string.IsNullOrEmpty(json))
        {
            return Array.Empty<string>();
        }

        try
        {
            var arr = JsonSerializer.Deserialize<string[]>(json);
            if (arr is null || arr.Length == 0)
            {
                return Array.Empty<string>();
            }

            var filtered = new List<string>(arr.Length);
            foreach (var s in arr)
            {
                if (!string.IsNullOrEmpty(s) && !ContainsEmoji(s))
                {
                    filtered.Add(s);
                }
            }

            return filtered;
        }
        catch (JsonException)
        {
            return Array.Empty<string>();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        lock (_gate)
        {
            if (_handle != nint.Zero)
            {
                ByakaronNative.SpellDestroy(_handle);
                _handle = nint.Zero;
            }
        }

        GC.SuppressFinalize(this);
    }

    ~SpellEngine()
    {
        if (_handle != nint.Zero)
        {
            ByakaronNative.SpellDestroy(_handle);
            _handle = nint.Zero;
        }
    }

    private static bool ContainsBengaliLetter(string word)
    {
        foreach (var c in word)
        {
            if (c is >= '\u0980' and <= '\u09FF')
            {
                return true;
            }
        }

        return false;
    }

    private static bool ContainsEmoji(string value)
    {
        // Skip obvious emoji / pictographic presentation forms (mirrors macOS filter).
        foreach (var rune in value.EnumerateRunes())
        {
            var v = (uint)rune.Value;
            if (v is >= 0x1F300 and <= 0x1FAFF)
            {
                return true;
            }

            if (v is >= 0x2600 and <= 0x27BF)
            {
                return true;
            }
        }

        return false;
    }
}
