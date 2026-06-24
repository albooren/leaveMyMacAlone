import AppKit
import SwiftUI
import LeaveMyMacAloneCore

struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    let onLockNow: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saydamlık")
                .font(.headline)

            Slider(value: $store.overlayOpacity, in: Transparency.range)

            Text(String(format: "Opaklık: %.0f%%", store.overlayOpacity * 100))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("Şimdi Kilitle", action: onLockNow)
            Button("Çıkış", action: onQuit)
        }
        .padding(20)
        .frame(width: 260)
    }
}

@MainActor
final class MenuBarController {

    var onLockNow: () -> Void = {}
    var onQuit: () -> Void = {}

    private let store: AppSettingsStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: AppSettingsStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        configureStatusButton()
        configurePopover()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "lock.shield",
                               accessibilityDescription: "LeaveMyMacAlone")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let root = SettingsView(
            store: store,
            onLockNow: { [weak self] in self?.onLockNow() },
            onQuit: { [weak self] in self?.onQuit() }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
