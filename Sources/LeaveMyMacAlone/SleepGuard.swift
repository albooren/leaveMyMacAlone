import Foundation
import IOKit.pwr_mgt

/// Holds IOKit power assertions to keep the display awake and prevent idle
/// system sleep while the overlay is shown / a background task runs.
///
/// LIMITATION: assertions only block *idle* sleep. They do NOT prevent
/// lid-close (clamshell) sleep on a bare laptop, Apple menu > Sleep, low
/// battery, or thermal sleep.
final class SleepGuard {

    private var displayAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var systemAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var displayHeld = false
    private var systemHeld = false

    private let reason = "Showing lock overlay while a background task runs" as CFString

    /// Acquire both assertions. Safe to call repeatedly (no-op if already held).
    func begin() {
        let level = IOPMAssertionLevel(kIOPMAssertionLevelOn) // 255

        // Keeps the screen ON; per IOPMLib.h this also prevents idle system sleep.
        if !displayHeld {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                level,
                reason,
                &id)
            if rc == kIOReturnSuccess {
                displayAssertionID = id
                displayHeld = true
            } else {
                NSLog("SleepGuard: display assertion failed: \(String(format: "0x%08x", rc))")
            }
        }

        // Explicit idle-system-sleep assertion (belt-and-suspenders).
        if !systemHeld {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                level,
                reason,
                &id)
            if rc == kIOReturnSuccess {
                systemAssertionID = id
                systemHeld = true
            } else {
                NSLog("SleepGuard: system assertion failed: \(String(format: "0x%08x", rc))")
            }
        }
    }

    /// Release both assertions. Safe to call repeatedly.
    func end() {
        if displayHeld {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = IOPMAssertionID(0)
            displayHeld = false
        }
        if systemHeld {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = IOPMAssertionID(0)
            systemHeld = false
        }
    }

    deinit { end() }
}
