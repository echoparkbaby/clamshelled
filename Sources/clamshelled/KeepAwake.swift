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
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Clamshelled — Keep Me Awake" as CFString,
            &id)
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }
}
