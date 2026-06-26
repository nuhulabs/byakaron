import Cocoa
import InputMethodKit

@objc(ByakaronInputController)
class ByakaronInputController: IMKInputController {

    // MARK: - Engine state

    private var engineCtx: OpaquePointer?
    private var selectedIndex: UInt = 0
    private var candidatePanel: CandidatePanel?

    /// Buffer of raw Latin keystrokes for the in-progress word in Zig mode.
    var zigLatinBuffer = ""

    /// Built-in macOS candidate window used in Zig mode. Created lazily (it needs
    /// the global IMKServer) and reused for the controller's lifetime.
    var zigCandidatesWindow: IMKCandidates?

    /// Current candidate strings shown in `zigCandidatesWindow`. Index 0 is the
    /// live phonetic transliteration (the default commit). Returned to the panel
    /// from `candidates(_:)`.
    var zigCandidates: [String] = []

    /// The candidate that a plain commit (space/focus loss) will insert. Defaults
    /// to the phonetic transliteration and tracks the panel's highlight.
    var zigSelected = ""

    /// Bengali digits ০-৯ indexed by 0-9
    private static let bengaliDigits: [Character] = [
        "\u{09E6}", "\u{09E7}", "\u{09E8}", "\u{09E9}", "\u{09EA}",
        "\u{09EB}", "\u{09EC}", "\u{09ED}", "\u{09EE}", "\u{09EF}",
    ]

    // MARK: - Lifecycle

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        initializeEngine()
        // Settings live in the main app's Settings window, which runs as a
        // separate process and writes the shared suite. Observe the cross-process
        // broadcast so a toggle there rebuilds this running IME's engine.
        settingsObserver = ByakaronSettings.observeChanges { [weak self] in
            self?.rebuildEngine()
        }
    }

    /// Token for the DistributedNotificationCenter subscription, removed in deinit.
    private var settingsObserver: NSObjectProtocol?

    private func initializeEngine() {
        zigLatinBuffer = ""
        zigSelected = ""
        zigCandidates = []
        // Load the dictionary/suffix data once, off the main thread.
        PhoneticDictionary.preload()
        return
    }

    /// Tear down the riti context+config and re-create with current settings.
    /// Called when the phonetic-only toggle changes; any in-flight session is
    /// dropped (host marked text clears on next keystroke).
    private func rebuildEngine() {
        // Drop any in-flight Zig word; the buffer is cleared in initializeEngine.
        zigLatinBuffer = ""
        zigSelected = ""
        zigCandidates = []
        zigCandidatesWindow?.hide()
        hideCandidates()
        selectedIndex = 0
        initializeEngine()
    }

    deinit {
        if let token = settingsObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: - Key handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event,
              event.type == .keyDown,
              let client = sender as? (any IMKTextInput) else {
            return false
        }

        // Experimental Zig engine: fully separate inline-phonetic key handling.
        // See PhoneticInputController+Zig.swift.
        return handleZig(event, client: client)

    }

    private func hideCandidates() {
        candidatePanel?.hide()
    }


    // MARK: - Session lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        selectedIndex = 0
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? (any IMKTextInput) {
            commitZig(client: client)
        }
        zigCandidatesWindow?.hide()
        hideCandidates()
        super.deactivateServer(sender)

    }

    override func candidates(_ sender: Any!) -> [Any]! {
        // Zig mode feeds the built-in candidate window from its own list.
        return zigCandidates
    }

    // MARK: - Candidate window callbacks (Zig mode)

    /// The user moved the highlight in the candidate window. Track it so a plain
    /// commit (space / focus loss) inserts the highlighted candidate.
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string, !text.isEmpty else { return }
        zigSelected = text
    }

    /// The user picked a candidate (Return, a number key, or a click). Commit it.
    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string,
              let client = self.client() as (any IMKTextInput)? else { return }
        commitZigText(text, client: client)
    }
}

