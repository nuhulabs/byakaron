using System.Collections.Generic;

namespace Byakaron.Models;

/// <summary>UI row for one misspelling in the issues sidebar.</summary>
public sealed class SpellIssue
{
    public required string Id { get; init; }
    public required string Word { get; set; }
    public required IReadOnlyList<string> Suggestions { get; set; }
    public int Offset { get; set; }
    public int Length { get; set; }
    public int SuggestionCount => Suggestions.Count;
}
