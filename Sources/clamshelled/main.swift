import AppKit
import ServiceManagement
import ClamshelledShared

// Entry point. Everything else lives in AppController / HelperClient / SleepState.

let args = CommandLine.arguments

if args.contains("--self-test") { runSelfTest() }

// Headless helper management — used for testing and scripted/MDM deployment.
// Exits non-zero on failure so callers can actually detect it.
if args.contains("--helper-status") || args.contains("--install-helper")
    || args.contains("--uninstall-helper") {

    let service = SMAppService.daemon(plistName: ClamshelledHelperInfo.daemonPlistName)
    func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          "enabled"
        case .requiresApproval: "requires-approval"
        case .notRegistered:    "not-registered"
        case .notFound:         "not-found"
        @unknown default:       "unknown"
        }
    }
    // Run the work as a main-actor task and pump the run loop, rather than blocking
    // on a semaphore. Blocking here would deadlock: HelperClient is @MainActor, so a
    // main-thread wait would stop the very actor the work needs to run on.
    Task {
        var failed = false

        if args.contains("--install-helper") {
            let path = Bundle.main.bundlePath
            if !path.hasPrefix("/Applications/") || path.contains("AppTranslocation") {
                print("register: REFUSED — a LaunchDaemon must be registered from /Applications, not \(path)")
                failed = true
            } else {
                do { try HelperClient.register(); print("register: ok") }
                catch { print("register: FAILED — \(error.localizedDescription)"); failed = true }
            }
        }
        if args.contains("--uninstall-helper") {
            // Refuse to strand the Mac awake with no way to undo it.
            if readDisableSleep() ?? true {
                print("unregister: REFUSED — sleep is currently disabled; turn it off first")
                failed = true
            } else {
                do { try await HelperClient.unregister(); print("unregister: ok") }
                catch { print("unregister: FAILED — \(error.localizedDescription)"); failed = true }
            }
        }
        print("helper status: \(describe(service.status))")
        exit(failed ? 1 : 0)
    }
    RunLoop.main.run()   // the Task above always exits
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
