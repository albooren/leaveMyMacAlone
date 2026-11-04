// Helper: behaves like Raycast/Alfred. A global hot key (Ctrl+Opt+Cmd+K) toggles a non-activating
// panel with a text field, so it can take keystrokes without becoming the active app.
// That is the shape a launcher has, and a launcher can run shell commands.
import AppKit
import Carbon.HIToolbox

DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(0) }

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = KeyPanel(contentRect: NSRect(x: 300, y: 300, width: 300, height: 40),
                     styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
panel.title = "LMMA launcher helper"
panel.isReleasedWhenClosed = false
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 284, height: 24))
panel.contentView?.addSubview(field)

func toggle() {
    if panel.isVisible {
        panel.orderOut(nil)
    } else {
        field.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }
}

// SIGUSR1 opens the panel with no hot key, as a mouse button or a gesture could.
signal(SIGUSR1, SIG_IGN)
let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
signalSource.setEventHandler { toggle() }
signalSource.resume()

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    DispatchQueue.main.async { toggle() }
    return noErr
}, 1, &spec, nil, nil)
var ref: EventHotKeyRef?
RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey),
                    EventHotKeyID(signature: OSType(0x4C4E4348), id: 1),
                    GetApplicationEventTarget(), 0, &ref)
app.run()
