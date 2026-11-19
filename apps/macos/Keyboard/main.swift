import Cocoa
import InputMethodKit

// Connection name MUST match Info.plist's InputMethodConnectionName
let kConnectionName = "dev.nuhu.labs.inputmethod.Byakaron_Connection"

// IMKServer must be a global to stay alive for the process lifetime
var server: IMKServer!

// Build identifier — check Console.app for "Byakaron" to verify which build is running
let byakaronBuildId = "build-20260506b"
NSLog("Byakaron: starting %@", byakaronBuildId)

// An idle LSUIElement app with no visible windows is App Napped: macOS drops it
// to background CPU and I/O priority and lets its memory be compressed and
// swapped. Switching to Byakaron then waits for the napped process to wake and
// page itself back in, and the keys typed meanwhile reach the app as plain
// English. An input method answers keystrokes, so it opts out for its lifetime
// (idle system sleep stays allowed).
let appNapActivity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "Byakaron input method answers keystrokes")

// Register menu bar icon as template BEFORE IMKServer loads it —
// PDF template icon: macOS auto-inverts for dark menu bars + Globe key overlay
if let iconPath = Bundle.main.path(forResource: "MenuIcon", ofType: "pdf"),
    let icon = NSImage(contentsOfFile: iconPath)
{
    icon.isTemplate = true
    icon.setName("MenuIcon")
}

// NSSpellServer — shipped per product decision even though it may be inert on
// recent macOS. Started on a background queue (NSSpellServer.run blocks).
// Strong refs keep both alive for the process lifetime.
var spellServer: NSSpellServer?
var spellServerDelegate: ByakaronSpellServerDelegate?

func startSpellServer() {
    let srv = NSSpellServer()
    let del = ByakaronSpellServerDelegate()
    srv.delegate = del
    if srv.registerLanguage("bn", byVendor: "Byakaron") {
        spellServer = srv
        spellServerDelegate = del
        DispatchQueue.global(qos: .utility).async {
            NSLog("Byakaron: NSSpellServer running for bn")
            srv.run()
            NSLog("Byakaron: NSSpellServer.run returned")
        }
    } else {
        // Expected on recent macOS: the system no longer surfaces third-party
        // NSSpellServer language vendors. Not an error — spell-check/suggestions
        // are delivered through IMK, not this route.
        NSLog(
            "Byakaron: NSSpellServer 'bn' vendor not accepted by the system (expected on recent macOS); using IMK-based checking instead"
        )
    }
}
startSpellServer()

autoreleasepool {
    server = IMKServer(
        name: kConnectionName,
        bundleIdentifier: Bundle.main.bundleIdentifier!)

    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate

    // Keep a strong reference so ARC doesn't release it
    withExtendedLifetime(delegate) {
        NSApplication.shared.run()
    }
}
