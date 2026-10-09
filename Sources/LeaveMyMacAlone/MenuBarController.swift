import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import LeaveMyMacAloneCore

// Borderless panels can't become key by default, which would leave the slider
// and buttons unresponsive. Allow it (the panel is non-activating, so this does
// not steal activation from the user's current app).
//
// The SwiftUI content grows and shrinks (custom-message field, return stepper,
// image row), and the hosting view resizes the window to fit. Pin the top edge
// so it always hangs from the menu bar instead of growing up into it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var anchorTop: CGFloat?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let top = anchorTop { rect.origin.y = top - rect.height }
        super.setFrame(rect, display: flag)
    }
}

@MainActor
final class MenuBarController {

    var onLockNow: () -> Void = {}
    var onQuit: () -> Void = {}

    private let store: AppSettingsStore
    private let updates: UpdateController
    private let statusItem: NSStatusItem
    private let preview: PreviewOverlayController
    private var panel: KeyablePanel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(store: AppSettingsStore, updates: UpdateController) {
        self.store = store
        self.updates = updates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.preview = PreviewOverlayController(store: store)
        configureStatusButton()
    }

    /// When the user enables intruder capture, request Camera permission now (a
    /// calm moment) so the prompt never appears mid-intrusion. For an accessory
    /// (menu-bar) app the TCC prompt only surfaces if we are the active app, so
    /// activate first. If the user previously denied camera, the system won't
    /// re-prompt — guide them to the Camera Settings pane instead.
    private func primeIntruderPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .denied, .restricted:
            showCameraDeniedAlert()
        @unknown default:
            break
        }
        // Notifications power the unlock summary; independent of camera state.
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Camera was previously denied; the system won't re-prompt. Offer to open the
    /// Camera privacy pane so the user can enable it manually.
    private func showCameraDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Kamera izni gerekli",
                                              comment: "Camera denied title")
        alert.informativeText = NSLocalizedString(
            "İzinsiz giriş fotoğrafı çekebilmek için Kamera izni gerekiyor. Sistem Ayarları > Gizlilik ve Güvenlik > Kamera bölümünde LeaveMyMacAlone uygulamasına izin ver.",
            comment: "Camera denied body")
        alert.addButton(withTitle: NSLocalizedString("Kamera Ayarlarını Aç",
                                                     comment: "Open camera settings button"))
        alert.addButton(withTitle: NSLocalizedString("İptal", comment: "Cancel button"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "lock.shield",
                               accessibilityDescription: "LeaveMyMacAlone")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePanel(_:))
    }

    @objc
    private func togglePanel(_ sender: Any?) {
        if panel == nil { openPanel() } else { closePanel() }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        let root = SettingsView(
            store: store,
            updates: updates,
            onLockNow: { [weak self] in self?.closePanel(); self?.onLockNow() },
            onQuit: { [weak self] in self?.closePanel(); self?.onQuit() },
            onSliderEditing: { [weak self] editing in
                // Show the live preview only while the slider is being dragged.
                if editing { self?.preview.start() } else { self?.preview.stop() }
            },
            onCaptureIntruderEnabled: { [weak self] in self?.primeIntruderPermissions() },
            onOpenIntruderPhotos: { IntruderCapture.openPhotosFolder() },
            onCheckForUpdates: { [weak self] in
                self?.closePanel()
                self?.updates.checkForUpdates()
            },
            onChooseImage: { [weak self] in self?.chooseFloatingImage() }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // Flush under the menu bar: top edge at the status item's bottom (= menu
        // bar bottom), left-aligned to the icon and clamped onto the screen. No
        // arrow, no gap.
        let buttonScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? .zero
        var x = buttonScreen.minX
        x = min(x, visible.maxX - size.width - 8)
        x = max(x, visible.minX + 8)
        panel.anchorTop = buttonScreen.minY
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonScreen.minY))

        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        self.panel = panel
        installDismissMonitors()
        // Preview is NOT shown on open; it appears only while the slider is
        // dragged (see SettingsView onSliderEditing). closePanel() stops it as a
        // safety net if the panel closes mid-drag.
    }

    /// The open panel can't sit above our popUpMenu-level panel, so close the
    /// panel, run the picker, then reopen it to show the result.
    private func chooseFloatingImage() {
        closePanel()
        if let name = FloatingImageStore.chooseAndImport() {
            store.floatingImageName = name
            store.floatingKind = .image
        }
        openPanel()
    }

    private func installDismissMonitors() {
        // A click that lands in another process (desktop, another app, or the
        // status item) — dismiss, unless it is on our status item, where the
        // button action toggles us closed instead (avoids a double toggle).
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let frame = self.statusButtonScreenFrame(),
                   frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.closePanel()
            }
        }
        // Escape closes the panel.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            MainActor.assumeIsolated { self?.closePanel() }
            return nil
        }
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func closePanel() {
        preview.stop()           // revert the screen to normal
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor); localKeyMonitor = nil }
        statusItem.button?.highlight(false)
        panel?.orderOut(nil)
        panel = nil
    }
}
