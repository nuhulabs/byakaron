import AppKit

/// The suggestion panel, drawn by us for both the keyboard and the app's "Avro
/// typing" editor: the composer's current page as numbered pills with the
/// highlighted one filled, chevrons to page when there is more than one, and
/// a click on a pill to pick it. The look is the Linux pill panel (BYK_CSS in
/// apps/linux/App/main.c, Resources/gnome-shell/panel.css) and the Windows one
/// (apps/windows/Keyboard/CandidateWindow.cpp): change them together.
///
/// The keyboard used IMK's own `IMKCandidates` before. Its highlight is not
/// ours to move: `selectCandidate(withIdentifier:)` with either a row's or a
/// string's identifier left it on the first candidate while the arrows moved
/// the marked text. Drawing the panel ourselves draws the composer's highlight.
final class CandidatePanel: NSPanel {
    private let list = CandidatePillView()

    /// `onPick` gets an index into the current page; `onPage` true for the next page.
    init(onPick: @escaping (Int) -> Void, onPage: @escaping (Bool) -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        list.onPick = onPick
        list.onPage = onPage
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show `state` just below `caret` (screen coordinates), above it when
    /// there is no room below. With `parent`, the panel moves with that window.
    func show(_ state: ComposerSnapshot, below caret: NSRect, parent: NSWindow? = nil) {
        list.state = state
        let size = list.fittingSize
        var origin = NSPoint(x: caret.minX - CandidatePillView.inset, y: caret.minY - size.height - 2)
        let screen =
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: caret.midX, y: caret.midY)) }
            ?? parent?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            if origin.y < visible.minY { origin.y = caret.maxY + 2 }
        }
        // In the app the panel goes when the app does; the keyboard is a
        // background app that is never active, so its panel must not.
        hidesOnDeactivate = parent != nil
        if let parent {
            level = .popUpMenu
            if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        } else {
            // Above the client's windows, full screen ones and menus included.
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFront(nil)
        invalidateShadow()
    }

    override func orderOut(_ sender: Any?) {
        parent?.removeChildWindow(self)
        super.orderOut(sender)
    }
}

/// The pills. Colours are the system's dynamic ones, resolved as each frame is
/// drawn, so light and dark (and the accent colour) follow the system.
private final class CandidatePillView: NSView {
    var onPick: ((Int) -> Void)?
    var onPage: ((Bool) -> Void)?
    var state = ComposerSnapshot() {
        didSet {
            hovered = nil
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Room around the panel for nothing but drawing; also how far left of
    /// the caret the first pill's text starts.
    static let inset: CGFloat = 2 + itemPadding
    private static let itemPadding: CGFloat = 9

    private let font = NSFont.systemFont(ofSize: 16)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 2
    private let numberGap: CGFloat = 4
    private let chevronWidth: CGFloat = 16
    private var itemHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 4 }

    private var hovered: Int? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    // MARK: Layout

    private func number(_ i: Int, selected: Bool) -> NSAttributedString {
        let color = selected ? NSColor.white.withAlphaComponent(0.9) : NSColor.labelColor.withAlphaComponent(0.6)
        return NSAttributedString(string: "\(i + 1)", attributes: [.font: numberFont, .foregroundColor: color])
    }

    private func word(_ i: Int, selected: Bool) -> NSAttributedString {
        NSAttributedString(
            string: state.candidates[i],
            attributes: [.font: font, .foregroundColor: selected ? NSColor.white : NSColor.labelColor]
        )
    }

    private func contentWidth(_ i: Int) -> CGFloat {
        ceil(number(i, selected: false).size().width + numberGap + word(i, selected: false).size().width)
    }

    private var hasPages: Bool { state.pageCount > 1 }

    /// Each pill's rectangle, in view coordinates.
    private func itemRects() -> [NSRect] {
        let h = itemHeight
        let pad = Self.itemPadding
        if state.vertical {
            let width = (state.candidates.indices.map(contentWidth).max() ?? 0) + 2 * pad
            return state.candidates.indices.map {
                NSRect(x: padding, y: padding + CGFloat($0) * h, width: width, height: h)
            }
        }
        var x = padding
        return state.candidates.indices.map {
            let rect = NSRect(x: x, y: padding, width: contentWidth($0) + 2 * pad, height: h)
            x = rect.maxX
            return rect
        }
    }

    /// The previous/next chevrons, stacked at the trailing end.
    private func chevronRects(after items: [NSRect]) -> (up: NSRect, down: NSRect)? {
        guard hasPages else { return nil }
        let x = (items.map(\.maxX).max() ?? padding) + 2
        let mid = ((items.map(\.minY).min() ?? padding) + (items.map(\.maxY).max() ?? padding)) / 2
        let h: CGFloat = 12
        return (
            NSRect(x: x, y: mid - h, width: chevronWidth, height: h),
            NSRect(x: x, y: mid, width: chevronWidth, height: h)
        )
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let items = itemRects()
        var maxX = items.map(\.maxX).max() ?? 0
        if let chevrons = chevronRects(after: items) { maxX = chevrons.up.maxX + 2 }
        return NSSize(width: maxX + padding, height: (items.map(\.maxY).max() ?? 0) + padding)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = state.vertical ? 12 : frame.height / 2
        let background = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        (NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .labelColor) ?? .windowBackgroundColor)
            .setFill()
        background.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        background.lineWidth = 1
        background.stroke()

        let items = itemRects()
        for (i, rect) in items.enumerated() {
            let selected = i == state.highlight
            let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            if selected {
                NSColor.controlAccentColor.setFill()
                pill.fill()
            } else if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                pill.fill()
            }
            let n = number(i, selected: selected)
            let w = word(i, selected: selected)
            let nSize = n.size()
            let wSize = w.size()
            var x = rect.minX + Self.itemPadding
            // The number sits a little high, like a superscript beside the word.
            n.draw(at: NSPoint(x: x, y: rect.midY - wSize.height / 2 + 2))
            x += nSize.width + numberGap
            w.draw(at: NSPoint(x: x, y: rect.midY - wSize.height / 2))
        }

        if let chevrons = chevronRects(after: items) {
            drawChevron("chevron.up", in: chevrons.up, enabled: state.page > 0)
            drawChevron("chevron.down", in: chevrons.down, enabled: state.page + 1 < state.pageCount)
        }
    }

    private func drawChevron(_ name: String, in rect: NSRect, enabled: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.labelColor.withAlphaComponent(enabled ? 0.7 : 0.25)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return }
        let size = image.size
        image.draw(
            in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovered = itemRects().firstIndex { $0.contains(point) }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let items = itemRects()
        if let index = items.firstIndex(where: { $0.contains(point) }) {
            onPick?(index)
        } else if let chevrons = chevronRects(after: items) {
            if chevrons.up.insetBy(dx: -2, dy: -2).contains(point), point.y < chevrons.up.maxY {
                if state.page > 0 { onPage?(false) }
            } else if chevrons.down.insetBy(dx: -2, dy: -2).contains(point) {
                if state.page + 1 < state.pageCount { onPage?(true) }
            }
        }
    }
}
