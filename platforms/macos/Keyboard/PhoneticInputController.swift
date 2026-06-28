import InputMethodKit

@objc(ByakaronInputController)
class ByakaronInputController: IMKInputController {
    private var latinBuffer = ""
    private var candidateList: [String] = []
    private var selectedText = ""
    private var candidatesWindow: IMKCandidates?
    private var settingsObserver: NSObjectProtocol?
    private static let panelControlKeyCodes: Set<UInt16> = [
        123, 124, 125, 126,  // left / right / down / up
        116, 121,  // page up / page down
        36, 76,  // Return / numpad Enter
    ]

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        PhoneticDictionary.preload()
        settingsObserver = ByakaronSettings.observeChanges { [weak self] in
            self?.reset()
        }
    }

    deinit {
        if let token = settingsObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? (any IMKTextInput) {
            commit(client: client)
        }
        candidatesWindow?.hide()
        super.deactivateServer(sender)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        candidateList
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string, !text.isEmpty else { return }
        selectedText = text
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string,
            let client = self.client() as (any IMKTextInput)?
        else { return }
        commitText(text, client: client)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event,
            event.type == .keyDown,
            let client = sender as? (any IMKTextInput)
        else {
            return false
        }

        let modifiers = event.modifierFlags
        if modifiers.contains(.command) || modifiers.contains(.control) {
            commit(client: client)
            return false
        }

        let keyCode = event.keyCode

        if let panel = candidatesWindow, panel.isVisible(), !latinBuffer.isEmpty {
            switch keyCode {
            case 53:  // Escape — abandon the word
                reset()
                clearMarkedText(client: client)
                return true

            case 49:  // Space — commit the highlighted candidate, pass the space on
                commit(client: client)
                return false

            case 51:  // Backspace — fall through to buffer editing below
                break

            default:
                if panelHandles(event, panel: panel) {
                    forwardToPanel(event, panel: panel)
                    return true
                }
            }
        }

        switch keyCode {
        case 36, 76:  // Return / numpad Enter (no panel)
            if !latinBuffer.isEmpty {
                commit(client: client)
                return true
            }
            return false

        case 53:  // Escape — drop the buffer, leave host text untouched
            if !latinBuffer.isEmpty {
                reset()
                clearMarkedText(client: client)
                return true
            }
            return false

        case 51:  // Backspace
            if !latinBuffer.isEmpty {
                latinBuffer.removeLast()
                if latinBuffer.isEmpty {
                    reset()
                    clearMarkedText(client: client)
                } else {
                    updateComposition(client: client)
                }
                return true
            }
            return false

        case 49:  // Space — commit the word, let the space fall through to the host
            if !latinBuffer.isEmpty {
                commit(client: client)
            }
            return false

        default:
            break
        }

        guard let characters = event.characters,
            let scalar = characters.unicodeScalars.first
        else {
            return false
        }

        if isAvroInputScalar(scalar) {
            latinBuffer.append(Character(scalar))
            updateComposition(client: client)
            return true
        }

        commit(client: client)
        return false
    }

    private func updateComposition(client: any IMKTextInput) {
        let bangla = Transliterator.toBangla(latinBuffer)
        selectedText = bangla
        showMarkedText(bangla, client: client)
        refreshCandidates(client: client)
    }

    private func refreshCandidates(client: any IMKTextInput) {
        guard let dict = PhoneticDictionary.shared, !latinBuffer.isEmpty else {
            candidateList = []
            candidatesWindow?.hide()
            return
        }

        candidateList = dict.suggestions(forLatin: latinBuffer)
        selectedText = candidateList.first ?? Transliterator.toBangla(latinBuffer)

        guard candidateList.count > 1, let panel = candidatesPanel() else {
            candidatesWindow?.hide()
            return
        }

        panel.setPanelType(panelType())
        panel.update()
        panel.show(IMKCandidatesLocationHint(kIMKLocateCandidatesBelowHint))
    }

    func commit(client: any IMKTextInput) {
        guard !latinBuffer.isEmpty else { return }
        let text = selectedText.isEmpty ? Transliterator.toBangla(latinBuffer) : selectedText
        commitText(text, client: client)
    }

    func commitText(_ text: String, client: any IMKTextInput) {
        reset()
        client.insertText(
            text as NSString,
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func reset() {
        latinBuffer = ""
        selectedText = ""
        candidateList = []
        candidatesWindow?.hide()
    }

    private func panelHandles(_ event: NSEvent, panel: IMKCandidates) -> Bool {
        if Self.panelControlKeyCodes.contains(event.keyCode) { return true }
        let selectionKeys = (panel.selectionKeys() as? [NSNumber]) ?? []
        return selectionKeys.contains(NSNumber(value: event.keyCode))
    }

    private func forwardToPanel(_ event: NSEvent, panel: IMKCandidates) {
        let selector = Selector(("handleKeyboardEvent:"))
        if panel.responds(to: selector) {
            panel.perform(selector, with: event)
        } else {
            panel.interpretKeyEvents([event])
        }
    }

    private func panelType() -> IMKCandidatePanelType {
        switch ByakaronSettings.candidateOrientation {
        case .vertical:
            return IMKCandidatePanelType(kIMKSingleColumnScrollingCandidatePanel)
        case .horizontal:
            return IMKCandidatePanelType(kIMKSingleRowSteppingCandidatePanel)
        }
    }

    private func candidatesPanel() -> IMKCandidates? {
        if let panel = candidatesWindow { return panel }
        guard let server = self.server(),
            let panel = IMKCandidates(server: server, panelType: panelType())
        else { return nil }
        panel.setAttributes([
            IMKCandidatesSendServerKeyEventFirst: NSNumber(value: true),
            NSAttributedString.Key.font.rawValue: NSFont.systemFont(ofSize: 16),
        ])
        panel.setDismissesAutomatically(false)
        candidatesWindow = panel
        return panel
    }

    private func showMarkedText(_ bangla: String, client: any IMKTextInput) {
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ]
        let attrStr = NSAttributedString(string: bangla, attributes: attrs)
        client.setMarkedText(
            attrStr,
            selectionRange: NSRange(location: bangla.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func clearMarkedText(client: any IMKTextInput) {
        client.setMarkedText(
            "" as NSString,
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func isAvroInputScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { return true }  // A-Z, a-z
        if v >= 0x30 && v <= 0x39 { return true }  // 0-9 → Bengali digits
        switch v {
        case 0x2E, 0x2C, 0x60, 0x3A, 0x5E, 0x24:  // . , ` : ^ $
            return true
        default:
            return false
        }
    }
}
