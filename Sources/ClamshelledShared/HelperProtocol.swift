import Foundation

/// Names and code-signing requirements shared by the app and its privileged helper.
public enum ClamshelledHelperInfo {
    /// Mach service the root helper vends (must match MachServices in the plist).
    public static let machServiceName = "com.brandon.clamshelled.helper"
    /// LaunchDaemon plist embedded at Contents/Library/LaunchDaemons/.
    public static let daemonPlistName = "com.brandon.clamshelled.helper.plist"

    public static let appIdentifier    = "com.brandon.clamshelled"
    public static let helperIdentifier = "com.brandon.clamshelled.helper"
    public static let teamIdentifier   = "AQ5XNNSVN7"

    /// Bumped whenever the helper's behaviour or security posture changes. The app
    /// compares this against the running helper and forces a re-registration on a
    /// mismatch — otherwise a stale root helper from an older build keeps serving
    /// the new app (launchd will not swap it out on its own).
    public static let protocolGeneration = 2

    /// The helper runs as ROOT, so callers must be pinned. Requiring only
    /// `anchor apple generic` + Team OU would also accept *development*-signed
    /// builds from the same team; the two certificate-field checks below narrow it
    /// to the Developer ID branch specifically.
    ///   1.2.840.113635.100.6.2.6  → Developer ID intermediate CA
    ///   1.2.840.113635.100.6.1.13 → Developer ID Application leaf
    /// Deliberately NOT pinned to a leaf hash or CDHash: that would break
    /// legitimate updates and certificate renewal.
    private static func developerIDRequirement(identifier: String) -> String {
        """
        anchor apple generic \
        and identifier "\(identifier)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
    }

    /// Enforced by the helper's listener on incoming connections.
    public static var appRequirement: String {
        developerIDRequirement(identifier: appIdentifier)
    }
    /// Enforced by the app on its connection, so it can't be steered to an impostor.
    public static var helperRequirement: String {
        developerIDRequirement(identifier: helperIdentifier)
    }
}

/// The entire privileged surface. Deliberately minimal — the helper is root, so
/// every method is attack surface. It cannot run arbitrary commands.
@objc public protocol ClamshelledHelperProtocol {
    /// Sets `pmset -a disablesleep`. Replies with success + any output.
    func setDisableSleep(_ enabled: Bool, reply: @escaping (Bool, String) -> Void)
    /// Generation of the *running* helper, so the app can detect a stale one.
    func protocolGeneration(reply: @escaping (Int) -> Void)
}
