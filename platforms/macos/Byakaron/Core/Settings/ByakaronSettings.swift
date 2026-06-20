import Foundation

/// Shared settings store for Byakaron, compiled into BOTH the SwiftUI app and the
/// IME helper. Pure Foundation — no AppKit and no engine/IMKit dependency — so the
/// SwiftUI preference views can bind to it directly and the IME can read it.
///
/// The two products run as separate processes with different bundle IDs, so
/// `UserDefaults.standard` would give each its own private domain and never agree.
/// We therefore route everything through an explicit shared suite (`suiteName`)
/// that both processes open, and broadcast changes over
/// `DistributedNotificationCenter` so a setting flipped in the app's Settings
/// window reaches the already-running IME immediately.
enum ByakaronSettings {

    /// Shared preferences domain opened by both the app and the IME. Not a real
    /// sandboxed app group (the IME isn't sandboxed — see Byakaron.entitlements);
    /// it's a named `UserDefaults` suite, which on an unsandboxed Mac is a plain
    /// `~/Library/Preferences/<suite>.plist` both processes can read and write.
    static let suiteName = "dev.nuhu.byakaron.shared"

    /// The shared defaults both processes talk to.
    static let defaults = UserDefaults(suiteName: suiteName) ?? .standard

    // MARK: - Keys

    /// UserDefaults key for the phonetic-only toggle. When true, riti returns a
    /// single phonetic transliteration with no dictionary/autocorrect/emoji
    /// candidates — committed inline via the lonely-suggestion path.
    static let phoneticOnlyModeKey = "ByakaronPhoneticOnlyMode"

    /// Orientation of the candidate list shown by the IME.
    static let candidateOrientationKey = "ByakaronCandidateOrientation"

    /// Max candidates shown per page in the candidate list.
    static let candidatesPerPageKey = "ByakaronCandidatesPerPage"

    /// Font size (points) for candidate text in the IME candidate list.
    static let candidateFontSizeKey = "ByakaronCandidateFontSize"

    /// EXPERIMENTAL: route transliteration through the Zig libbyakaron engine
    /// instead of riti. When on, the IME runs in an inline phonetic mode (no
    /// candidate panel) driven by `ZigTransliterator`. Off by default.
    static let useZigTransliterationKey = "ByakaronUseZigTransliteration"

    // MARK: - Real settings (read by the IME)

    /// Whether phonetic-only mode is on, read from the shared suite.
    static var phoneticOnlyMode: Bool {
        get { defaults.bool(forKey: phoneticOnlyModeKey) }
        set {
            defaults.set(newValue, forKey: phoneticOnlyModeKey)
            broadcastChange()
        }
    }

    /// EXPERIMENTAL: whether the Zig transliteration engine is enabled, read
    /// from the shared suite. The IME rebuilds when this flips.
    static var useZigTransliteration: Bool {
        get { defaults.bool(forKey: useZigTransliterationKey) }
        set {
            defaults.set(newValue, forKey: useZigTransliterationKey)
            broadcastChange()
        }
    }

    /// Candidate-list orientation. Defaults to horizontal (the historical layout).
    static var candidateOrientation: CandidateOrientation {
        get {
            guard let raw = defaults.string(forKey: candidateOrientationKey),
                  let value = CandidateOrientation(rawValue: raw) else {
                return .horizontal
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: candidateOrientationKey)
            broadcastChange()
        }
    }

    /// How the candidate list is laid out on screen.
    enum CandidateOrientation: String, CaseIterable, Identifiable {
        case horizontal
        case vertical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .horizontal: return "Horizontal"
            case .vertical: return "Vertical"
            }
        }
    }

    // MARK: - Cross-process change notification

    /// Name broadcast over `DistributedNotificationCenter` whenever a setting the
    /// IME cares about changes. The IME observes this to rebuild its engine; a
    /// plain `NotificationCenter` would stay inside one process and never arrive.
    static let didChangeNotification = Notification.Name("dev.nuhu.byakaron.settingsDidChange")

    /// Tell every Byakaron process that a shared setting changed.
    static func broadcastChange() {
        DistributedNotificationCenter.default().postNotificationName(
            didChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Subscribe to cross-process setting changes. The handler runs on the main
    /// thread. Returns the observer token so the caller can remove it.
    @discardableResult
    static func observeChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
    }
}
