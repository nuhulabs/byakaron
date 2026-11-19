import SwiftUI

// MARK: - Avro Layout Reference

private struct LayoutEntry: Identifiable {
    let id: Int
    let bengali: String
    let key: String
}

private struct LayoutSection: Identifiable {
    let id: Int
    let title: String
    let entries: [LayoutEntry]
}

/// The Avro Phonetic key map, shown as a reference inside the Settings window.
/// The table is the one every Byakaron app shows (src/Composer/Layout.zig).
struct LayoutTab: View {
    private let sections: [LayoutSection] = LayoutData.sections

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 120), spacing: 24)]
    }

    var body: some View {
        Form {
            Section {
                Text(tr(BYK_STR_LAYOUT_HINT))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                        ForEach(section.entries) { entry in
                            cell(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func cell(_ entry: LayoutEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.bengali)
                .frame(minWidth: 32, alignment: .leading)
            Text(entry.key)
                .font(.callout.monospaced())
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Avro Layout Data

/// src/Composer/Layout.zig through byakaron.h's byakaron_layout_*.
private enum LayoutData {
    static let sections: [LayoutSection] = (0..<byakaron_layout_section_count()).compactMap { s in
        var title: UnsafePointer<CChar>?
        var count = 0
        guard byakaron_layout_section_info(s, &title, &count) == 0, let title else { return nil }
        let entries: [LayoutEntry] = (0..<count).compactMap { i in
            var e = ByakaronLayoutEntry()
            guard byakaron_layout_entry(s, i, &e) == 0 else { return nil }
            return LayoutEntry(id: i, bengali: String(cString: e.bangla), key: String(cString: e.keys))
        }
        return LayoutSection(id: s, title: String(cString: title), entries: entries)
    }
}

#if DEBUG
#Preview("Layout") {
    LayoutTab()
        .frame(width: 560, height: 640)
}
#endif
