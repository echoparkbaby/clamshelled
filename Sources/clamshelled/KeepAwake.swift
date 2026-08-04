import IOKit.pwr_mgt

/// "Keep Me Awake" — stops idle sleep while Clamshelled is running.
///
/// This is a power assertion, the same mechanism `/usr/bin/caffeinate` uses. It
/// needs no root and no helper, and the kernel drops it when this process exits —
/// so unlike `disablesleep` it can't strand the Mac awake after a quit or a crash.
/// It also does NOT survive closing the lid: that still needs the clamshell toggle.
@MainActor
enum KeepAwake {
    private static var assertionID: IOPMAssertionID = 0

    /// Also how `pmset -g assertions` labels us, which the self-test greps for.
    /// Plain ASCII on purpose — pmset mangles non-ASCII in that listing.
    static let assertionName = "Clamshelled: Keep Me Awake"

    static var isOn: Bool { assertionID != 0 }

    /// Returns false if the assertion couldn't be created — the caller reports it
    /// rather than silently showing a checkmark for something that isn't happening.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard on != isOn else { return true }
        guard on else {
            let ok = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
            assertionID = 0   // never retry a released ID, even if the release failed
            return ok
        }
        var id: IOPMAssertionID = 0
        // Display sleep, NOT system sleep. PreventUserIdleSystemSleep keeps the
        // machine running but explicitly lets the screen go dark, which is not what
        // anyone means by "Keep Me Awake". Preventing display sleep covers both:
        // powerd holds its own "prevent sleep while display is on" assertion.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionName as CFString,
            &id)
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }
}
