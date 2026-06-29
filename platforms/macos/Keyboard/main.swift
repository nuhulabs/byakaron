import Cocoa
import InputMethodKit

// Connection name MUST match Info.plist's InputMethodConnectionName
let kConnectionName = "dev.nuhu.labs.inputmethod.Byakaron_Connection"

// IMKServer must be a global to stay alive for the process lifetime
var server: IMKServer!

// Build identifier — check Console.app for "Byakaron" to verify which build is running
let byakaronBuildId = "build-20260506b"
NSLog("Byakaron: starting %@", byakaronBuildId)

// Install a minimal main menu so the welcome window honors standard Mac
// keyboard shortcuts (Cmd+W, Cmd+Q, Cmd+C/V/X/A) when it is the key window.
// Without an NSApp.mainMenu, an LSUIElement app has no key-equivalents to
// dispatch, so these shortcuts are silently ignored.
//
// Cmd+Q is intentionally rebound to performClose: instead of terminate:.
// This process is the IME service — terminating it interrupts typing system-
// wide. Closing the window is what users actually want here.
func installMainMenu() {
    let mainMenu = NSMenu()

    // App menu (title is the leftmost item label macOS shows in the menu bar)
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu(title: "Byakaron")
    appMenu.addItem(NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"))
    appMenu.addItem(NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "q"))
    appMenu.addItem(NSMenuItem(
        title: "Hide Byakaron",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"))
    appMenuItem.submenu = appMenu

    // Edit menu — needed for Cmd+C/V/X/A in the alert/text fields the welcome
    // window opens (e.g. update-check error messages).
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redo)
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
    editMenuItem.submenu = editMenu

    NSApplication.shared.mainMenu = mainMenu
}

installMainMenu()

// Register menu bar icon as template BEFORE IMKServer loads it —
// PDF template icon: macOS auto-inverts for dark menu bars + Globe key overlay
if let iconPath = Bundle.main.path(forResource: "iconTemplate", ofType: "pdf"),
   let icon = NSImage(contentsOfFile: iconPath) {
    icon.isTemplate = true
    icon.setName("iconTemplate")
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
        NSLog("Byakaron: NSSpellServer.registerLanguage(bn) failed")
    }
}
startSpellServer()

autoreleasepool {
    server = IMKServer(name: kConnectionName,
                       bundleIdentifier: Bundle.main.bundleIdentifier!)

    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate

    // Keep a strong reference so ARC doesn't release it
    withExtendedLifetime(delegate) {
        NSApplication.shared.run()
    }
}
