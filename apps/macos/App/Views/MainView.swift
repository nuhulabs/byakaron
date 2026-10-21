import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Main screen, modeled on the clean source-list layout of native macOS 26 apps:
/// a plain sidebar listing the spelling issues, a detail pane holding the editor
/// and the corrections for the selected issue, and a native toolbar. The window
/// uses the system material — no tinted gradients or wall-to-wall glass — so it
/// reads as a stock macOS app.
struct MainView: View {
    @EnvironmentObject private var checker: SpellChecker

    /// The issue currently selected in the sidebar.
    @State private var selection: Misspelling.ID?

    /// After apply/ignore, wait for the refreshed issue list then select the
    /// misspelling at or after this UTF-16 offset (adjusted for the edit).
    @State private var pendingJumpUTF16: Int?

    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    /// Guard so we only nudge the user toward setup once per launch.
    @State private var didCheckSetup = false
    #endif

    var body: some View {
        Group {
            if checker.engine == nil {
                loadingView
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                } detail: {
                    detail
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        #if os(macOS)
        .onAppear { promptSetupIfNeeded() }
        #endif
        .onChange(of: checker.misspellings) { _, new in
            resolvePendingJump(in: new)
        }
    }

    #if os(macOS)
    /// On first appearance, if the Byakaron input source hasn't been added yet, open
    /// Settings to the Setup tab so the user can finish enabling the keyboard.
    private func promptSetupIfNeeded() {
        guard !didCheckSetup else { return }
        didCheckSetup = true
        guard !KeyboardInstaller.isInputSourceAdded() else { return }

        // Deep-link Settings to the Setup tab, then open it (slightly delayed so the
        // main window has settled first).
        ByakaronSettings.defaults.set(SettingsTab.setup.rawValue, forKey: SettingsTab.selectionKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            openSettings()
        }
    }
    #endif

    // MARK: - Derived counts

    /// Word count over Unicode word boundaries (skips punctuation/whitespace).
    private var wordCount: Int {
        var count = 0
        checker.text.enumerateSubstrings(
            in: checker.text.startIndex..<checker.text.endIndex, options: .byWords
        ) { _, _, _, _ in count += 1 }
        return count
    }

    private var characterCount: Int {
        checker.text.count
    }

    /// Issues that have at least one suggestion — i.e. the ones "Fix all" can act on.
    private var fixableCount: Int {
        checker.misspellings.reduce(into: 0) { total, miss in
            if !checker.suggestions(for: miss).isEmpty { total += 1 }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section(checker.misspellings.isEmpty ? "Issues" : "Issues (\(checker.misspellings.count))") {
                if checker.misspellings.isEmpty {
                    Label(
                        checker.text.isEmpty ? "Nothing to check yet" : "No misspellings",
                        systemImage: checker.text.isEmpty ? "pencil.and.scribble" : "checkmark.seal"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(checker.misspellings) { miss in
                        IssueListRow(word: miss.word, count: checker.suggestions(for: miss).count)
                            .tag(miss.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Issues")
    }

    // MARK: - Detail

    private var detail: some View {
        editorPane
            // Single source of truth for the window's title — `navigationTitle`
            // feeds the real macOS title bar, so we no longer paint a second
            // "Byakaron" into a toolbar item (which caused the doubled title).
            .navigationTitle("Byakaron")
            .navigationSubtitle(checker.text.isEmpty ? "বাংলা বানান পরীক্ষক" : statusSummary)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    EditorToolbarActions(
                        isEmpty: checker.text.isEmpty,
                        canFix: fixableCount > 0,
                        onFixAll: {
                            if checker.fixAll() > 0 {
                                pendingJumpUTF16 = 0
                            }
                        },
                        onCopy: copyText,
                        onClear: {
                            checker.text = ""
                            selection = nil
                        }
                    )
                }
            }
    }

    /// The editor, plus an inline correction bar for the selected issue and a
    /// live status bar along the bottom.
    private var editorPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                BanglaSpellTextView(
                    text: $checker.text,
                    selectedRange: selectedMisspelling?.range,
                    isCorrect: { checker.isCorrect($0) },
                    suggestions: { word, range in
                        checker.suggestions(for: word, at: range)
                    },
                    onLearn: { word in
                        if let miss = checker.misspellings.first(where: { $0.word == word }) {
                            queueAdvance(after: miss, utf16Delta: 0)
                        }
                        checker.learn(word)
                    },
                    onApplied: { nsRange, replacementUTF16 in
                        handleEditorApply(nsRange: nsRange, replacementUTF16: replacementUTF16)
                        checker.runCheckNow()
                    }
                )

                if checker.text.isEmpty {
                    Text("এখানে বাংলা লিখুন বা পেস্ট করুন…")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            if let miss = selectedMisspelling {
                Divider()
                CorrectionBar(
                    word: miss.word,
                    suggestions: checker.suggestions(for: miss),
                    onApply: { correction in
                        let delta = (correction as NSString).length - (miss.word as NSString).length
                        queueAdvance(after: miss, utf16Delta: delta)
                        checker.apply(correction, to: miss)
                    },
                    onIgnore: {
                        queueAdvance(after: miss, utf16Delta: 0)
                        checker.ignore(miss)
                    }
                )
            }

            Divider()
            statusBar
        }
        .background(.background)
    }

    /// Slim footer with live document stats — the kind of at-a-glance counter
    /// users expect from a writing tool.
    private var statusBar: some View {
        HStack(spacing: 14) {
            StatusItem(systemImage: "text.word.spacing", text: "\(wordCount) words")
            StatusItem(systemImage: "character", text: "\(characterCount) characters")
            Spacer(minLength: 0)
            if checker.misspellings.isEmpty {
                StatusItem(systemImage: "checkmark.seal.fill", text: "No issues", tint: .green)
            } else {
                StatusItem(
                    systemImage: "exclamationmark.triangle.fill",
                    text: "\(checker.misspellings.count) issue\(checker.misspellings.count == 1 ? "" : "s")",
                    tint: .orange
                )
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Subtitle text summarizing the document state, shown in the title bar.
    private var statusSummary: String {
        let issues = checker.misspellings.count
        if issues == 0 {
            return "\(wordCount) words · all clear"
        }
        return "\(wordCount) words · \(issues) issue\(issues == 1 ? "" : "s")"
    }

    private func copyText() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(checker.text, forType: .string)
        #endif
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading dictionary…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Selection helpers

    private var selectedMisspelling: Misspelling? {
        checker.misspellings.first { $0.id == selection }
    }

    /// Remember where to land after the next misspellings refresh.
    private func queueAdvance(after miss: Misspelling, utf16Delta: Int) {
        let misses = checker.misspellings
        guard let i = misses.firstIndex(where: { $0.id == miss.id }) else {
            pendingJumpUTF16 = 0
            return
        }
        if i + 1 < misses.count {
            let nextOff = checker.utf16Offset(of: misses[i + 1].range.lowerBound)
            pendingJumpUTF16 = nextOff + utf16Delta
        } else {
            // Last issue — clear selection once the list refreshes.
            pendingJumpUTF16 = -1
            selection = nil
        }
    }

    private func handleEditorApply(nsRange: NSRange, replacementUTF16: Int) {
        let delta = replacementUTF16 - nsRange.length
        if let miss = checker.misspellings.first(where: {
            NSRange($0.range, in: checker.text) == nsRange
        }) {
            queueAdvance(after: miss, utf16Delta: delta)
        } else {
            pendingJumpUTF16 = nsRange.location + replacementUTF16
        }
    }

    private func resolvePendingJump(in new: [Misspelling]) {
        guard let jump = pendingJumpUTF16 else {
            // Keep selection valid across refreshes; auto-pick first if none.
            if let selection, new.contains(where: { $0.id == selection }) { return }
            selection = new.first?.id
            return
        }
        pendingJumpUTF16 = nil
        if jump < 0 || new.isEmpty {
            selection = nil
            return
        }
        selection = new.first { miss in
            checker.utf16Offset(of: miss.range.lowerBound) >= jump
        }?.id ?? new.first?.id
    }
}

/// A sidebar row: the misspelled word and how many corrections are available.
private struct IssueListRow: View {
    let word: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.cursor.ibeam")
                .foregroundStyle(.orange)
            // Cap the word so a long token can't push the count off the row or
            // force horizontal overflow; truncate in the middle to keep the
            // start and end visible (most informative for Bangla words).
            Text(word)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(word)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .layoutPriority(1)
                    .help("\(count) suggestion\(count == 1 ? "" : "s")")
            }
        }
    }
}

/// The detail toolbar's action buttons, factored into their own view so SwiftUI
/// only re-renders them when the small set of flags they depend on changes — this
/// keeps the toolbar from flickering on unrelated editor updates, and gives the
/// type-checker a small, self-contained body to resolve.
private struct EditorToolbarActions: View {
    let isEmpty: Bool
    let canFix: Bool
    let onFixAll: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        Button(action: onFixAll) {
            Label("Fix All", systemImage: "wand.and.stars")
        }
        .help("Replace every issue with its top suggestion")
        .disabled(!canFix)

        Button(action: onCopy) {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .help("Copy the full text to the clipboard")
        .disabled(isEmpty)

        Button(role: .destructive, action: onClear) {
            Label("Clear", systemImage: "trash")
        }
        .help("Clear the editor")
        .disabled(isEmpty)
    }
}

/// One labelled stat in the editor's bottom status bar.
private struct StatusItem: View {
    let systemImage: String
    let text: String
    var tint: Color? = nil

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint ?? .secondary)
    }
}

/// Inline bar under the editor showing the selected word and tappable corrections.
private struct CorrectionBar: View {
    let word: String
    let suggestions: [String]
    let onApply: (String) -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(word)
                    .font(.system(size: 16, weight: .semibold))
                Text("Replace with")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if suggestions.isEmpty {
                Text("No suggestions")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { onApply(suggestion) }
                                .font(.system(size: 15))
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button("Ignore", action: onIgnore)
                .help("Accept this word for now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Previews

#if DEBUG
private let sampleMisspellings = [
    Misspelling(word: "আমর", range: "".startIndex..<"".startIndex),
    Misspelling(word: "ভালো", range: "".startIndex..<"".startIndex),
    Misspelling(word: "বাংলদেশ", range: "".startIndex..<"".startIndex),
]

#Preview("Empty") {
    MainView()
        .environmentObject(SpellChecker.preview())
}

#Preview("With issues") {
    MainView()
        .environmentObject(SpellChecker.preview(
            text: "আমর সোনার বাংলদেশ, আমি তোমায় ভালোবাসি।",
            misspellings: sampleMisspellings
        ))
}

#Preview("Issue row") {
    List {
        IssueListRow(word: "বাংলদেশ", count: 4)
        IssueListRow(word: "আমর", count: 2)
        IssueListRow(word: "নিভৃত", count: 0)
        // Overflow case: a very long token must truncate (middle) and still
        // leave room for the count capsule — not push it off the row.
        IssueListRow(word: "সদফঞ্ডদফ্কসদফঞ্ডদফ্কসদফঞ্ডদফ্ক", count: 8)
    }
    .listStyle(.sidebar)
    .frame(width: 260, height: 200)
}

#Preview("Status bar") {
    VStack(spacing: 0) {
        // Clean document.
        StatusBarPreview(words: 128, chars: 642, issues: 0)
        Divider()
        // Document with issues.
        StatusBarPreview(words: 9, chars: 47, issues: 3)
    }
    .frame(width: 560)
}

#Preview("Toolbar actions") {
    HStack {
        // Empty editor: only nothing is actionable.
        EditorToolbarActions(
            isEmpty: true, canFix: false,
            onFixAll: {}, onCopy: {}, onClear: {}
        )
        Divider().frame(height: 24)
        // Text with fixable issues: everything enabled.
        EditorToolbarActions(
            isEmpty: false, canFix: true,
            onFixAll: {}, onCopy: {}, onClear: {}
        )
    }
    .labelStyle(.iconOnly)
    .padding()
}

/// Stand-in that mirrors MainView's `statusBar` layout for isolated previewing
/// (the real one reads the live `SpellChecker`).
private struct StatusBarPreview: View {
    let words: Int
    let chars: Int
    let issues: Int

    var body: some View {
        HStack(spacing: 14) {
            StatusItem(systemImage: "text.word.spacing", text: "\(words) words")
            StatusItem(systemImage: "character", text: "\(chars) characters")
            Spacer(minLength: 0)
            if issues == 0 {
                StatusItem(systemImage: "checkmark.seal.fill", text: "No issues", tint: .green)
            } else {
                StatusItem(
                    systemImage: "exclamationmark.triangle.fill",
                    text: "\(issues) issue\(issues == 1 ? "" : "s")",
                    tint: .orange
                )
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

#Preview("Correction bar") {
    VStack(spacing: 0) {
        CorrectionBar(
            word: "বাংলদেশ",
            suggestions: ["বাংলাদেশ", "বাংলাদেশে", "বাংলাদেশের"],
            onApply: { _ in },
            onIgnore: {}
        )
        CorrectionBar(
            word: "xyz",
            suggestions: [],
            onApply: { _ in },
            onIgnore: {}
        )
    }
    .frame(width: 560)
}
#endif
