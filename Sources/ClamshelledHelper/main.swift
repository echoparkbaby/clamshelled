import Foundation
import ClamshelledShared

// Clamshelled privileged helper — a LaunchDaemon running as root, registered by the
// app via SMAppService. It exposes exactly one privileged operation over XPC:
// toggling `pmset -a disablesleep`. It cannot run arbitrary commands.
//
// Security model:
//   • The listener pins the caller's code signature (Developer ID branch, our
//     bundle ID, our team) via setConnectionCodeSigningRequirement — non-matching
//     peers are rejected BEFORE the delegate is consulted.
//   • The pmset path and argument array are fixed; the only client input is a Bool.
//   • Requests are serialised, so concurrent callers can't race pmset.
//   • The process exits when idle, so a stale root helper can't outlive an app
//     update. launchd relaunches it on demand.

/// Exits the process after a period with no requests. Without this the helper runs
/// until reboot, and replacing the app would leave the OLD root binary serving the
/// NEW app — which is both a correctness bug and a downgrade vector.
final class IdleExiter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "clamshelled.helper.idle")
    private let timeout: TimeInterval
    private var work: DispatchWorkItem?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func poke() {
        queue.async { [self] in
            work?.cancel()
            let seconds = self.timeout
            let item = DispatchWorkItem {
                NSLog("Clamshelled helper: idle for \(seconds)s, exiting")
                exit(0)
            }
            work = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }
}

let idleExiter = IdleExiter(timeout: 120)

/// Process is not Sendable; this makes the hand-off to the watchdog explicit.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

final class HelperService: NSObject, ClamshelledHelperProtocol {

    private static let pmsetPath = "/usr/bin/pmset"
    /// Serialises privileged work: two clients must not drive pmset concurrently.
    /// A lock rather than a queue, so the (non-Sendable) XPC reply block stays on
    /// the thread XPC handed it to us on.
    private let lock = NSLock()

    func setDisableSleep(_ enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        idleExiter.poke()
        lock.lock()
        let (ok, out) = Self.runPmset(enabled: enabled)
        lock.unlock()
        NSLog("Clamshelled helper: disablesleep=\(enabled ? 1 : 0) ok=\(ok)")
        reply(ok, out)
    }

    func protocolGeneration(reply: @escaping (Int) -> Void) {
        idleExiter.poke()
        reply(ClamshelledHelperInfo.protocolGeneration)
    }

    /// Fixed executable, fixed arguments — the only client input is one Bool.
    /// Bounded: a wedged pmset must not pin a root process or hang the caller.
    private static func runPmset(enabled: Bool) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pmsetPath)
        p.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (false, "Could not run pmset: \(error.localizedDescription)")
        }
        // Watchdog: kill a hung child so we always reply. Process isn't Sendable,
        // so hand it across the queue boundary in an explicit box.
        let box = ProcessBox(p)
        let killer = DispatchWorkItem {
            if box.process.isRunning {
                NSLog("Clamshelled helper: pmset timed out, terminating")
                box.process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)

        // Drain before waiting — waiting first can deadlock on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            return (false, out.isEmpty ? "pmset exited \(p.terminationStatus)" : out)
        }
        return (true, out)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClamshelledHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: ClamshelledHelperInfo.machServiceName)
listener.delegate = delegate
// Reject anything not signed by us, before the delegate is ever consulted.
// Without this, any local process could drive a root daemon.
listener.setConnectionCodeSigningRequirement(ClamshelledHelperInfo.appRequirement)
listener.resume()
idleExiter.poke()
NSLog("Clamshelled helper gen \(ClamshelledHelperInfo.protocolGeneration) listening")
dispatchMain()
