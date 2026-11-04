// Helper: a plain app that puts one empty window into native full screen, standing
// in for "the owner left another app in a full-screen Space". Exits by itself.
// Reports its real state through the file in LMMA_FSAPP_STATE: the accessibility API
// can't see windows on another Space, so it isn't a reliable witness.
import AppKit

DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 320),
                      styleMask: [.titled, .resizable, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "LMMA full-screen helper"
window.collectionBehavior = [.fullScreenPrimary]
window.isReleasedWhenClosed = false
window.makeKeyAndOrderFront(nil)
if let statePath = ProcessInfo.processInfo.environment["LMMA_FSAPP_STATE"] {
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        try? (window.styleMask.contains(.fullScreen) ? "1" : "0")
            .write(toFile: statePath, atomically: true, encoding: .utf8)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    app.activate(ignoringOtherApps: true)
    window.toggleFullScreen(nil)
}
app.run()
