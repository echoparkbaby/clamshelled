import Foundation
import ServiceManagement
import ClamshelledShared

/// Guards a continuation so it resumes exactly once. An XPC call can complete via
/// the reply block, the error handler, *or* our timeout — resuming twice would trap.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func fire(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Everything the app knows about its privileged helper.
///
/// All calls are asynchronous with a bounded timeout: a wedged helper must never
/// freeze the menu bar, and must never make the app unquittable.
@MainActor
enum HelperClient {

    static let callTimeout: Duration = .seconds(10)

    static var service: SMAppService {
        SMAppService.daemon(plistName: ClamshelledHelperInfo.daemonPlistName)
    }
    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    /// A LaunchDaemon's BundleProgram resolves *inside* this bundle, so registering
    /// from a disk image, a translocated copy, or a folder the user might move
    /// leaves a daemon pointing at a path that can vanish or be swapped.
    static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            && !path.contains("AppTranslocation")
    }

    // MARK: - Privileged calls

    private static func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: ClamshelledHelperInfo.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ClamshelledHelperProtocol.self)
        // Pin the helper's signature so we can't be steered to an impostor.
        conn.setCodeSigningRequirement(ClamshelledHelperInfo.helperRequirement)
        return conn
    }

    /// Asks the helper to flip `pmset -a disablesleep`.
    static func setDisableSleep(_ on: Bool) async -> (ok: Bool, output: String) {
        let conn = makeConnection()
        conn.resume()
        defer { conn.invalidate() }

        let result: (Bool, String) = await withCheckedContinuation { continuation in
            let shot = OneShot(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                shot.fire((false, error.localizedDescription))
            } as? ClamshelledHelperProtocol

            guard let proxy else {
                shot.fire((false, "Couldn’t reach the privileged helper."))
                return
            }
            proxy.setDisableSleep(on) { ok, out in shot.fire((ok, out)) }

            Task {
                try? await Task.sleep(for: callTimeout)
                shot.fire((false, "The privileged helper didn’t respond in time."))
            }
        }
        return (ok: result.0, output: result.1)
    }

    /// Generation of the *running* helper — nil if it can't be reached.
    static func runningGeneration() async -> Int? {
        let conn = makeConnection()
        conn.resume()
        defer { conn.invalidate() }

        return await withCheckedContinuation { continuation in
            let shot = OneShot<Int?>(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                shot.fire(nil)
            } as? ClamshelledHelperProtocol

            guard let proxy else { shot.fire(nil); return }
            proxy.protocolGeneration { shot.fire($0) }

            Task {
                try? await Task.sleep(for: callTimeout)
                shot.fire(nil)
            }
        }
    }

    // MARK: - Registration

    static func register() throws {
        try service.register()
    }

    /// Unregister and wait for launchd to confirm — registering again before the old
    /// job is gone is exactly how a stale root helper survives an update.
    static func unregister() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedThrowingContinuation) in
            service.unregister { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    /// Replacing the app does NOT restart an already-running helper, so an old root
    /// binary can keep serving a new app. Detect that and cycle the registration.
    /// Returns true if a re-registration was performed.
    @discardableResult
    static func reregisterIfStale() async -> Bool {
        guard isEnabled else { return false }
        let running = await runningGeneration()
        // Reachable and current → nothing to do. Unreachable (nil) is also worth a
        // cycle: the registration exists but nothing is answering on it.
        if running == ClamshelledHelperInfo.protocolGeneration { return false }

        NSLog("Clamshelled: helper generation \(running.map(String.init) ?? "unreachable") "
              + "≠ \(ClamshelledHelperInfo.protocolGeneration) — re-registering")
        do {
            try await unregister()
            try await Task.sleep(for: .milliseconds(500)) // let launchd reap the old job
            try register()
            return true
        } catch {
            NSLog("Clamshelled: helper re-registration failed: \(error.localizedDescription)")
            return false
        }
    }
}

private typealias CheckedThrowingContinuation = CheckedContinuation<Void, Error>
