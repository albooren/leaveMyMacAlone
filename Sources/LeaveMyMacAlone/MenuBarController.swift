import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import LeaveMyMacAloneCore

// Round icon button for the panel actions. `prominent` = filled white circle
// with a dark glyph (primary action); otherwise a frosted circle with a white
// glyph (secondary). Avoids the system accent (blue) to match the dark panel.
private struct CircleIconButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
            .frame(width: 52, height: 52)
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial),
                        in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(prominent ? 0 : 0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    let onLockNow: () -> Void
    let onQuit: () -> Void
    // true while the user is dragging the opacity slider; drives the live preview.
    let onSliderEditing: (Bool) -> Void
    // Called when the user turns the intruder-capture toggle ON (prime perms).
    let onCaptureIntruderEnabled: () -> Void
    // Open the captured-photos folder in Finder.
    let onOpenIntruderPhotos: () -> Void

    private var opacityPercent: Int { Int((store.overlayOpacity * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Identity header (centered: app icon + name).
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("LeaveMyMacAlone")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // Transparency control with live value and end markers.
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Koyuluk")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(opacityPercent)%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    Image(systemName: "sun.min.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Slider(value: $store.overlayOpacity, in: Transparency.range,
                           onEditingChanged: onSliderEditing)
                    Image(systemName: "moon.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                Text("Kilit ekranının koyuluğunu ayarlar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Whether to keep the Mac awake while it is locked. Lay it out as a
            // settings row: label on the leading edge, switch pinned trailing.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kilitliyken uykuyu engelle")
                        .font(.subheadline.weight(.semibold))
                    Text("Kapatırsan Mac kilitliyken uykuya geçebilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $store.preventSleepWhileLocked)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            // Intruder capture: toggle + (when on) a shortcut to the photos folder.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("İzinsiz girişte fotoğraf çek")
                            .font(.subheadline.weight(.semibold))
                        Text("Kilidi açmaya çalışan kişinin ön kameradan fotoğrafını çeker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $store.captureIntruderPhoto)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if store.captureIntruderPhoto {
                    Button("İzinsiz giriş fotoğraflarını aç", action: onOpenIntruderPhotos)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .onChange(of: store.captureIntruderPhoto) { _, newValue in
                if newValue { onCaptureIntruderEnabled() }
            }

            Divider()

            // Actions: round icon buttons side by side — lock (primary, filled)
            // and quit (secondary, frosted).
            HStack(spacing: 20) {
                Button(action: onLockNow) {
                    Image(systemName: "lock.fill")
                }
                .buttonStyle(CircleIconButtonStyle(prominent: true))
                .help("Şimdi Kilitle")

                Button(action: onQuit) {
                    Image(systemName: "power")
                }
                .buttonStyle(CircleIconButtonStyle(prominent: false))
                .help("Çıkış")
            }
            .frame(maxWidth: .infinity)

            // How to unlock, for discoverability.
            Text("Açmak için butona, Space veya Enter'a bas.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        .frame(width: 280)
        // The panel window is borderless/clear, so the card draws its own frosted
        // background + rounded corners (matches a native menu-bar dropdown).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// Borderless panels can't become key by default, which would leave the slider
// and buttons unresponsive. Allow it (the panel is non-activating, so this does
// not steal activation from the user's current app).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarController {

    var onLockNow: () -> Void = {}
    var onQuit: () -> Void = {}

    private let store: AppSettingsStore
    private let statusItem: NSStatusItem
    private let preview: PreviewOverlayController
    private var panel: KeyablePanel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(store: AppSettingsStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.preview = PreviewOverlayController(store: store)
        configureStatusButton()
    }

    /// When the user enables intruder capture, request Camera + Notification
    /// permission now (a calm moment) so the prompts never appear mid-intrusion.
    private func primeIntruderPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
            onLockNow: { [weak self] in self?.closePanel(); self?.onLockNow() },
            onQuit: { [weak self] in self?.closePanel(); self?.onQuit() },
            onSliderEditing: { [weak self] editing in
                // Show the live preview only while the slider is being dragged.
                if editing { self?.preview.start() } else { self?.preview.stop() }
            },
            onCaptureIntruderEnabled: { [weak self] in self?.primeIntruderPermissions() },
            onOpenIntruderPhotos: { IntruderCapture.openPhotosFolder() }
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
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonScreen.minY))

        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        self.panel = panel
        installDismissMonitors()
        // Preview is NOT shown on open; it appears only while the slider is
        // dragged (see SettingsView onSliderEditing). closePanel() stops it as a
        // safety net if the panel closes mid-drag.
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
