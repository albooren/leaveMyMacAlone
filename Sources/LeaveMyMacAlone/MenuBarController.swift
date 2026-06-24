import AppKit
import SwiftUI
import LeaveMyMacAloneCore

struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    let onLockNow: () -> Void
    let onQuit: () -> Void

    private var opacityPercent: Int { Int((store.overlayOpacity * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Identity header.
            HStack(spacing: 11) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LeaveMyMacAlone")
                        .font(.headline)
                    Text("Ekran kilidi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Transparency control with live value and end markers.
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Saydamlık")
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
                    Slider(value: $store.overlayOpacity, in: Transparency.range)
                    Image(systemName: "moon.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                Text("Kilit ekranının koyuluğunu ayarlar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Actions: lock is the primary call to action; quit is secondary.
            VStack(spacing: 9) {
                Button(action: onLockNow) {
                    Label("Şimdi Kilitle", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onQuit) {
                    Label("Çıkış", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // How to unlock, for discoverability.
            Text("Kilitliyken: butona, Space veya Enter'a bas.")
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
    private var panel: KeyablePanel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(store: AppSettingsStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
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
            onQuit: { [weak self] in self?.closePanel(); self?.onQuit() }
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
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor); localKeyMonitor = nil }
        statusItem.button?.highlight(false)
        panel?.orderOut(nil)
        panel = nil
    }
}
