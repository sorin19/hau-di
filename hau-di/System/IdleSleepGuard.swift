import Foundation
import IOKit.pwr_mgt

/// While recording, the Mac doesn't start the screensaver or turn off the display (like a video player).
/// A key held down doesn't count as activity: without this, after the interval set in the system settings
/// the screensaver would start in the middle of the dictation. The user's settings stay untouched; when the keys are
/// released (a keyboard event), the screensaver countdown starts over from zero, as after any key press.
@MainActor
final class IdleSleepGuard {
    private var assertion: IOPMAssertionID = 0
    private var active = false

    func begin() {
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "hau-di: dictation in progress" as CFString,
                                                 &assertion)
        active = result == kIOReturnSuccess
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertion)
        active = false
    }
}
