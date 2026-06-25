import AppKit
import LeaveMyMacAloneCore

/// Owns every subsystem and coordinates lock → authenticate → unlock.
@MainActor
final class AppController {
    private let store = AppSettingsStore()
    private let sleepGuard = SleepGuard()
    private let shield = ShieldController()
    private let inputBlocker = InputBlocker()
    private let kiosk = KioskMode()
    private let authenticator = Authenticator()
    private var machine = LockStateMachine()
    private let intruder = IntruderCapture(photographer: AVFoundationPhotographer())

    private var menuBar: MenuBarController?
    private var hotKey: GlobalHotKey?

    // Auth lifecycle guards. `authEpoch` is bumped whenever an authentication
    // attempt is started, superseded (re-present), or aborted (panic/watchdog);
    // a completing attempt only acts on its result if its captured epoch still
    // matches, so a stale/cancelled LAContext callback can never drive state.
    private var authEpoch = 0
    private var authTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    // Upper bound on how long the app may sit in `.authenticating`. If the auth
    // UI is dismissed/lost/hung without a result (e.g. the user escaped the
    // sheet), this fail-safes back to a clean locked state instead of stranding.
    private let authTimeout: Duration = .seconds(60)
    // Retain power-notification tokens for the app's lifetime.
    private var powerObservers: [NSObjectProtocol] = []
    // Drives the step-by-step first-run permission onboarding.
    private var onboardingTask: Task<Void, Never>?

    // Throttle the activation-recovery re-present (see reclaimForeground). The
    // LocalAuthentication agent is excluded by two guards, so this never fires in
    // normal use — it is a backstop so that if a foreground app (or a future
    // macOS that hosts the auth UI in an unrecognised .regular process) fights
    // for focus, we degrade to a clean locked state instead of looping forever.
    private var lastReclaimAt: Date?
    private var reclaimBurst = 0
    private let reclaimMinInterval: TimeInterval = 0.5
    private let reclaimBurstLimit = 3

    func start() {
        NSApp.setActivationPolicy(.accessory)

        let menu = MenuBarController(store: store)
        menu.onLockNow = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        }
        menu.onQuit = {
            NSApp.terminate(nil)
        }
        menuBar = menu

        // ⌃⌥⌘L registers with the WindowServer and is intentionally NOT consumed
        // by the event tap, so it stays live from ANY state as a panic
        // affordance: lock when unlocked, and abort-back-to-locked when stuck in
        // authentication (the single keyboard recovery path while the auth UI is
        // unreachable). See handleHotKey.
        hotKey = GlobalHotKey(onPressed: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleHotKey() }
        })

        store.onOpacityChange = { [weak self] opacity in
            guard let self else { return }
            Task { @MainActor in self.shield.setOpacity(opacity) }
        }

        registerPowerObservers()

        // Launch into the menu bar; NEVER auto-lock. The user locks on demand —
        // the "Şimdi Kilitle" menu item or the ⌃⌥⌘L hot key. If permissions are
        // missing, walk the user through granting them first.
        if !InputBlocker.hasRequiredPermissions() {
            startPermissionOnboarding()
        }
    }

    func lock() {
        guard machine.lock() else { return } // ignore if not unlocked
        intruder.beginSession(enabled: store.captureIntruderPhoto)
        // Keep the Mac awake while locked only if the user wants it (default on);
        // sleepGuard.end() on teardown is a no-op if we never began.
        if store.preventSleepWhileLocked {
            sleepGuard.begin()
        }
        // onUnlock = the "Kilidi Aç" button → begin auth. onInteract = a click
        // anywhere else on the shield → flash "still locked" while locked, or
        // re-present a buried auth sheet while authenticating (tap-independent
        // recovery, so a covering window can never strand the user).
        shield.show(opacity: store.overlayOpacity, onInteract: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleBackgroundClick() }
        }, onUnlock: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleUnlockButton() }
        })
        kiosk.engage()
        // Keyboard route into unlocking (the mouse drives the shield directly):
        // Space/Return begin auth, any other key flashes "still locked".
        let live = inputBlocker.start(onUnlockKey: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleUnlockButton() }
        }, onLockedKey: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleBackgroundClick() }
        })
        if !live {
            // Input blocking could not engage — never strand the user behind a
            // visible-but-non-functional lock. Roll back to unlocked and warn.
            inputBlocker.stop()
            kiosk.disengage()
            shield.hide()
            sleepGuard.end()
            _ = machine.abortLock()
            showTapFailureAlert()
        }
    }

    // ⌃⌥⌘L from any state. The hot key is never consumed by the tap, so it is
    // the guaranteed keyboard escape hatch.
    private func handleHotKey() {
        switch machine.state {
        case .unlocked:
            lock()
        case .authenticating:
            // Auth UI may be unreachable (e.g. after a Cmd+Tab escape). Abort
            // it and return to a clean, fully-armed locked state.
            panicRelock()
        case .locked:
            break // already locked; first interaction starts auth
        }
    }

    // The "Kilidi Aç" button. The deliberate way to start unlocking.
    private func handleUnlockButton() {
        switch machine.state {
        case .locked:
            noteIntruderInteraction()
            requestUnlock()
        case .authenticating:
            // The in-flight auth sheet was lost / buried; bring a fresh one to
            // the front instead of stranding.
            startAuth()
        case .unlocked:
            break
        }
    }

    // A click on the shield OUTSIDE the unlock button. While locked this only
    // flashes the lock badge so the user learns the button is the way out (it
    // does NOT begin auth). While authenticating it re-presents a buried auth
    // sheet (tap-independent recovery).
    private func handleBackgroundClick() {
        switch machine.state {
        case .locked:
            noteIntruderInteraction()
            shield.flashLocked()
        case .authenticating:
            startAuth()
        case .unlocked:
            break
        }
    }

    /// Count one locked-state interaction; capture a photo if the policy says so.
    /// Capture runs detached so a slow camera never delays the lock/unlock path.
    private func noteIntruderInteraction() {
        if intruder.registerInteraction() {
            Task { @MainActor in await self.intruder.performCapture() }
        }
    }

    private func requestUnlock() {
        guard machine.beginAuth() else { return }
        // Keep the tap live but in auth mode: it stops consuming plain input
        // (so the password sheet is usable) while still swallowing app/space
        // switching and launcher shortcuts that would let a passer-by escape.
        inputBlocker.beginAuthMode()
        // Drop the shield below the auth dialog so the password / Touch ID
        // screen appears on top of the dimmed overlay, not buried behind it.
        shield.lowerBelowAuthDialog()
        startAuth()
    }

    /// Present (or re-present) the auth UI. Each call supersedes any in-flight
    /// attempt via a fresh epoch, so only the newest sheet's result is honored.
    private func startAuth() {
        authEpoch &+= 1
        let epoch = authEpoch
        authenticator.cancel()      // abort any prior in-flight evaluation
        authTask?.cancel()
        NSApp.activate()            // re-take focus so the sheet is reachable
        startWatchdog(epoch: epoch)
        authTask = Task { @MainActor in
            let ok = await authenticator.authenticate(
                reason: "Mac'in kilidini açmak için kimliğini doğrula")
            guard epoch == self.authEpoch else { return } // superseded → ignore
            self.finishAuth(success: ok)
        }
    }

    private func finishAuth(success: Bool) {
        cancelWatchdog()
        if success {
            _ = machine.authSucceeded()
            inputBlocker.stop()
            kiosk.disengage()
            shield.hide(success: true)   // play the unlock flourish, then tear down
            sleepGuard.end()
            intruder.postUnlockNotification()
            intruder.endSession()
        } else if inputBlocker.endAuthMode() {
            _ = machine.authFailed()          // re-armed; stay locked
            shield.raiseToFullShield()        // back to full cover (no auth dialog)
        } else {
            // Tap could not be re-armed — fail safe rather than strand behind a
            // non-consuming lock.
            failSafeToUnlocked()
        }
    }

    /// Abort an in-flight authentication and return to a clean locked state.
    /// Invoked by ⌃⌥⌘L during auth and by the auth watchdog.
    private func panicRelock() {
        authEpoch &+= 1             // supersede the in-flight attempt's result
        cancelWatchdog()
        authenticator.cancel()
        authTask?.cancel()
        guard machine.state == .authenticating else { return }
        if inputBlocker.endAuthMode() {
            _ = machine.authFailed()          // authenticating -> locked
            shield.raiseToFullShield()        // back to full cover (no auth dialog)
        } else {
            failSafeToUnlocked()
        }
    }

    /// Last-resort teardown to unlocked when input blocking cannot be (re)armed.
    private func failSafeToUnlocked() {
        switch machine.state {
        case .authenticating: _ = machine.authSucceeded() // -> unlocked
        case .locked: _ = machine.abortLock()             // -> unlocked
        case .unlocked: break
        }
        inputBlocker.stop()
        kiosk.disengage()
        shield.hide()
        sleepGuard.end()
        showTapFailureAlert()
    }

    private func startWatchdog(epoch: Int) {
        cancelWatchdog()
        watchdogTask = Task { @MainActor in
            try? await Task.sleep(for: authTimeout)
            guard !Task.isCancelled,
                  epoch == self.authEpoch,
                  self.machine.state == .authenticating else { return }
            self.panicRelock()
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Power / session transitions

    private func registerPowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        })
        // The event tap cannot block Cmd+Tab once the password fallback turns on
        // Secure Event Input (the tap goes blind to keystrokes) — and our kiosk
        // presentationOptions only suppress switching while WE are frontmost. So
        // an app switch during auth can bury the sheet behind another app. Watch
        // for a real foreground app stealing focus and reclaim it directly,
        // independent of the tap. This is the tap-proof half of "wherever you go,
        // you land back on the password screen".
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Runs on the main queue. Extract Sendable scalars from the
            // (non-Sendable) NSRunningApplication here so nothing unsafe crosses
            // into the main-actor hop below.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? -1
            let isRegular = app?.activationPolicy == .regular
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.handleAppActivated(pid: pid, isRegular: isRegular, bundleID: bundleID)
            }
        })
    }

    /// A foreground app other than us became active while the Mac is locked or
    /// authenticating — almost always a Cmd+Tab escape that slipped past the tap.
    /// Reclaim the foreground (and re-present the sheet in front if mid-auth).
    private func handleAppActivated(pid: pid_t, isRegular: Bool, bundleID: String?) {
        guard machine.state == .locked || machine.state == .authenticating else { return }
        // Ignore ourselves (our own reclaim re-activates us), background/agent
        // apps, and the system auth agents that legitimately take focus while
        // evaluating the policy.
        if pid == NSRunningApplication.current.processIdentifier { return }
        if !isRegular { return }
        if Self.isSystemAuthAgent(bundleID) { return }
        reclaimForeground()
    }

    /// True for the background processes that draw the system authentication UI,
    /// which may briefly take focus and must NOT be treated as an escape.
    private static func isSystemAuthAgent(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        // Only Apple-signed system bundles qualify; never misclassify a
        // third-party app (which would silently exempt it from recovery).
        guard id.hasPrefix("com.apple.") else { return false }
        return id.contains("securityagent") || id.contains("loginwindow")
            || id.contains("coreauth") || id.contains("authui")
            || id.contains("localauthentication") || id.contains("biometric")
    }

    /// Pull our shield back to the front and, if authenticating, present a fresh
    /// auth sheet on top (superseding the buried one via a new epoch).
    private func reclaimForeground() {
        NSApp.activate()
        shield.reassert()
        guard machine.state == .authenticating else {
            reclaimBurst = 0
            return
        }
        // Detect a focus-fight: many reclaims in quick succession means something
        // keeps stealing the foreground faster than a human could. Collapse to a
        // clean, fully-armed locked state rather than re-presenting forever.
        let now = Date()
        if let last = lastReclaimAt, now.timeIntervalSince(last) < reclaimMinInterval {
            reclaimBurst += 1
        } else {
            reclaimBurst = 0
        }
        lastReclaimAt = now
        if reclaimBurst >= reclaimBurstLimit {
            reclaimBurst = 0
            lastReclaimAt = nil
            panicRelock()
            return
        }
        startAuth()
    }

    /// A session-level tap and presentation options can lapse across sleep/wake.
    /// Re-arm and re-assert if still locked; fail safe if input blocking is gone.
    private func handleWake() {
        guard machine.state == .locked else { return }
        if inputBlocker.ensureLive() {
            kiosk.reassert()
            shield.reassert()
        } else {
            failSafeToUnlocked()
        }
    }

    /// Don't sleep mid-authentication: collapse to a clean locked state so wake
    /// resumes with the tap armed rather than stuck behind an unreachable sheet.
    private func handleSleep() {
        if machine.state == .authenticating {
            panicRelock()
        }
    }

    // MARK: - First-run permission onboarding

    /// Walk the user through the two required privileges ONE AT A TIME, in order:
    /// Accessibility, then Input Monitoring. Each step opens its own Settings
    /// pane and waits until that privilege is granted before moving to the next.
    private func startPermissionOnboarding() {
        onboardingTask?.cancel()
        onboardingTask = Task { @MainActor in
            // The active keyboard tap needs only Accessibility (it supersedes
            // Input Monitoring), so this is a single step.
            if !InputBlocker.hasAccessibilityPermission() {
                _ = InputBlocker.ensureAccessibilityPermission(prompt: false) // register in the list
                guard self.promptPermissionStep(
                    name: "Erişilebilirlik",
                    paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                ) else { return }
                guard await self.waitForGrant({ InputBlocker.hasAccessibilityPermission() }) else {
                    self.showOnboardingTimeoutAlert(name: "Erişilebilirlik"); return
                }
            }
            // Granted — sit silently in the menu bar; the user locks on demand.
        }
    }

    /// Guided alert for one permission step; opens that privilege's Settings pane.
    /// Returns false if the user cancels.
    private func promptPermissionStep(name: String, paneURL: String) -> Bool {
        let localizedName = NSLocalizedString(name, comment: "Permission name")
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("%@ izni gerekli", comment: "Permission title"),
            localizedName)
        alert.informativeText = String(
            format: NSLocalizedString(
                "LeaveMyMacAlone girişi engelleyebilmek için %@ iznine ihtiyaç duyar. Aşağıdaki düğmeye bas, açılan listede LeaveMyMacAlone'u bul ve anahtarını aç. İzni verince otomatik tamamlanır.",
                comment: "Permission step body"),
            localizedName)
        alert.addButton(withTitle: String(
            format: NSLocalizedString("%@ Ayarlarını Aç", comment: "Open settings button"),
            localizedName))
        alert.addButton(withTitle: NSLocalizedString("İptal", comment: "Cancel button"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let url = URL(string: paneURL) { NSWorkspace.shared.open(url) }
        return true
    }

    /// Poll up to ~5 minutes for a privilege to be granted. Returns whether it
    /// was granted within the window.
    private func waitForGrant(_ granted: @escaping () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if granted() { return true }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }
        }
        return granted()
    }

    private func showOnboardingTimeoutAlert(name: String) {
        let localizedName = NSLocalizedString(name, comment: "Permission name")
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("%@ izni doğrulanamadı", comment: "Permission timeout title"),
            localizedName)
        alert.informativeText = NSLocalizedString(
            "İzni verdiysen LeaveMyMacAlone'u kapatıp yeniden açmayı dene, sonra menüden kilitle.",
            comment: "Permission timeout body")
        alert.addButton(withTitle: NSLocalizedString("Tamam", comment: "OK button"))
        NSApp.activate()
        alert.runModal()
    }

    private func showTapFailureAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Giriş engelleme kurulamadı", comment: "Tap failure title")
        alert.informativeText = NSLocalizedString(
            "Giriş engelleme etkinleştirilemedi, bu yüzden kilit kaldırıldı. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden LeaveMyMacAlone'a izin verildiğinden emin ol, sonra tekrar kilitle.",
            comment: "Tap failure body")
        alert.addButton(withTitle: NSLocalizedString("Tamam", comment: "OK button"))
        NSApp.activate()
        alert.runModal()
    }
}
