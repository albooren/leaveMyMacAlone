// Helper: a plain app that puts one empty window into native full screen, standing
// in for "the owner left another app in a full-screen Space". Exits by itself.
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
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    app.activate(ignoringOtherApps: true)
    window.toggleFullScreen(nil)
}
app.run()
