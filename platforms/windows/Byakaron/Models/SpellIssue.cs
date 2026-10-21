using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Byakaron.Models;

/// <summary>UI row for one misspelling in the issues sidebar.</summary>
public sealed class SpellIssue : INotifyPropertyChanged
{
    private IReadOnlyList<string> _suggestions = [];

    public required string Id { get; init; }
    public required string Word { get; set; }
    public int Offset { get; set; }
    public int Length { get; set; }

    public required IReadOnlyList<string> Suggestions
    {
        get => _suggestions;
        set
        {
            if (ReferenceEquals(_suggestions, value))
            {
                return;
            }

            _suggestions = value ?? [];
            OnPropertyChanged();
            OnPropertyChanged(nameof(SuggestionCount));
        }
    }

    public int SuggestionCount => _suggestions.Count;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
