import AppKit

/// The app's composer for "Avro typing": the same engine, settings, learned
/// choices and personal dictionary as the installed keyboard (they share
/// `ByakaronSettings.dataDirectory`), so the keyboard's typing and suggestions
/// can be tried here without installing it and logging out. Main thread only.
enum AppComposer {
    static let handle: OpaquePointer? = ByakaronSettings.openComposer(
        spellDB: Bundle.main.url(forResource: "Byakaron", withExtension: "db")?.path,
        onUpdate: { _ in
            // Spelling corrections arrived on the composer's worker thread.
            DispatchQueue.main.async {
                guard let handle = AppComposer.handle else { return }
                byakaron_composer_refresh(handle)
                ComposingTextView.active?.redraw()
            }
        }
    )
}

/// An `NSTextView` that, while `avroTyping` is on, sends key events to the
/// composer the way the keyboard (`ByakaronInputController`) does: the
/// highlighted candidate is the marked text, commits are inserted, keys the
/// composer does not consume reach the text view as usual, and the candidates
/// show in `CandidatePanel`.
final class ComposingTextView: NSTextView {
    /// The view whose composer state is on screen, redrawn when corrections arrive.
    fileprivate static weak var active: ComposingTextView?

    var avroTyping = false {
        didSet {
            guard avroTyping != oldValue else { return }
            if !avroTyping { flush() }
        }
    }

    private lazy var candidatePanel = CandidatePanel { [weak self] index in
        guard let self, let composer = AppComposer.handle else { return }
        self.apply(byakaron_composer_pick(composer, index))
    }

    override func keyDown(with event: NSEvent) {
        guard avroTyping, let composer = AppComposer.handle else {
            super.keyDown(with: event)
            return
        }
        Self.active = self
        if !apply(ComposerKeys.send(event, to: composer)) {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        flush()  // the caret is about to leave the word
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        flush()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { flush() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Insert the result's commit, redraw, and report whether the key was consumed.
    @discardableResult
    private func apply(_ result: ByakaronKeyResult) -> Bool {
        if let commit = result.commitText { commitText(commit) }
        redraw()
        return result.handled != 0
    }

    /// Commit the word being typed where it stands.
    func flush() {
        guard let composer = AppComposer.handle, hasMarkedText() else {
            candidatePanel.orderOut(nil)
            return
        }
        if let text = byakaron_composer_flush(composer), text.pointee != 0 {
            commitText(String(cString: text))
        }
        redraw()
    }

    /// Replace the marked text (the word being composed) with `text`.
    private func commitText(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Draw the composer's state: the highlighted candidate as marked text and
    /// the current page in the candidate panel.
    fileprivate func redraw() {
        guard let composer = AppComposer.handle else { return }
        let state = ComposerSnapshot(composer)
        if state.composing {
            setMarkedText(
                state.preedit,
                selectedRange: NSRange(location: (state.preedit as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        } else if hasMarkedText() {
            // The word was dropped (Esc, or Backspace to empty): commits arrive
            // through `commitText`, so whatever is still marked goes.
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        guard state.panelVisible, !state.candidates.isEmpty, let window else {
            candidatePanel.orderOut(nil)
            return
        }
        // Below the marked text, like the keyboard's panel.
        var actual = NSRange()
        let caret = firstRect(forCharacterRange: markedRange(), actualRange: &actual)
        candidatePanel.show(state, below: caret, in: window)
    }
}

/// A small native candidate window for the app's "Avro typing" editor: the
/// composer's current page, numbered, with the highlighted candidate selected,
/// horizontal or vertical per the `candidate_orientation` setting. Clicking a
/// candidate picks it. (The keyboard uses IMK's own panel, which only an input
/// method can create.)
final class CandidatePanel: NSPanel {
    private let list = CandidateListView()

    init(onPick: @escaping (Int) -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = true
        list.onPick = onPick
        contentView = list
    }

    func show(_ state: ComposerSnapshot, below caret: NSRect, in parent: NSWindow) {
        list.state = state
        let size = list.fittingSize
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            if origin.y < screen.minY { origin.y = caret.maxY + 4 }  // no room below
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    override func orderOut(_ sender: Any?) {
        parent?.removeChildWindow(self)
        super.orderOut(sender)
    }
}

private final class CandidateListView: NSView {
    var onPick: ((Int) -> Void)?
    var state = ComposerSnapshot() {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let font = NSFont.systemFont(ofSize: 16)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 6
    private let itemPadding: CGFloat = 8
    private let rowHeight: CGFloat = 26

    private func label(_ i: Int) -> NSAttributedString {
        let s = NSMutableAttributedString(
            string: "\(i + 1) ",
            attributes: [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
        s.append(NSAttributedString(string: state.candidates[i], attributes: [.font: font]))
        return s
    }

    private var pageLabel: NSAttributedString? {
        guard state.pageCount > 1 else { return nil }
        return NSAttributedString(
            string: "\(state.page + 1)/\(state.pageCount)",
            attributes: [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        )
    }

    /// Each candidate's rectangle, in view coordinates.
    private func itemRects() -> [NSRect] {
        var rects: [NSRect] = []
        if state.vertical {
            let width = (0..<state.candidates.count).map { label($0).size().width }.max() ?? 0
            for i in state.candidates.indices {
                let y = padding + CGFloat(i) * rowHeight
                rects.append(NSRect(x: padding, y: y, width: width + 2 * itemPadding, height: rowHeight))
            }
        } else {
            var x = padding
            for i in state.candidates.indices {
                let w = label(i).size().width + 2 * itemPadding
                rects.append(NSRect(x: x, y: padding, width: w, height: rowHeight))
                x += w + 2
            }
        }
        return rects
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let rects = itemRects()
        var size = NSSize(
            width: (rects.map(\.maxX).max() ?? 0) + padding,
            height: (rects.map(\.maxY).max() ?? 0) + padding
        )
        if let page = pageLabel {
            if state.vertical {
                size.height += page.size().height + 2
            } else {
                size.width += page.size().width + itemPadding
            }
        }
        return size
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.stroke()

        for (i, rect) in itemRects().enumerated() {
            let text = NSMutableAttributedString(attributedString: label(i))
            if i == state.highlight {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                text.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: text.length))
            }
            let size = text.size()
            text.draw(at: NSPoint(x: rect.minX + itemPadding, y: rect.midY - size.height / 2))
        }

        if let page = pageLabel {
            let size = page.size()
            let at =
                state.vertical
                ? NSPoint(x: bounds.maxX - padding - size.width, y: bounds.maxY - padding - size.height)
                : NSPoint(x: bounds.maxX - padding - size.width, y: bounds.midY - size.height / 2)
            page.draw(at: at)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = itemRects().firstIndex(where: { $0.contains(point) }) { onPick?(index) }
    }
}
