using System;
using System.Collections.Generic;
using Byakaron.Interop;

namespace Byakaron.Settings;

/// <summary>
/// The Avro phonetic key map shown on the Layout tab, read from the core
/// (src/Composer/Layout.zig) so every app shows the same table.
/// </summary>
public static class LayoutReference
{
    public sealed record Section(string Title, IReadOnlyList<(string Bangla, string Keys)> Entries);

    /// <summary>The layout's sections in order. Empty when byakaron_ffi.dll is unavailable.</summary>
    public static List<Section> Load()
    {
        var result = new List<Section>();
        try
        {
            var count = ByakaronNative.LayoutSectionCount();
            for (nuint s = 0; s < count; s++)
            {
                if (ByakaronNative.LayoutSectionInfo(s, out var title, out var entryCount) != 0) continue;
                var entries = new List<(string, string)>((int)entryCount);
                for (nuint e = 0; e < entryCount; e++)
                {
                    if (ByakaronNative.LayoutEntryAt(s, e, out var entry) != 0) continue;
                    entries.Add((
                        ByakaronNative.Utf8String(entry.Bangla) ?? string.Empty,
                        ByakaronNative.Utf8String(entry.Keys) ?? string.Empty));
                }
                result.Add(new Section(ByakaronNative.Utf8String(title) ?? string.Empty, entries));
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
}
