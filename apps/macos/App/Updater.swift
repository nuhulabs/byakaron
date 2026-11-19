import AppKit
import Combine
import CryptoKit
import Foundation
import Security

/// Byakaron updating itself from nuhulabs/Byakaron-Assets.
///
/// Which release to take is the shared core's call (src/Update.zig, through
/// `byakaron_update_pick`): the newest one the `update_channel` setting takes
/// that is newer than this build. This class does the macOS part:
///
/// 1. Once a day while `auto_update` is on (and on Check for Updates), fetch
///    GitHub's release list.
/// 2. Download that release's Byakaron.dmg, check it against the SHA-256
///    GitHub keeps for it (or the release's SHA256SUMS), and copy the app out
///    of the disk image, refusing one not signed like this app.
/// 3. "Restart to Update" (toolbar, Settings › Updates): quit, swap the new
///    app in place of this one, open it. At launch the new app reinstalls the
///    keyboard (KeyboardInstaller.ensureInstalled), which has changed with it.
///
/// A local build (`byakaron_update_build_channel() < 0`) only checks when
/// asked. One request to github.com per check; nothing about the user is sent.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        /// The new app is staged; restarting installs it.
        case ready(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    /// The release asset this app updates from.
    static let asset = "Byakaron.dmg"
    private static let every: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "ByakaronLastUpdateCheck"

    private var timer: Timer?
    private var staged: URL?
    private var downloadedImage: URL?

    /// "27.0.0-beta.3"
    let currentVersion = String(cString: byakaron_version())
    /// A release build, not a local one.
    let isRelease = byakaron_update_build_channel() >= 0

    private init() {
        lastChecked = ByakaronSettings.defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Check now if one is due, and then every hour whether one is.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        // Not while the app is still opening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkIfDue() }
    }

    func checkIfDue() {
        // A test feed (BYAKARON_UPDATE_FEED) is checked at every launch.
        let testing = ProcessInfo.processInfo.environment["BYAKARON_UPDATE_FEED"] != nil
        guard testing || isRelease, settings().auto else { return }
        if !testing, let last = lastChecked, last <= Date(), Date().timeIntervalSince(last) < Self.every { return }
        Task { await check(announce: false) }
    }

    /// The channel changed: what was found for the old one may not be right.
    func channelChanged() {
        if case .downloading = state { return }
        discardStaged()
        state = .idle
        Task { await check(announce: false) }
    }

    /// Check, and download what is found. `announce`: someone asked from the
    /// menu, so say what came of it in an alert too.
    func check(announce: Bool) async {
        switch state {
        case .checking, .downloading: return
        case .ready(let version):
            if announce { alert("Byakaron \(version) is ready", "Restart Byakaron to finish updating.", restart: true) }
            return
        default: break
        }
        state = .checking
        let (_, channel) = settings()
        do {
            let feed = try await fetchFeed()
            lastChecked = Date()
            ByakaronSettings.defaults.set(lastChecked, forKey: Self.lastCheckKey)
            guard let release = try Self.pick(feed: feed, channel: channel) else {
                state = .upToDate
                if announce { alert("Byakaron is up to date", "\(currentVersion) is the newest version on this channel.") }
                return
            }
            try await download(release)
            if announce, case .ready(let version) = state {
                alert("Byakaron \(version) is ready", "Restart Byakaron to finish updating.", restart: true)
            }
        } catch {
            NSLog("Byakaron: update check failed: %@", "\(error)")
            state = .failed(error.localizedDescription)
            if announce { alert("Could not update Byakaron", error.localizedDescription) }
        }
    }

    // MARK: - Settings

    /// `auto_update` and `update_channel` from the shared settings.
    private func settings() -> (auto: Bool, channel: Int32) {
        let fallback = Int32(max(0, byakaron_update_build_channel()))
        guard let composer = ByakaronSettings.openComposer() else { return (true, fallback) }
        defer { byakaron_composer_destroy(composer) }
        let auto = ByakaronSettings.value("auto_update", composer) ?? 1
        let channel = ByakaronSettings.value("update_channel", composer).map(Int32.init) ?? fallback
        return (auto != 0, channel)
    }

    // MARK: - Check

    struct Release {
        let tag: String
        let version: String
        let url: URL
        let sha256: String?
        let size: UInt64
    }

    private var userAgent: String { "Byakaron/\(currentVersion) (macOS)" }

    private func fetchFeed() async throws -> String {
        guard let url = URL(string: String(cString: byakaron_update_feed_url())) else {
            throw UpdateError("The update address is not valid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("github.com answered \(http.statusCode). Try again later.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pick(feed: String, channel: Int32) throws -> Release? {
        var r = ByakaronRelease()
        let found = byakaron_update_pick(feed, nil, channel, asset, &r)
        defer { byakaron_update_free(&r) }
        switch found {
        case 1:
            guard let url = URL(string: String(cString: r.url)) else { throw UpdateError("The release has a bad link.") }
            return Release(
                tag: String(cString: r.tag), version: String(cString: r.version), url: url,
                sha256: r.sha256.map { String(cString: $0) }, size: r.size)
        case 0:
            return nil
        default:
            throw UpdateError("github.com sent something unexpected. Try again later.")
        }
    }

    // MARK: - Download and stage

    private static var updatesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("dev.nuhu.labs.Byakaron/Updates", isDirectory: true)
    }

    private func download(_ release: Release) async throws {
        state = .downloading(version: release.version)
        let fm = FileManager.default
        discardStaged()
        let dir = Self.updatesDirectory.appendingPathComponent(release.tag, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var request = URLRequest(url: release.url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed (\(http.statusCode)).")
        }
        let image = dir.appendingPathComponent(Self.asset)
        try fm.moveItem(at: tmp, to: image)

        let expected: String
        if let sha = release.sha256 {
            expected = sha
        } else {
            expected = try await sumFromSums(release)
        }
        guard try await Self.sha256(of: image) == expected.lowercased() else {
            try? fm.removeItem(at: dir)
            throw UpdateError("The download does not match its checksum.")
        }

        let app = dir.appendingPathComponent("Byakaron.app", isDirectory: true)
        try await Self.copyApp(from: image, to: app)
        try Self.checkSignature(of: app)
        downloadedImage = image
        staged = app
        state = .ready(version: release.version)
    }

    /// The release's SHA256SUMS line for the asset.
    private func sumFromSums(_ release: Release) async throws -> String {
        let url = release.url.deletingLastPathComponent().appendingPathComponent("SHA256SUMS")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == Self.asset {
                return String(parts[0])
            }
        }
        throw UpdateError("The release has no checksum for \(Self.asset).")
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Mount the disk image, copy Byakaron.app out of it, unmount.
    private static func copyApp(from image: URL, to app: URL) async throws {
        let mount = image.deletingLastPathComponent().appendingPathComponent("mnt", isDirectory: true)
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                          "-mountpoint", mount.path, image.path])
        do {
            try await run("/usr/bin/ditto", [mount.appendingPathComponent("Byakaron.app").path, app.path])
        } catch {
            try? await run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
            throw UpdateError("The disk image has no Byakaron.app.")
        }
        try? await run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
        try? FileManager.default.removeItem(at: mount)
    }

    /// The new app must be validly signed, be Byakaron, and come from the same
    /// team as this one (when this one is signed by a team: a local ad-hoc
    /// build takes any valid signature).
    private static func checkSignature(of app: URL) throws {
        guard let new = Bundle(url: app), new.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The downloaded app is not Byakaron.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil)
                == errSecSuccess
        else {
            throw UpdateError("The downloaded app's signature is not valid.")
        }
        if let mine = teamID(Bundle.main.bundleURL), teamID(app) != mine {
            throw UpdateError("The downloaded app is not signed by Byakaron's developer.")
        }
    }

    private static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func discardStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        staged = nil
        downloadedImage = nil
    }

    // MARK: - Install

    /// Quit, put the staged app where this one is, and open it. Where this app
    /// cannot be replaced (a folder this user cannot write), open the disk
    /// image to drag it over by hand.
    func restartAndInstall() {
        guard case .ready = state, let staged else { return }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            if let downloadedImage { NSWorkspace.shared.open(downloadedImage) }
            return
        }
        // $1 our pid, $2 this app, $3 the new one. The old app is kept until
        // the new one is in place, and put back if that fails.
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            next="$2.update"; prev="$2.previous"
            rm -rf "$next" "$prev"
            if /usr/bin/ditto "$3" "$next" && mv "$2" "$prev"; then
                if mv "$next" "$2"; then rm -rf "$prev"; else mv "$prev" "$2"; fi
            fi
            rm -rf "$next" "$(dirname "$3")"
            /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
            /usr/bin/open "$2"
            """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
        do {
            try swap.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func alert(_ title: String, _ text: String, restart: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if restart {
            alert.addButton(withTitle: "Restart to Update")
            alert.addButton(withTitle: "Later")
        }
        if alert.runModal() == .alertFirstButtonReturn, restart { restartAndInstall() }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tool)
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    done.resume()
                } else {
                    done.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))."))
                }
            }
            do { try proc.run() } catch { done.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
