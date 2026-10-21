using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Byakaron.Spell;

/// <summary>A misspelled span in the document text.</summary>
public sealed class Misspelling : IEquatable<Misspelling>
{
    public Misspelling(string id, string word, int offset, int length)
    {
        Id = id;
        Word = word;
        Offset = offset;
        Length = length;
    }

    public string Id { get; }
    public string Word { get; }
    public int Offset { get; }
    public int Length { get; }

    public bool Equals(Misspelling? other) =>
        other is not null && Id == other.Id;

    public override bool Equals(object? obj) => Equals(obj as Misspelling);

    public override int GetHashCode() => Id.GetHashCode(StringComparison.Ordinal);
}

/// <summary>
/// Observable document model: text, loaded engine, and current misspellings.
/// Mirrors the macOS <c>SpellChecker</c> — apply/ignore/learn/fixAll live here;
/// the Zig FFI is only used via <see cref="SpellEngine"/>.
/// </summary>
public sealed partial class SpellChecker : IDisposable
{
    private SpellEngine? _engine;
    private string _text = string.Empty;
    private List<Misspelling> _misspellings = [];
    private CancellationTokenSource? _debounceCts;
    private int _checkVersion;
    private bool _disposed;

    public event EventHandler? Changed;

    public string Text
    {
        get => _text;
        set
        {
            if (_text == value)
            {
                return;
            }

            _text = value ?? string.Empty;
            ScheduleCheck();
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public IReadOnlyList<Misspelling> Misspellings => _misspellings;

    /// <summary>null while the dictionary is still loading or failed to open.</summary>
    public SpellEngine? Engine => _engine;

    public bool IsReady => _engine is not null;

    public async Task LoadAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var engine = await Task.Run(SpellEngine.LoadFromAppDirectory).ConfigureAwait(false);
        if (_disposed)
        {
            engine?.Dispose();
            return;
        }

        _engine?.Dispose();
        _engine = engine;
        RunCheckNow();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void ScheduleCheck()
    {
        _debounceCts?.Cancel();
        _debounceCts?.Dispose();
        _debounceCts = new CancellationTokenSource();
        var token = _debounceCts.Token;
        var version = Interlocked.Increment(ref _checkVersion);
        var snapshot = _text;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(250, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            if (token.IsCancellationRequested || version != Volatile.Read(ref _checkVersion))
            {
                return;
            }

            var engine = _engine;
            if (engine is null)
            {
                return;
            }

            var found = FindMisspellings(snapshot, engine);
            if (version != Volatile.Read(ref _checkVersion) || !string.Equals(_text, snapshot, StringComparison.Ordinal))
            {
                return;
            }

            _misspellings = found;
            Changed?.Invoke(this, EventArgs.Empty);
        }, token);
    }

    public void RunCheckNow()
    {
        _debounceCts?.Cancel();
        Interlocked.Increment(ref _checkVersion);

        var engine = _engine;
        if (engine is null)
        {
            _misspellings = [];
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }

        _misspellings = FindMisspellings(_text, engine);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public bool IsCorrect(string word) => _engine?.IsCorrect(word) ?? true;

    public IReadOnlyList<string> Suggestions(Misspelling misspelling)
    {
        if (_engine is null)
        {
            return Array.Empty<string>();
        }

        var (prev2, prev1, next) = ContextAround(misspelling.Offset, misspelling.Length);
        return _engine.Suggestions(misspelling.Word, prev2, prev1, next);
    }

    public IReadOnlyList<string> Suggestions(string word) =>
        _engine?.Suggestions(word) ?? Array.Empty<string>();

    public void Learn(string word)
    {
        _engine?.Learn(word);
        RunCheckNow();
    }

    public void Apply(string correction, Misspelling misspelling)
    {
        if (misspelling.Offset < 0 || misspelling.Offset + misspelling.Length > _text.Length)
        {
            return;
        }

        _text = string.Concat(
            _text.AsSpan(0, misspelling.Offset),
            correction,
            _text.AsSpan(misspelling.Offset + misspelling.Length));
        RunCheckNow();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Ignore(Misspelling misspelling)
    {
        _engine?.Learn(misspelling.Word);
        RunCheckNow();
    }

    /// <summary>
    /// Replace every misspelling that has a suggestion with its top candidate.
    /// Walks end→start so earlier offsets stay valid. Returns how many were fixed.
    /// </summary>
    public int FixAll()
    {
        if (_engine is null || _misspellings.Count == 0)
        {
            return 0;
        }

        var fixes = new List<(int Offset, int Length, string Replacement)>();
        foreach (var miss in _misspellings)
        {
            var top = Suggestions(miss).FirstOrDefault();
            if (string.IsNullOrEmpty(top))
            {
                continue;
            }

            fixes.Add((miss.Offset, miss.Length, top));
        }

        fixes.Sort((a, b) => b.Offset.CompareTo(a.Offset));

        var text = _text;
        var corrected = 0;
        foreach (var (offset, length, replacement) in fixes)
        {
            if (offset < 0 || offset + length > text.Length)
            {
                continue;
            }

            text = string.Concat(
                text.AsSpan(0, offset),
                replacement,
                text.AsSpan(offset + length));
            corrected++;
        }

        if (corrected > 0)
        {
            _text = text;
            RunCheckNow();
            Changed?.Invoke(this, EventArgs.Empty);
        }

        return corrected;
    }

    public (string Prev2, string Prev1, string Next) ContextAround(int offset, int length)
    {
        var words = new List<(string Word, int Offset, int Length)>();
        foreach (Match match in WordRegex().Matches(_text))
        {
            words.Add((match.Value, match.Index, match.Length));
        }

        var idx = words.FindIndex(w => w.Offset == offset && w.Length == length);
        if (idx < 0)
        {
            idx = words.FindIndex(w =>
                offset < w.Offset + w.Length && offset + length > w.Offset);
        }

        if (idx < 0)
        {
            return (string.Empty, string.Empty, string.Empty);
        }

        var prev2 = idx >= 2 ? words[idx - 2].Word : string.Empty;
        var prev1 = idx >= 1 ? words[idx - 1].Word : string.Empty;
        var next = idx + 1 < words.Count ? words[idx + 1].Word : string.Empty;
        return (prev2, prev1, next);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _debounceCts?.Cancel();
        _debounceCts?.Dispose();
        _engine?.Dispose();
        _engine = null;
    }

    private static List<Misspelling> FindMisspellings(string text, SpellEngine engine)
    {
        var result = new List<Misspelling>();
        foreach (Match match in WordRegex().Matches(text))
        {
            if (engine.IsCorrect(match.Value))
            {
                continue;
            }

            result.Add(new Misspelling(
                id: $"{match.Index}:{match.Value}",
                word: match.Value,
                offset: match.Index,
                length: match.Length));
        }

        return result;
    }

    [GeneratedRegex(@"[\u0980-\u09FF]+(?:[\u200C\u200D\u09BC]?[\u0980-\u09FF]+)*", RegexOptions.Compiled)]
    private static partial Regex WordRegex();
}
