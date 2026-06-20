import SwiftUI

// MARK: - Avro Layout Reference

private struct LayoutEntry: Identifiable {
    let id = UUID()
    let bengali: String
    let key: String
}

private struct LayoutSection: Identifiable {
    let id = UUID()
    let title: String
    let columns: Int
    let entries: [LayoutEntry]
}

/// The full Avro phonetic key map, shown as a reference inside the Guide window.
struct LayoutTab: View {
    private let sections: [LayoutSection] = LayoutData.sections

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: 8)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)

                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                            ForEach(section.entries) { entry in
                                cell(entry)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cell(_ entry: LayoutEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.bengali)
                .font(.system(size: 16, weight: .medium))
                .frame(minWidth: 32, alignment: .center)
            Text(entry.key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Avro Layout Data

private enum LayoutData {
    static let sections: [LayoutSection] = [
        LayoutSection(
            title: "Consonants ব্যঞ্জনবর্ণ", columns: 4,
            entries: pairs([
                ("ক", "k"), ("ট", "T"), ("প", "p"), ("স", "s"),
                ("খ", "kh"), ("ঠ", "Th"), ("ফ", "ph, f"), ("হ", "h"),
                ("গ", "g"), ("ড", "D"), ("ব", "b"), ("ড়", "R"),
                ("ঘ", "gh"), ("ঢ", "Dh"), ("ভ", "bh, v"), ("ঢ়", "Rh"),
                ("ঙ", "Ng"), ("ণ", "N"), ("ম", "m"), ("য়", "y, Y"),
                ("চ", "c"), ("ত", "t"), ("য", "z"), ("শ", "sh, S"),
                ("ছ", "ch"), ("থ", "th"), ("র", "r"), ("ষ", "Sh"),
                ("জ", "j"), ("দ", "d"), ("ল", "l"), ("ং", "ng"),
                ("ঝ", "jh"), ("ধ", "dh"), ("ঃ", ":"), ("ঁ", "^"),
                ("ঞ", "NG"), ("ন", "n"), ("ৎ", "t``"),
            ])
        ),
        LayoutSection(
            title: "Vowels স্বরবর্ণ", columns: 3,
            entries: pairs([
                ("অ", "o"), ("ই / কি", "i"), ("উ / কু", "u"),
                ("আ / কা", "a"), ("ঈ / কী", "I"), ("ঊ / কূ", "U"),
                ("ঋ / কৃ", "rri"), ("এ / কে", "e"), ("ও / কো", "O"),
                ("ঐ / কৈ", "OI"), ("ঔ / কৌ", "OU"),
            ])
        ),
        LayoutSection(
            title: "Special", columns: 3,
            entries: pairs([
                ("্ হসন্ত", ",,"), ("ব-ফলা", "w"), ("রেফ", "rr (v)"),
                ("় নুক্তা", ".."), ("য-ফলা", "y, Z"), ("। দাড়ি", "."),
                ("ZWJ", "`"), ("র-ফলা", "r"), ("৳ টাকা", "$"),
                ("ZWNJ", "~"),
            ])
        ),
        LayoutSection(
            title: "Numbers সংখ্যা", columns: 5,
            entries: pairs([
                ("০", "0"), ("১", "1"), ("২", "2"), ("৩", "3"), ("৪", "4"),
                ("৫", "5"), ("৬", "6"), ("৭", "7"), ("৮", "8"), ("৯", "9"),
            ])
        ),
    ]

    private static func pairs(_ raw: [(String, String)]) -> [LayoutEntry] {
        raw.map { LayoutEntry(bengali: $0.0, key: $0.1) }
    }
}

#if DEBUG
#Preview("Avro Layout") {
    LayoutTab()
        .frame(width: 560, height: 640)
}
#endif
