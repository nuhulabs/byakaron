namespace Byakaron.Settings;

/// <summary>
/// The Avro phonetic key map shown on the Layout tab: the same table as the macOS
/// app (apps/macos/App/Views/LayoutView.swift). Change them together.
/// </summary>
public static class LayoutReference
{
    public sealed record Section(string Title, (string Bangla, string Keys)[] Entries);

    public static readonly Section[] Sections =
    {
        new("Consonants (ব্যঞ্জনবর্ণ)", new[]
        {
            ("ক", "k"),
            ("ট", "T"),
            ("প", "p"),
            ("স", "s"),
            ("খ", "kh"),
            ("ঠ", "Th"),
            ("ফ", "ph, f"),
            ("হ", "h"),
            ("গ", "g"),
            ("ড", "D"),
            ("ব", "b"),
            ("ড়", "R"),
            ("ঘ", "gh"),
            ("ঢ", "Dh"),
            ("ভ", "bh, v"),
            ("ঢ়", "Rh"),
            ("ঙ", "Ng"),
            ("ণ", "N"),
            ("ম", "m"),
            ("য়", "y, Y"),
            ("চ", "c"),
            ("ত", "t"),
            ("য", "z"),
            ("শ", "sh, S"),
            ("ছ", "ch"),
            ("থ", "th"),
            ("র", "r"),
            ("ষ", "Sh"),
            ("জ", "j"),
            ("দ", "d"),
            ("ল", "l"),
            ("ং", "ng"),
            ("ঝ", "jh"),
            ("ধ", "dh"),
            ("ঃ", ":"),
            ("ঁ", "^"),
            ("ঞ", "NG"),
            ("ন", "n"),
            ("ৎ", "t``"),
        }),
        new("Vowels (স্বরবর্ণ)", new[]
        {
            ("অ", "o"),
            ("ই / কি", "i"),
            ("উ / কু", "u"),
            ("আ / কা", "a"),
            ("ঈ / কী", "I"),
            ("ঊ / কূ", "U"),
            ("ঋ / কৃ", "rri"),
            ("এ / কে", "e"),
            ("ও / কো", "O"),
            ("ঐ / কৈ", "OI"),
            ("ঔ / কৌ", "OU"),
        }),
        new("Special", new[]
        {
            ("্ হসন্ত", ",,"),
            ("ব-ফলা", "w"),
            ("রেফ", "rr (v)"),
            ("় নুক্তা", ".."),
            ("য-ফলা", "y, Z"),
            ("। দাড়ি", "."),
            ("ZWJ", "`"),
            ("র-ফলা", "r"),
            ("৳ টাকা", "$"),
            ("ZWNJ", "~"),
        }),
        new("Numbers (সংখ্যা)", new[]
        {
            ("০", "0"),
            ("১", "1"),
            ("২", "2"),
            ("৩", "3"),
            ("৪", "4"),
            ("৫", "5"),
            ("৬", "6"),
            ("৭", "7"),
            ("৮", "8"),
            ("৯", "9"),
        }),
    };
}
