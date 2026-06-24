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
        // by the event tap, so it stays live as a re-lock affordance. lock() is a
        // no-op unless state == .unlocked (the machine guard), so pressing it
        // during authenticating/locked is safely ignored.
        hotKey = GlobalHotKey(onPressed: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        })

        store.onOpacityChange = { [weak self] opacity in
            guard let self else { return }
            Task { @MainActor in self.shield.setOpacity(opacity) }
        }

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
        shield.show(opacity: store.overlayOpacity)
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

    private func requestUnlock() {
        guard machine.beginAuth() else { return }
        // Stop consuming so the password fallback can be typed in the sheet.
        inputBlocker.pause()
        Task { @MainActor in
            let ok = await authenticator.authenticate(
                reason: "Mac'in kilidini açmak için kimliğini doğrula")
            if ok {
                _ = machine.authSucceeded()
                inputBlocker.stop()
                kiosk.disengage()
                shield.hide()
                sleepGuard.end()
            } else {
                if inputBlocker.resume() {
                    _ = machine.authFailed()      // re-armed; stay locked
                } else {
                    // Tap could not be re-armed — fail safe to unlocked rather
                    // than strand the user behind a non-consuming lock.
                    _ = machine.authSucceeded()   // authenticating -> unlocked
                    inputBlocker.stop()
                    kiosk.disengage()
                    shield.hide()
                    sleepGuard.end()
                    showTapFailureAlert()
                }
            }
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
