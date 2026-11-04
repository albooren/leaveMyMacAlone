import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    // Cancelling also blocks a logout or restart while locked. That is deliberate:
    // otherwise another app could veto the logout after we had already quit, leaving
    // the Mac open. Unlock first, or hold the power button.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.allowsTermination ? .terminateNow : .terminateCancel
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
