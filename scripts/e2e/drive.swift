// End-to-end driver: launches a test copy, locks it through its real menu button,
// runs one scenario and prints PASS/FAIL lines. Started by run.sh.
//
// Safety rules:
//  - a detached deadman SIGKILLs the test copy after `deadmanSeconds`, whatever
//    happens to this process, so the screen always clears;
//  - no key is ever posted unless `locked()` holds (copy alive, shield on screen, copy
//    frontmost), so a keystroke can't land in another app.
//
// Limits worth knowing:
//  - synthetic Cmd+Opt+Esc does not open Force Quit even on an unlocked Mac, so that
//    shortcut can't be exercised here; the scenarios check that the kiosk's Force Quit
//    flag is in force instead. Synthetic Cmd+Tab does work, also under Secure Input.
//  - Touch ID and the real account password can't be automated.
import AppKit
import ApplicationServices

let deadmanSeconds = 45
let bundleID = "com.alperenkisi.leavemymacalone"

// MARK: - Helpers

func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func log(_ s: String) { print(s); fflush(stdout) }
func check(_ ok: Bool, _ what: String) { log("\(ok ? "PASS" : "FAIL") \(what)") }

func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        spin(0.05)
    }
    return cond()
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func texts(_ el: AXUIElement) -> [String] {
    ["AXTitle", "AXDescription", "AXValue", "AXLabel"]
        .compactMap { attr(el, $0) as? String }.filter { !$0.isEmpty }
}

func walk(_ el: AXUIElement, depth: Int = 0, visit: (AXUIElement) -> Bool) -> Bool {
    if visit(el) { return true }
    guard depth < 14, let kids = attr(el, "AXChildren") as? [AXUIElement] else { return false }
    for k in kids where walk(k, depth: depth + 1, visit: visit) { return true }
    return false
}

func axApp(_ pid: pid_t) -> AXUIElement {
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 1.5)
    return a
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    (attr(app, "AXWindows") as? [AXUIElement]) ?? []
}

func findButton(in app: AXUIElement, _ match: (String) -> Bool) -> AXUIElement? {
    var hit: AXUIElement?
    for win in windows(of: app) {
        _ = walk(win) { el in
            guard (attr(el, "AXRole") as? String) == "AXButton" else { return false }
            if texts(el).contains(where: match) { hit = el; return true }
            return false
        }
        if hit != nil { break }
    }
    return hit
}

func allText(of app: AXUIElement) -> [String] {
    var out: [String] = []
    for win in windows(of: app) {
        _ = walk(win) { el in
            for t in texts(el) where !out.contains(t) { out.append(t) }
            return false
        }
    }
    return out
}

func windowList() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
}

func ownerPID(_ w: [String: Any]) -> pid_t { w[kCGWindowOwnerPID as String] as? pid_t ?? -1 }
func layer(_ w: [String: Any]) -> Int { w[kCGWindowLayer as String] as? Int ?? 0 }
var fullShieldLevel: Int { Int(CGShieldingWindowLevel()) }

func shieldBounds(_ pid: pid_t) -> [[String: CGFloat]] {
    windowList().filter { ownerPID($0) == pid && layer($0) == fullShieldLevel }
        .compactMap { $0[kCGWindowBounds as String] as? [String: CGFloat] }
}

func everyDisplayCovered(_ pid: pid_t) -> Bool {
    let shields = shieldBounds(pid)
    return NSScreen.screens.allSatisfy { s in
        shields.contains { $0["Width"] == s.frame.width && $0["Height"] == s.frame.height && $0["X"] == s.frame.minX }
    }
}

func frontmostID() -> String {
    let f = NSWorkspace.shared.frontmostApplication
    return f?.bundleIdentifier ?? f?.localizedName ?? "?"
}

func secureInputHeld() -> Bool {
    let s = CGSessionCopyCurrentDictionary() as? [String: Any]
    return s?["kCGSSessionSecureInputPID"] != nil
}

func kioskInForce() -> Bool {
    let o = NSApplication.shared.currentSystemPresentationOptions
    return o.contains(.disableForceQuit) && o.contains(.disableProcessSwitching)
        && o.contains(.disableSessionTermination)
}

func systemAuthWindows() -> Int {
    windowList().filter {
        ($0[kCGWindowOwnerName as String] as? String)?.lowercased().contains("coreauth") == true
    }.count
}

func helperFullScreen(_ pid: pid_t) -> Bool? {
    windows(of: axApp(pid)).first.flatMap { attr($0, "AXFullScreen") as? Bool }
}

func secureFieldCount(_ pid: pid_t) -> Int {
    var n = 0
    for win in windows(of: axApp(pid)) {
        _ = walk(win) { el in
            if (attr(el, "AXSubrole") as? String) == "AXSecureTextField" { n += 1 }
            return false
        }
    }
    return n
}

func openApp(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    try? p.run()
    p.waitUntilExit()
}

let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = []) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
    usleep(25_000)
}
func tap(_ code: CGKeyCode) { key(code, true); key(code, false) }

// MARK: - Test copy

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: drive <test.app> <scenario> [test password]"); exit(2) }
let scenario = args[2]
_ = NSApplication.shared

let proc = Process()
proc.executableURL = URL(fileURLWithPath: args[1] + "/Contents/MacOS/LeaveMyMacAlone")
var testEnvironment: [String: String] = args.count > 3 ? ["LMMA_TEST_PASSWORD": args[3]] : [:]
if scenario == "slow-check-near-timeout" {
    testEnvironment["LMMA_TEST_AUTH_TIMEOUT"] = "3"
    testEnvironment["LMMA_TEST_VERIFY_DELAY"] = "3"
}
proc.environment = ProcessInfo.processInfo.environment.merging(testEnvironment) { $1 }
try proc.run()
let pid = proc.processIdentifier
let deadman = Process()
deadman.executableURL = URL(fileURLWithPath: "/bin/sh")
deadman.arguments = ["-c", "sleep \(deadmanSeconds); kill -9 \(pid) 2>/dev/null"]
try deadman.run()

var helper: Process?

func alive() -> Bool { proc.isRunning }

func finish(_ code: Int32 = 0) -> Never {
    helper?.terminate()
    if alive() { kill(pid, SIGKILL) }
    deadman.terminate()
    spin(0.5)
    exit(code)
}

func locked() -> Bool {
    alive() && !shieldBounds(pid).isEmpty && frontmostID() == bundleID
}

func requireLocked(_ doing: String) {
    guard locked() else {
        check(false, "\(doing): lock not confirmed, refusing to send keys (front=\(frontmostID()))")
        finish(1)
    }
}

func lockThroughMenu() -> Bool {
    let app = axApp(pid)
    guard waitUntil(4, { attr(app, "AXExtrasMenuBar") != nil }),
          let bar = attr(app, "AXExtrasMenuBar"),
          let item = (attr(bar as! AXUIElement, "AXChildren") as? [AXUIElement])?.first else {
        log("no status item")
        return false
    }
    AXUIElementPerformAction(item, "AXPress" as CFString)
    let isLock: (String) -> Bool = { $0.contains("Şimdi Kilitle") || $0.contains("Lock Now") }
    guard waitUntil(3, { findButton(in: app, isLock) != nil }), let button = findButton(in: app, isLock) else {
        log("no lock button")
        return false
    }
    AXUIElementPerformAction(button, "AXPress" as CFString)
    return waitUntil(4) { !shieldBounds(pid).isEmpty }
}

func unlockButton() -> AXUIElement? {
    findButton(in: axApp(pid)) { $0.contains("Kilidi Aç") || $0 == "Unlock" }
}

/// Press the shield's unlock button and wait for the password field to take focus.
func openPanel() {
    guard let button = unlockButton() else {
        check(false, "unlock button not found")
        finish(1)
    }
    AXUIElementPerformAction(button, "AXPress" as CFString)
    if !waitUntil(3, { secureInputHeld() }) {
        check(false, "password field did not take focus (Secure Input never came on)")
        finish(1)
    }
    spin(0.3)
}

func secureField() -> AXUIElement? {
    var found: AXUIElement?
    for win in windows(of: axApp(pid)) {
        _ = walk(win) { el in
            guard (attr(el, "AXSubrole") as? String) == "AXSecureTextField" else { return false }
            found = el
            return true
        }
    }
    return found
}

func axCenter(_ el: AXUIElement) -> CGPoint {
    var origin = CGPoint.zero, size = CGSize.zero
    if let v = attr(el, "AXPosition") { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
    if let v = attr(el, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
}

func mouseClick(at point: CGPoint, down: CGEventType, up: CGEventType,
                button: CGMouseButton, flags: CGEventFlags = []) {
    for type in [down, up] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

func panelRejected() -> Bool {
    allText(of: axApp(pid)).contains { $0.contains("Parola yanlış") || $0.contains("Incorrect password") }
}

func cmdTabMovesFront() -> Bool {
    requireLocked("Cmd+Tab")
    let before = frontmostID()
    key(0x37, true, .maskCommand)
    key(0x30, true, .maskCommand); key(0x30, false, .maskCommand)
    spin(0.15)
    key(0x37, false)
    spin(0.5)
    return frontmostID() != before
}

func sendQuit() -> Bool {
    _ = NSRunningApplication(processIdentifier: pid)?.terminate()
    return waitUntil(2.5) { !alive() }
}

// MARK: - Scenarios

spin(1.0)

let fullScreenStatePath = (args[1] as NSString).deletingLastPathComponent + "/../fullscreen-state"

func helperIsFullScreen() -> Bool {
    ((try? String(contentsOfFile: fullScreenStatePath, encoding: .utf8)) ?? "") == "1"
}

func helperOnScreen(_ hpid: pid_t) -> Bool {
    windowList().contains { ownerPID($0) == hpid && layer($0) == 0 }
}

func startFullScreenHelper() throws -> Process {
    try? FileManager.default.removeItem(atPath: fullScreenStatePath)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: (args[1] as NSString).deletingLastPathComponent + "/../fsapp")
    p.environment = ProcessInfo.processInfo.environment.merging(["LMMA_FSAPP_STATE": fullScreenStatePath]) { $1 }
    try p.run()
    return p
}

if scenario == "lock-over-fullscreen" {
    helper = try startFullScreenHelper()
    guard waitUntil(8, { helperIsFullScreen() }) else {
        check(false, "the full-screen helper never entered full screen, so nothing was tested")
        finish(1)
    }
    spin(1.2)
}

/// The launcher helper's text field, once its panel is open.
func launcherField(_ hpid: pid_t) -> AXUIElement? {
    var hit: AXUIElement?
    for win in windows(of: axApp(hpid)) {
        _ = walk(win) { el in
            if (attr(el, "AXRole") as? String) == "AXTextField" { hit = el; return true }
            return false
        }
    }
    return hit
}

func launcherText(_ hpid: pid_t) -> String {
    launcherField(hpid).flatMap { attr($0, "AXValue") as? String } ?? ""
}

/// Ctrl+Opt+Cmd+K with real modifier events (synthetic bare function keys don't fire hot keys).
func pressLauncherHotKey() {
    let c: CGEventFlags = .maskControl
    let co: CGEventFlags = [.maskControl, .maskAlternate]
    let coc: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    key(0x3B, true, c); key(0x3A, true, co); key(0x37, true, coc)
    key(0x28, true, coc); key(0x28, false, coc)
    key(0x37, false, co); key(0x3A, false, c); key(0x3B, false)
}

/// The process that holds keyboard focus right now, system-wide: where a key would land.
func keyboardFocusPID() -> pid_t? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 1.0)
    guard let focused = attr(system, "AXFocusedUIElement") else { return nil }
    var focusPID: pid_t = 0
    return AXUIElementGetPid(focused as! AXUIElement, &focusPID) == .success ? focusPID : nil
}

let launcherStatePath = (args[1] as NSString).deletingLastPathComponent + "/../launcher-state"

/// What the launcher helper reports about itself, without using accessibility.
func launcherState() -> (hasKeyboard: Bool, typed: String) {
    let lines = ((try? String(contentsOfFile: launcherStatePath, encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false)
    let typed = lines.first { $0.hasPrefix("typed=") }.map { String($0.dropFirst(6)) } ?? ""
    return (lines.contains("key=1"), typed)
}

let launcherScenarios: Set<String> = ["launcher-during-auth", "unlock-and-quit", "focus-reclaim-spares-controls",
                                      "launcher-without-accessibility"]
if launcherScenarios.contains(scenario) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: (args[1] as NSString).deletingLastPathComponent + "/../launcher")
    var launcherEnvironment = ProcessInfo.processInfo.environment
    launcherEnvironment["LMMA_LAUNCHER_STATE"] = launcherStatePath
    if scenario == "launcher-without-accessibility" { launcherEnvironment["LMMA_LAUNCHER_NO_AX"] = "1" }
    p.environment = launcherEnvironment
    try p.run()
    helper = p
    let hpid = p.processIdentifier
    spin(0.6)
}
if scenario == "launcher-during-auth", let hpid = helper?.processIdentifier {
    // Control, before any lock: the hot key opens the panel and typing reaches it. Only
    // type once the field really has focus, so the letter can't land in another app.
    pressLauncherHotKey()
    let focused = waitUntil(2) { keyboardFocusPID() == hpid }
    log("control: panel open=\(launcherField(hpid) != nil) focusPID=\(keyboardFocusPID().map(String.init) ?? "none") helper=\(hpid) front=\(frontmostID())")
    check(focused, "control: the launcher takes keyboard focus without being activated")
    guard focused else { finish(1) }
    tap(0x0C) // "q"
    let reached = waitUntil(1) { launcherText(hpid) == "q" }
    check(reached, "control: typing reaches the launcher when nothing is locked")
    guard reached else { finish(1) }
    pressLauncherHotKey()
    spin(0.4)
}
if scenario == "launcher-without-accessibility", let hpid = helper?.processIdentifier {
    // Control, before any lock. Accessibility can't see this helper, so it reports for itself.
    kill(hpid, SIGUSR1)
    let keyed = waitUntil(2) { launcherState().hasKeyboard }
    check(keyed, "control: the launcher takes the keyboard")
    guard keyed else { finish(1) }
    tap(0x0C) // "q", sent only now that the helper says it has the keyboard
    let reached = waitUntil(1) { launcherState().typed == "q" }
    check(reached, "control: typing reaches the launcher when nothing is locked")
    guard reached else { finish(1) }
    kill(hpid, SIGUSR1)
    spin(0.4)
}
if scenario == "lock-with-other-app-in-front" {
    openApp("Finder")
    spin(0.9)
}

guard lockThroughMenu() else {
    check(false, "\(scenario): could not lock (does this terminal have Accessibility permission?)")
    finish(1)
}
spin(0.8)

switch scenario {

case "quit-while-locked":
    // The quit Apple event: what pressing Q in the Cmd+Tab switcher sends.
    check(!sendQuit(), "quit request refused while locked")
    check(alive() && everyDisplayCovered(pid), "shield still up after the quit request")

case "lock-with-other-app-in-front":
    check(frontmostID() == bundleID, "lock takes the foreground from another app")
    check(kioskInForce(), "kiosk options in force")

case "lock-over-fullscreen":
    // The shield has to appear on another app's full-screen Space, with that app left alone.
    guard let hpid = helper?.processIdentifier else { finish(1) }
    spin(1.5)
    check(helperIsFullScreen(), "the full-screen app stays in full screen")
    check(helperOnScreen(hpid), "control: its Space really is the one on screen")
    check(everyDisplayCovered(pid), "the shield covers it")
    check(frontmostID() == bundleID && kioskInForce(), "frontmost with the kiosk in force")
    openPanel()
    check(frontmostID() == bundleID && kioskInForce(), "the password field works over it")

case "fullscreen-while-locked":
    // An app can enter full screen by itself during a lock (a video, a scheduled task).
    let p = try startFullScreenHelper()
    helper = p
    let entered = waitUntil(8) { helperIsFullScreen() }
    check(entered, "control: the helper entered full screen during the lock")
    spin(1.5)
    check(helperIsFullScreen(), "it stays in full screen")
    check(helperOnScreen(p.processIdentifier), "control: its Space really is the one on screen")
    check(everyDisplayCovered(pid), "the shield covers it")
    check(frontmostID() == bundleID && kioskInForce(), "the lock keeps the foreground")

case "password-stage":
    openPanel()
    check(frontmostID() == bundleID, "stays frontmost while the password field has focus")
    check(kioskInForce(), "kiosk (Force Quit, app switching, logout off) stays in force")
    check(everyDisplayCovered(pid), "shield stays at the full level on every display")
    check(systemAuthWindows() == 0, "no system auth window opened")
    check(!cmdTabMovesFront(), "Cmd+Tab does nothing")
    check(!sendQuit(), "quit request refused during auth")

case "launcher-during-auth":
    // Once the secure field has focus the tap is blind, so hot keys and any focus theft
    // must be stopped by other means, or blind typing could run a command in a launcher
    // behind the shield.
    guard let hpid = helper?.processIdentifier else { finish(1) }
    openPanel()
    requireLocked("launcher hot key")
    pressLauncherHotKey()
    check(!waitUntil(0.8) { launcherField(hpid) != nil }, "layer 1: global hot keys are off during auth")
    // Layer 2: a launcher can also open from a mouse button or a gesture.
    kill(hpid, SIGUSR1)
    check(waitUntil(1.5) { launcherField(hpid) != nil }, "the launcher panel opened without a hot key")
    // The launcher reports for itself: an instant reading of "focus is ours" could come
    // from before it took the keyboard.
    let tookKeyboard = waitUntil(1) { launcherState().hasKeyboard }
    let started = Date()
    let lostKeyboard = waitUntil(2) { !launcherState().hasKeyboard }
    log("launcher took the keyboard: \(tookKeyboard); held it for about \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    check(lostKeyboard, "layer 2: the launcher loses the keyboard again")
    check(waitUntil(1) { keyboardFocusPID() == pid }, "layer 2: the keyboard is back with the lock")
    // Harmless letters: they can only land in the launcher or the password field.
    guard alive(), !shieldBounds(pid).isEmpty else { check(false, "lock gone before typing"); finish(1) }
    tap(0x06); tap(0x06) // "zz"
    spin(0.5)
    check(launcherText(hpid).isEmpty, "typing does not reach the launcher (it got \"\(launcherText(hpid))\")")
    check(waitUntil(2) { secureInputHeld() && frontmostID() == bundleID }, "password field has focus again")

case "no-context-menu":
    // A menu above the shield offers Paste, which could submit the owner's clipboard.
    openPanel()
    guard let field = secureField() else { check(false, "no password field"); finish(1) }
    let center = axCenter(field)
    func menuOpen() -> Bool { !windowList().filter { ownerPID($0) == pid && layer($0) > fullShieldLevel }.isEmpty }
    func clearMenu() { if menuOpen() { tap(0x35); spin(0.3) } }
    mouseClick(at: center, down: .rightMouseDown, up: .rightMouseUp, button: .right)
    spin(0.6)
    check(!menuOpen(), "right-click on the password field opens no menu")
    clearMenu()
    mouseClick(at: center, down: .leftMouseDown, up: .leftMouseUp, button: .left, flags: .maskControl)
    spin(0.6)
    check(!menuOpen(), "Control-click on the password field opens no menu")
    clearMenu()
    key(0x3B, true, .maskControl); key(0x24, true, .maskControl); key(0x24, false, .maskControl); key(0x3B, false)
    spin(0.6)
    check(!menuOpen(), "the context-menu shortcut opens no menu")
    clearMenu()
    check(waitUntil(1) { secureInputHeld() && unlockButton() == nil }, "the panel is still open with its field focused")

case "focus-reclaim-spares-controls":
    // Taking the keyboard back must not press whatever the cursor happens to be on.
    guard let hpid = helper?.processIdentifier else { finish(1) }
    openPanel()
    guard let cancel = findButton(in: axApp(pid), { $0.contains("Vazgeç") || $0 == "Cancel" }) else {
        check(false, "no cancel button"); finish(1)
    }
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: axCenter(cancel), mouseButton: .left)?
        .post(tap: .cghidEventTap)
    spin(0.3)
    kill(hpid, SIGUSR1)
    check(waitUntil(1.5) { launcherField(hpid) != nil }, "the launcher panel opened")
    check(waitUntil(1.5) { keyboardFocusPID() == pid }, "the keyboard comes back with the cursor on Cancel")
    spin(0.5)
    check(unlockButton() == nil && secureInputHeld(), "the panel stays open: nothing was pressed")

case "launcher-without-accessibility":
    // A launcher that hides from the accessibility API must not get the keyboard either.
    guard let hpid = helper?.processIdentifier else { finish(1) }
    openPanel()
    kill(hpid, SIGUSR1)
    check(waitUntil(1.5) { windowList().contains { ownerPID($0) == hpid && layer($0) >= 0 } }, "the launcher panel opened")
    spin(0.6)
    guard alive(), !shieldBounds(pid).isEmpty else { check(false, "lock gone before typing"); finish(1) }
    log("launcher says it has the keyboard: \(launcherState().hasKeyboard)")
    tap(0x06); tap(0x06) // "zz": can only land in the launcher or the password field
    spin(0.5)
    check(launcherState().typed.isEmpty, "typing does not reach it (it got \"\(launcherState().typed)\")")

case "slow-check-near-timeout":
    // A correct password submitted just before the panel's timeout must still unlock.
    openPanel()
    spin(1.5)
    requireLocked("typing")
    tap(0x00); tap(0x0B); tap(0x08) // "abc"
    tap(0x24)
    check(waitUntil(6) { shieldBounds(pid).isEmpty }, "the check finishing after the old timeout still unlocks")

case "directory-unavailable":
    // A check that can't run says nothing about the password, and must say how to get out.
    openPanel()
    requireLocked("typing")
    tap(0x07) // "x" makes the debug verifier report the directory as unavailable
    tap(0x24)
    check(waitUntil(3) { allText(of: axApp(pid)).contains { $0.contains("doğrulanamadı") || $0.contains("can't be checked") } },
          "it says the password can't be checked, not that it is wrong")
    check(!panelRejected(), "it doesn't claim the password is wrong")
    check(everyDisplayCovered(pid), "still locked")

case "reclaim-foreground":
    openApp("Finder")
    check(waitUntil(2) { frontmostID() == bundleID && kioskInForce() },
          "locked: foreground and kiosk return after another app is activated")
    openPanel()
    openApp("Finder")
    check(waitUntil(2) { frontmostID() == bundleID && kioskInForce() },
          "authenticating: foreground and kiosk return")
    check(waitUntil(2) { secureInputHeld() }, "authenticating: password field has focus again")

case "wrong-password":
    // Goes through the real OpenDirectory check: counts as one failed login.
    openPanel()
    requireLocked("typing")
    tap(0x00) // "a"
    tap(0x24) // Return
    check(waitUntil(6) { panelRejected() }, "wrong password is rejected through OpenDirectory")
    check(alive() && everyDisplayCovered(pid) && frontmostID() == bundleID, "still locked afterwards")

case "cancel-and-keyboard-route":
    openPanel()
    requireLocked("Escape")
    tap(0x35) // Escape
    check(waitUntil(3) { !secureInputHeld() && unlockButton() != nil }, "Escape closes the panel")
    check(everyDisplayCovered(pid) && kioskInForce(), "still fully locked after cancelling")
    requireLocked("Space")
    tap(0x31) // Space, swallowed by the tap
    check(waitUntil(3) { secureInputHeld() }, "Space reopens the panel (the event tap is live)")

case "every-display-covered":
    check(everyDisplayCovered(pid), "locked: all \(NSScreen.screens.count) display(s) covered")
    openPanel()
    check(everyDisplayCovered(pid), "authenticating: all display(s) covered")
    check(secureFieldCount(pid) == 1, "exactly one password field on screen")

case "sigterm-rescue":
    // README's rescue path (`killall LeaveMyMacAlone` over SSH) must keep working.
    kill(pid, SIGTERM)
    check(waitUntil(3) { !alive() }, "SIGTERM ends a locked app, so the README rescue works")

case "unlock-and-quit":
    // Debug builds only: a fixed test password drives field -> verify -> teardown.
    openPanel()
    requireLocked("typing")
    tap(0x00) // "a" is wrong
    tap(0x24)
    check(waitUntil(3) { panelRejected() }, "wrong password rejected")
    check(waitUntil(2) { secureInputHeld() }, "field has focus again after a rejection")
    spin(0.2)
    requireLocked("typing")
    tap(0x00); tap(0x0B); tap(0x08) // "abc"
    tap(0x24)
    check(waitUntil(5) { shieldBounds(pid).isEmpty }, "correct password removes the shield")
    spin(0.8)
    check(!kioskInForce(), "kiosk released")
    check(NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory,
          "back to a menu bar app")
    if let hpid = helper?.processIdentifier {
        pressLauncherHotKey()
        check(waitUntil(1.5) { launcherField(hpid) != nil }, "global hot keys work again after unlocking")
        pressLauncherHotKey()
    }
    check(sendQuit(), "the app quits normally once unlocked")

default:
    check(false, "unknown scenario \(scenario)")
}

finish()
