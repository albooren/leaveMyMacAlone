import AppKit
import LeaveMyMacAloneCore
import LocalAuthentication

/// Owns every subsystem and coordinates lock → authenticate → unlock.
@MainActor
final class AppController {
    private let store = AppSettingsStore()
    private let sleepGuard = SleepGuard()
    private let shield = ShieldController()
    private let inputBlocker = InputBlocker()
    private let kiosk = KioskMode()
    private let authenticator = Authenticator()
    private let focusGuard = KeyboardFocusGuard()
    private let passwordVerifier: any PasswordVerifying
    private var passwordAttempts = PasswordAttemptPolicy()
    private var machine = LockStateMachine()
    private let intruder = IntruderCapture(photographer: AVFoundationPhotographer())

    private var menuBar: MenuBarController?
    private var updates: UpdateController?
    private var hotKey: GlobalHotKey?

    // Auth lifecycle guards. `authEpoch` is bumped whenever the auth panel opens,
    // closes or the lock ends; a completing attempt only acts on its result if its
    // captured epoch still matches, so a stale/cancelled LAContext callback or
    // password check can never drive state.
    private var authEpoch = 0
    private var authTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    // Upper bound on how long the auth panel stays open unattended. Counted from the
    // panel opening or the last rejected password; on expiry the panel closes (which
    // clears anything typed) and the Mac is simply locked again.
    private let authTimeout: Duration = .seconds(60)
    // Retain power-notification tokens for the app's lifetime.
    private var powerObservers: [NSObjectProtocol] = []
    // Drives the step-by-step first-run permission onboarding.
    private var onboardingTask: Task<Void, Never>?

    init(passwordVerifier: any PasswordVerifying = makePasswordVerifier()) {
        self.passwordVerifier = passwordVerifier
    }

    /// Whether the app may quit right now. See AppDelegate.applicationShouldTerminate.
    var allowsTermination: Bool { machine.allowsTermination }

    func start() {
        NSApp.setActivationPolicy(.accessory)

        let updates = UpdateController(isLocked: { [weak self] in
            self?.machine.state != .unlocked
        })
        self.updates = updates

        let menu = MenuBarController(store: store, updates: updates)
        menu.onLockNow = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        }
        menu.onQuit = {
            NSApp.terminate(nil)
        }
        menuBar = menu

        // ⌃⌥⌘L locks the Mac. The kiosk turns global hot keys off while locked, so
        // during a lock it only fires if we have lost the foreground. See handleHotKey.
        hotKey = GlobalHotKey(onPressed: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleHotKey() }
        })

        store.onOpacityChange = { [weak self] opacity in
            guard let self else { return }
            Task { @MainActor in self.shield.setOpacity(opacity) }
        }

        registerPowerObservers()
        intruder.installNotificationDelegate()

        // Launch into the menu bar; NEVER auto-lock and NEVER prompt for
        // permissions here. Accessibility is requested lazily, the first time the
        // user actually tries to lock (see lock()).
    }

    /// Entry point for locking ("Şimdi Kilitle" and ⌃⌥⌘L). The event tap needs
    /// Accessibility; if it isn't granted yet, walk the user through it and lock
    /// automatically once granted. If already granted, lock immediately.
    func lock() {
        guard machine.state == .unlocked else { return } // ignore unless idle
        if InputBlocker.hasAccessibilityPermission() {
            engageLock()
        } else {
            requestAccessibilityThenLock()
        }
    }

    /// Run the Accessibility onboarding, then lock automatically on grant. Guarded
    /// so repeated Lock presses don't start concurrent onboarding or double-lock.
    private func requestAccessibilityThenLock() {
        guard onboardingTask == nil else { return } // onboarding already in flight
        onboardingTask = Task { @MainActor in
            defer { self.onboardingTask = nil }
            _ = InputBlocker.ensureAccessibilityPermission(prompt: false) // register in the list
            guard self.promptPermissionStep(
                name: "Erişilebilirlik",
                paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }
            guard await self.waitForGrant({ InputBlocker.hasAccessibilityPermission() }) else {
                self.showOnboardingTimeoutAlert(name: "Erişilebilirlik"); return
            }
            // Granted — lock now, if still idle.
            if self.machine.state == .unlocked { self.engageLock() }
        }
    }

    /// The actual locking sequence (Accessibility already granted).
    private func engageLock() {
        guard machine.lock() else { return } // ignore if not unlocked
        // If the user is inside another app's native full-screen Space, our shield
        // (a third-party window) cannot cover it — pull that app out of full-screen
        // so the lock lands on a Desktop Space the shield covers. Any other full-screen
        // app goes too, so no uncovered Space is left on another display or one swipe
        // away. No-op otherwise.
        FullScreenExiter.exitFrontmostFullScreen()
        FullScreenExiter.exitEveryFullScreenInBackground()
        intruder.beginSession(enabled: store.captureIntruderPhoto)
        // Stop audio/video so nothing keeps playing (or leaking sound) at an
        // unattended desk — unless the owner chose to keep their music going.
        // Not resumed on unlock: the owner decides that.
        if !store.keepMediaPlaying {
            MediaPauser.pauseNowPlaying()
        }
        // Keep the Mac awake while locked only if the user wants it (default on);
        // sleepGuard.end() on teardown is a no-op if we never began.
        if store.preventSleepWhileLocked {
            sleepGuard.begin()
        }
        // onUnlock = the "Kilidi Aç" button → begin auth. onInteract = a click
        // anywhere else on the shield → flash "still locked" while locked, or
        // return focus to the password field while authenticating.
        shield.show(opacity: store.overlayOpacity, away: store.awayStatus(),
                   floating: store.floatingIcon(),
                   floatingSize: store.floatingSize, onInteract: { [weak self] in
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

    private func handleHotKey() {
        switch machine.state {
        case .unlocked:
            lock()
        case .authenticating:
            // Close the auth panel and return to a clean, fully-armed locked state.
            panicRelock()
        case .locked:
            break // already locked
        }
    }

    // The "Kilidi Aç" button. The deliberate way to start unlocking.
    private func handleUnlockButton() {
        switch machine.state {
        case .locked:
            noteIntruderInteraction()
            requestUnlock()
        case .authenticating:
            shield.focusAuth()
        case .unlocked:
            break
        }
    }

    // A click on the shield OUTSIDE the controls. While locked this only flashes the
    // lock badge so the user learns the button is the way out (it does NOT begin
    // auth). While authenticating it returns focus to the password field.
    private func handleBackgroundClick() {
        switch machine.state {
        case .locked:
            noteIntruderInteraction()
            shield.flashLocked()
        case .authenticating:
            shield.focusAuth()
        case .unlocked:
            break
        }
    }

    /// Count one locked-state interaction; capture a photo if the policy says so.
    /// Capture runs in a separate main-actor Task so a slow camera never delays
    /// the lock/unlock path.
    private func noteIntruderInteraction() {
        if intruder.registerInteraction() {
            Task { @MainActor in await self.intruder.performCapture() }
        }
    }

    /// Open the auth panel inside the shield. Nothing here hands the foreground to
    /// another process, so the kiosk stays in force for the whole authentication.
    private func requestUnlock() {
        guard machine.beginAuth() else { return }
        // Keep the tap live but in auth mode: it stops consuming plain input (so the
        // password field is usable) while still swallowing app/space switching and
        // launcher shortcuts that would let a passer-by escape.
        inputBlocker.beginAuthMode()
        authEpoch &+= 1
        let epoch = authEpoch
        startWatchdog(epoch: epoch)
        let biometricContext = authenticator.makeBiometricContext()
        shield.presentAuth(
            biometricContext: biometricContext,
            actions: AuthPanelActions(
                biometricViewReady: { [weak self] in
                    guard let self, let biometricContext else { return }
                    self.startBiometrics(biometricContext, epoch: epoch)
                },
                submitPassword: { [weak self] password in
                    self?.submitPassword(password, epoch: epoch)
                },
                cancel: { [weak self] in
                    self?.panicRelock()
                }))
        focusGuard.start { [weak self] in
            self?.shield.reclaimKeyboard()
        }
    }

    /// Wait for a finger or a Watch. Only success ends the lock: if it gives up (too
    /// many tries, lockout), the panel stays open and the password still works.
    private func startBiometrics(_ context: LAContext, epoch: Int) {
        guard epoch == authEpoch else { return }
        authTask = Task { @MainActor in
            let ok = await authenticator.evaluate(
                context,
                reason: NSLocalizedString("Mac'in kilidini açmak için kimliğini doğrula",
                                          comment: "Touch ID prompt reason"))
            guard epoch == self.authEpoch else { return } // superseded → ignore
            if ok {
                self.finishUnlock()
            } else {
                self.shield.biometricsEnded()
            }
        }
    }

    private func submitPassword(_ password: String, epoch: Int) {
        guard epoch == authEpoch, machine.state == .authenticating, !password.isEmpty else { return }
        let wait = passwordAttempts.retryDelay(now: ProcessInfo.processInfo.systemUptime)
        guard wait <= 0 else {
            shield.rejectPassword(.retryLater(seconds: Int(wait.rounded(.up))))
            return
        }
        shield.setAuthVerifying(true)
        Task { @MainActor in
            let result = await passwordVerifier.verify(password)
            guard epoch == self.authEpoch else { return } // superseded → ignore
            self.shield.setAuthVerifying(false)
            switch result {
            case .accepted:
                self.finishUnlock()
            case .rejected:
                self.noteRejectedPassword(epoch: epoch)
            case .unavailable:
                // Says nothing about the password, so it costs no attempt.
                self.shield.rejectPassword(.cannotVerify)
            }
        }
    }

    private func noteRejectedPassword(epoch: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        passwordAttempts.noteFailure(now: now)
        noteIntruderInteraction()
        startWatchdog(epoch: epoch)
        let wait = passwordAttempts.retryDelay(now: now)
        shield.rejectPassword(wait > 0 ? .retryLater(seconds: Int(wait.rounded(.up))) : .wrongPassword)
    }

    /// Authentication succeeded: tear the lock down.
    private func finishUnlock() {
        focusGuard.stop()
        cancelWatchdog()
        authEpoch &+= 1             // nothing still in flight may act on this lock
        authenticator.cancel()
        passwordAttempts.reset()
        _ = machine.authSucceeded()
        inputBlocker.stop()
        kiosk.disengage()
        shield.hide(success: true)   // play the unlock flourish, then tear down
        sleepGuard.end()
        intruder.postUnlockNotification()
        intruder.endSession()
        installHeldUpdateSoon()
    }

    /// Close the auth panel and return to a clean locked state. Invoked by the panel's
    /// cancel button and Escape, ⌃⌥⌘L during auth, the auth watchdog and going to sleep.
    private func panicRelock() {
        focusGuard.stop()
        authEpoch &+= 1             // supersede the in-flight attempt's result
        cancelWatchdog()
        authenticator.cancel()
        authTask?.cancel()
        guard machine.state == .authenticating else { return }
        rearmInputBlocking(afterAuth: true)
        _ = machine.authFailed()    // authenticating -> locked
        shield.dismissAuth()
    }

    /// A dead tap never ends the lock: unlocking does not depend on it (the shield's
    /// button and the password field work without it) and the shield and kiosk still
    /// hold. Failing open here would let anyone who kills the tap walk in.
    private func rearmInputBlocking(afterAuth: Bool) {
        let live = afterAuth ? inputBlocker.endAuthMode() : inputBlocker.ensureLive()
        if !live {
            NSLog("InputBlocker: tap could not be re-armed; staying locked")
        }
    }

    /// An update that became ready while locked was held back (installing
    /// relaunches the app). Install it now that the lock is gone — after a short
    /// pause so the unlock animation finishes, and only if still unlocked (a
    /// re-lock keeps it held for the next release).
    private func installHeldUpdateSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard self.machine.state == .unlocked else { return }
            self.updates?.lockDidRelease()
        }
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
        // The kiosk only holds while WE are frontmost, so losing the foreground for any
        // reason (an app calling activate, a background agent) must be undone at once.
        // No system UI legitimately needs the foreground during a lock any more: auth
        // happens in our own window.
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Runs on the main queue. Extract a Sendable scalar from the (non-Sendable)
            // NSRunningApplication here so nothing unsafe crosses into the hop below.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? -1
            MainActor.assumeIsolated {
                self?.handleAppActivated(pid: pid)
            }
        })
        // An app can enter full screen while locked, creating a Space the shield does
        // not cover: take it straight back out.
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
    }

    private func handleAppActivated(pid: pid_t) {
        guard machine.state != .unlocked else { return }
        // Ignore ourselves: taking the foreground back activates us.
        if pid == NSRunningApplication.current.processIdentifier { return }
        shield.reassert()
    }

    private func handleSpaceChange() {
        guard machine.state != .unlocked else { return }
        FullScreenExiter.exitEveryFullScreenInBackground()
        shield.reassert()
    }

    /// A session-level tap and presentation options can lapse across sleep/wake.
    /// Re-arm and re-assert if still locked.
    private func handleWake() {
        guard machine.state == .locked else { return }
        rearmInputBlocking(afterAuth: false)
        kiosk.reassert()
        shield.reassert()
    }

    /// Don't sleep mid-authentication: collapse to a clean locked state so wake
    /// resumes with the tap armed and nothing typed left in the panel.
    private func handleSleep() {
        if machine.state == .authenticating {
            panicRelock()
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
                "Leave My Mac Alone girişi engelleyebilmek için %@ iznine ihtiyaç duyar. Aşağıdaki düğmeye bas, açılan listede Leave My Mac Alone'u bul ve anahtarını aç. İzni verince otomatik tamamlanır.",
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
            "İzni verdiysen Leave My Mac Alone'u kapatıp yeniden açmayı dene, sonra menüden kilitle.",
            comment: "Permission timeout body")
        alert.addButton(withTitle: NSLocalizedString("Tamam", comment: "OK button"))
        NSApp.activate()
        alert.runModal()
    }

    private func showTapFailureAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Giriş engelleme kurulamadı", comment: "Tap failure title")
        alert.informativeText = NSLocalizedString(
            "Giriş engelleme etkinleştirilemedi, bu yüzden kilit kaldırıldı. Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik bölümünden Leave My Mac Alone'a izin verildiğinden emin ol, sonra tekrar kilitle.",
            comment: "Tap failure body")
        alert.addButton(withTitle: NSLocalizedString("Tamam", comment: "OK button"))
        NSApp.activate()
        alert.runModal()
    }
}
