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

        // First run cannot auto-lock: granting Accessibility/Input Monitoring
        // requires reaching System Settings, which a kiosk lock would hide.
        if InputBlocker.hasRequiredPermissions() {
            lock()
        } else {
            InputBlocker.requestPermissions()
            showPermissionsAlert()
        }
    }

    func lock() {
        guard machine.lock() else { return } // ignore if not unlocked
        sleepGuard.begin()
        // The shield click is a tap-independent recovery affordance (see
        // handleShieldInteraction): it works even when the event tap is paused
        // (during auth) or dead, so a covering window can never strand the user.
        shield.show(opacity: store.overlayOpacity, onInteract: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.handleShieldInteraction() }
        })
        kiosk.engage()
        let live = inputBlocker.start(onFirstInteraction: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.requestUnlock() }
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

    // A click on any shield window. In `.locked` the consuming tap intercepts
    // input before it reaches the window, so this fires only when the tap is NOT
    // consuming — precisely the states where a recovery path is required.
    private func handleShieldInteraction() {
        switch machine.state {
        case .locked:
            requestUnlock()
        case .authenticating:
            // The in-flight auth sheet was lost behind the shield / made
            // unreachable; bring a fresh one to the front instead of stranding.
            startAuth()
        case .unlocked:
            break
        }
    }

    private func requestUnlock() {
        guard machine.beginAuth() else { return }
        // Keep the tap live but in auth mode: it stops consuming plain input
        // (so the password sheet is usable) while still swallowing app/space
        // switching and launcher shortcuts that would let a passer-by escape.
        inputBlocker.beginAuthMode()
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
            shield.hide()
            sleepGuard.end()
        } else if inputBlocker.endAuthMode() {
            _ = machine.authFailed()          // re-armed; stay locked
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

    private func showPermissionsAlert() {
        let alert = NSAlert()
        alert.messageText = "İzin gerekli"
        alert.informativeText = """
        LeaveMyMacAlone girişi engelleyebilmek için iki izne ihtiyaç duyar. \
        Sistem Ayarları > Gizlilik ve Güvenlik bölümünden:
        • Erişilebilirlik (Accessibility)
        • Giriş İzleme (Input Monitoring)
        izinlerini ver. Sonra menü çubuğundaki kalkan simgesinden \
        "Şimdi Kilitle" ile kilitle.
        """
        alert.addButton(withTitle: "Sistem Ayarları'nı Aç")
        alert.addButton(withTitle: "Tamam")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showTapFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Giriş engelleme kurulamadı"
        alert.informativeText = """
        Giriş engelleme (event tap) etkinleştirilemedi, bu yüzden kilit \
        kaldırıldı. Sistem Ayarları > Gizlilik ve Güvenlik bölümünden \
        Erişilebilirlik ve Giriş İzleme izinlerinin verildiğinden emin ol, \
        sonra tekrar kilitle.
        """
        alert.addButton(withTitle: "Tamam")
        NSApp.activate()
        alert.runModal()
    }
}
