import AppKit

// Minimal bootstrap so the executable target compiles.
// Replaced by the real AppDelegate/AppController bootstrap in Task 12.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
