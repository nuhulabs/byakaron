import AppKit
import SwiftUI
import Combine

// MARK: - CandidatePanel (AppKit host)

/// Hosts the SwiftUI candidate bar inside a borderless floating panel and
/// positions it relative to the text cursor. The public API is unchanged from
/// the original AppKit implementation so `InputController` needs no edits.
class CandidatePanel {
    private var panel: NSPanel?
    private let model = CandidateModel()

    /// Called when the user clicks a candidate. Parameter is the GLOBAL candidate index.
    var onCandidateSelected: ((Int) -> Void)?
    /// Called when the user clicks a page chevron. Parameter is +1 (next) or -1 (prev).
    var onPageStep: ((Int) -> Void)?

    func show(candidates: [String], auxiliaryText: String, selectedIndex: Int, cursorRect: NSRect) {
        if panel == nil { createPanel() }
        guard let panel = panel else { return }

        // Re-read orientation each show so a Settings change applies on the next
        // keystroke without restarting the IME.
        model.orientation = ByakaronSettings.candidateOrientation
        model.candidates = candidates
        model.auxiliaryText = auxiliaryText
        model.selectedIndex = candidates.isEmpty ? 0 : min(selectedIndex, candidates.count - 1)
        model.recomputePages()
        model.syncPageToSelection()

        // Let SwiftUI compute the fitting size, then size the panel to match.
        guard let hosting = panel.contentView as? NSHostingView<CandidateBar> else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)

        position(panel, size: size, cursorRect: cursorRect)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func selectCandidate(at index: Int) {
        guard !model.candidates.isEmpty else { return }
        model.selectedIndex = min(index, model.candidates.count - 1)
        model.syncPageToSelection()
        resize()
    }

    /// Move the visible page by `delta` (-1 prev, +1 next), clamping to bounds.
    /// Returns the new global selected index, or nil if the page didn't change.
    func stepPage(by delta: Int) -> Int? {
        guard model.stepPage(by: delta) else { return nil }
        resize()
        return model.selectedIndex
    }

    var pageCount: Int { model.pageCount }
    var currentPage: Int { model.currentPage }
    /// Global indices of the candidates visible on the current page.
    var visiblePageRange: Range<Int> { model.range(for: model.currentPage) }

    /// Re-fit the panel after the visible page changes (page widths differ).
    private func resize() {
        guard let panel = panel,
              let hosting = panel.contentView as? NSHostingView<CandidateBar> else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = panel.frame.origin
        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Positioning

    private func position(_ panel: NSPanel, size: NSSize, cursorRect: NSRect) {
        // Below the cursor line (macOS coords: y increases upward).
        var origin = cursorRect.origin
        origin.y -= size.height + 4

        let cursorPoint = NSPoint(x: cursorRect.midX, y: cursorRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(cursorPoint) } ?? NSScreen.main

        if let sf = screen?.visibleFrame {
            origin.x = max(sf.minX, min(origin.x, sf.maxX - size.width))
            if origin.y < sf.minY { origin.y = cursorRect.maxY + 4 }       // flip above
            if origin.y + size.height > sf.maxY { origin.y = sf.maxY - size.height }
            if origin.y < sf.minY { origin.y = sf.minY }
        }

        panel.setFrameOrigin(origin)
    }

    // MARK: - Panel setup

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bar = CandidateBar(
            model: model,
            onSelect: { [weak self] index in self?.onCandidateSelected?(index) },
            onPageStep: { [weak self] delta in self?.onPageStep?(delta) }
        )
        panel.contentView = NSHostingView(rootView: bar)

        self.panel = panel
    }
}

// MARK: - Model

/// Observable state shared between the panel and the SwiftUI bar.
///
/// Pagination is width-driven (like the native macOS picker): candidates are
/// packed onto a page until the bar would exceed `maxBarWidth`, then they spill
/// onto the next page. Page boundaries are precomputed in `recomputePages()`.
final class CandidateModel: ObservableObject {
    @Published var candidates: [String] = [] { didSet { recomputePages() } }
    @Published var auxiliaryText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var currentPage: Int = 0

    /// How the bar lays itself out. Set from the shared settings on each show.
    @Published var orientation: ByakaronSettings.CandidateOrientation = .horizontal

    /// Start global index of each page; `pageStarts.count == pageCount`.
    @Published private(set) var pageStarts: [Int] = [0]

    /// Maximum content width before candidates spill to the next page. Roughly
    /// matches the native picker's comfortable on-screen width.
    private let maxBarWidth: CGFloat = 460

    /// Hard cap on candidates per page, regardless of width (matches native,
    /// which also bounds a page to the 1–9 number-key range).
    private let maxPerPage = 9

    var pageCount: Int { max(pageStarts.count, 1) }

    /// Global index range of the candidates shown on `page`.
    func range(for page: Int) -> Range<Int> {
        guard !candidates.isEmpty, page >= 0, page < pageStarts.count else {
            return 0..<0
        }
        let start = pageStarts[page]
        let end = page + 1 < pageStarts.count ? pageStarts[page + 1] : candidates.count
        return start..<end
    }

    /// Pack candidates into pages by measured pill width against `maxBarWidth`.
    func recomputePages() {
        guard !candidates.isEmpty else {
            pageStarts = [0]
            currentPage = 0
            return
        }

        var starts: [Int] = [0]
        var width: CGFloat = 0
        for (i, text) in candidates.enumerated() {
            // Number within the page is 1-based; width contribution is small and
            // roughly constant, so estimate with a single digit.
            let countOnPage = i - starts.last!
            let pillW = CandidatePill.estimatedWidth(number: countOnPage + 1, text: text)
            let prospective = width + (width > 0 ? CandidateBar.itemSpacing : 0) + pillW
            let overWidth = prospective > maxBarWidth && countOnPage > 0
            let overCount = countOnPage >= maxPerPage
            if overWidth || overCount {
                starts.append(i)
                width = pillW
            } else {
                width = prospective
            }
        }
        pageStarts = starts
        currentPage = min(currentPage, starts.count - 1)
    }

    /// Make `currentPage` the page that contains `selectedIndex`.
    func syncPageToSelection() {
        guard !pageStarts.isEmpty else { currentPage = 0; return }
        var page = 0
        for (p, start) in pageStarts.enumerated() where selectedIndex >= start {
            page = p
        }
        currentPage = page
    }

    /// Step the visible page by `delta`, moving the selection to the first
    /// candidate of the new page. Returns true if the page actually changed.
    @discardableResult
    func stepPage(by delta: Int) -> Bool {
        let target = currentPage + delta
        guard target >= 0, target < pageCount, target != currentPage else { return false }
        currentPage = target
        selectedIndex = pageStarts[target]
        return true
    }
}

// MARK: - SwiftUI Bar

/// A horizontal candidate bar matching the native macOS input-method picker:
/// a frosted capsule of pill items, each with a small index and the candidate,
/// the selected one filled with the accent color. When candidates span more
/// than one page, a page indicator and up/down chevrons appear at the end.
struct CandidateBar: View {
    @ObservedObject var model: CandidateModel
    var onSelect: (Int) -> Void
    var onPageStep: (Int) -> Void

    static let itemSpacing: CGFloat = 0

    private var cornerRadius: CGFloat { model.orientation == .vertical ? 12 : 15 }

    var body: some View {
        content
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.orientation {
        case .horizontal: horizontalBar
        case .vertical: verticalList
        }
    }

    // MARK: - Horizontal (the native-picker style bar)

    private var horizontalBar: some View {
        let range = model.range(for: model.currentPage)

        return HStack(spacing: CandidateBar.itemSpacing) {
            ForEach(Array(range.enumerated()), id: \.element) { offset, index in
                CandidatePill(
                    number: offset + 1,
                    text: model.candidates[index],
                    isSelected: index == model.selectedIndex
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }

            if model.pageCount > 1 {
                Pager(
                    canPrev: model.currentPage > 0,
                    canNext: model.currentPage < model.pageCount - 1,
                    onStep: onPageStep
                )
            }
        }
    }

    // MARK: - Vertical (stacked rows, one candidate per line)

    private var verticalList: some View {
        let range = model.range(for: model.currentPage)

        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(range.enumerated()), id: \.element) { offset, index in
                CandidateRow(
                    number: offset + 1,
                    text: model.candidates[index],
                    isSelected: index == model.selectedIndex
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }

            if model.pageCount > 1 {
                Divider().padding(.vertical, 2)
                VerticalPager(
                    canPrev: model.currentPage > 0,
                    canNext: model.currentPage < model.pageCount - 1,
                    page: model.currentPage + 1,
                    pageCount: model.pageCount,
                    onStep: onPageStep
                )
            }
        }
        .frame(minWidth: 132, alignment: .leading)
    }
}

/// Native-style pager: a thin vertical divider followed by stacked up/down
/// chevrons. No page number — just the controls. Up = previous page,
/// Down = next page.
private struct Pager: View {
    let canPrev: Bool
    let canNext: Bool
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 4)
                .padding(.trailing, 6)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                Chevron(systemName: "chevron.up", enabled: canPrev) { onStep(-1) }
                Chevron(systemName: "chevron.down", enabled: canNext) { onStep(1) }
            }
            .padding(.trailing, 4)
        }
    }

    private struct Chevron: View {
        let systemName: String
        let enabled: Bool
        let action: () -> Void

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 16, height: 11)
                .contentShape(Rectangle())
                .onTapGesture { if enabled { action() } }
        }
    }
}

/// One row of the vertical candidate list: a leading index number and the
/// candidate text, the selected row filled with the accent color. Lays the index
/// out at a fixed width so candidates align in a column, mirroring native IMEs
/// that show a vertical list.
private struct CandidateRow: View {
    let number: Int
    let text: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .frame(width: 14, alignment: .trailing)

            Text(text)
                .font(.system(size: CandidatePill.candidateFontSize))
                .foregroundStyle(isSelected ? Color.white : Color.primary)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }
}

/// Pager for the vertical list: a page indicator with prev/next chevrons laid out
/// horizontally along the bottom row.
private struct VerticalPager: View {
    let canPrev: Bool
    let canNext: Bool
    let page: Int
    let pageCount: Int
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(page) / \(pageCount)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Chevron(systemName: "chevron.up", enabled: canPrev) { onStep(-1) }
            Chevron(systemName: "chevron.down", enabled: canNext) { onStep(1) }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 3)
        .padding(.top, 1)
    }

    private struct Chevron: View {
        let systemName: String
        let enabled: Bool
        let action: () -> Void

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 18, height: 14)
                .contentShape(Rectangle())
                .onTapGesture { if enabled { action() } }
        }
    }
}

private struct CandidatePill: View {
    let number: Int
    let text: String
    let isSelected: Bool

    // Layout constants reused by `estimatedWidth` for width-driven pagination.
    static let candidateFontSize: CGFloat = 17
    static let numberFontSize: CGFloat = 8
    static let hSpacing: CGFloat = 4
    static let hPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: CandidatePill.hSpacing) {
            Text("\(number)")
                .font(.system(size: CandidatePill.numberFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .baselineOffset(0)
          

            Text(text)
                .font(.system(size: CandidatePill.candidateFontSize))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .padding(.horizontal, CandidatePill.hPadding)
        .padding(.vertical, 4)
        .padding(.trailing, 0)
        .clipShape(.capsule)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    /// Estimate the rendered pill width for width-driven pagination. Measured
    /// with NSFont so it tracks the actual text layout reasonably closely.
    static func estimatedWidth(number: Int, text: String) -> CGFloat {
        let numW = ("\(number)" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: numberFontSize, weight: .medium)]
        ).width
        let textW = (text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: candidateFontSize)]
        ).width
        return numW + hSpacing + textW + hPadding * 2
    }
}

// MARK: - Previews

#if DEBUG
private func previewModel(
    selected: Int,
    orientation: ByakaronSettings.CandidateOrientation = .horizontal
) -> CandidateModel {
    let m = CandidateModel()
    m.orientation = orientation
    m.candidates = ["হাই", "hi", "👋", "হি", "হই", "হী", "হ্যি", "হায়", "হাঁই",
                    "হ্যাঁ", "হেই", "হৈ", "হাই-হ্যালো", "হালুম"]
    m.auxiliaryText = "hi"
    m.selectedIndex = selected
    m.recomputePages()
    m.syncPageToSelection()
    return m
}

#Preview("Horizontal") {
    CandidateBar(model: previewModel(selected: 0), onSelect: { _ in }, onPageStep: { _ in })
        .padding(40)
        .preferredColorScheme(.light)
}

#Preview("Horizontal (Dark)") {
    CandidateBar(model: previewModel(selected: 2), onSelect: { _ in }, onPageStep: { _ in })
        .padding(40)
        .preferredColorScheme(.dark)
}

#Preview("Vertical") {
    CandidateBar(model: previewModel(selected: 1, orientation: .vertical),
                 onSelect: { _ in }, onPageStep: { _ in })
        .padding(40)
        .preferredColorScheme(.light)
}

#Preview("Vertical (Dark)") {
    CandidateBar(model: previewModel(selected: 3, orientation: .vertical),
                 onSelect: { _ in }, onPageStep: { _ in })
        .padding(40)
        .preferredColorScheme(.dark)
}
#endif
