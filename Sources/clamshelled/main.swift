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
    var failed = false

    if args.contains("--install-helper") {
        let path = Bundle.main.bundlePath
        if !path.hasPrefix("/Applications/") || path.contains("AppTranslocation") {
            print("register: REFUSED — a LaunchDaemon must be registered from /Applications, not \(path)")
            failed = true
        } else {
            do { try service.register(); print("register: ok") }
            catch { print("register: FAILED — \(error.localizedDescription)"); failed = true }
        }
    }
    if args.contains("--uninstall-helper") {
        // Refuse to strand the Mac awake with no way to undo it.
        if readDisableSleep() ?? true {
            print("unregister: REFUSED — sleep is currently disabled; turn it off first")
            failed = true
        } else {
            final class ErrorBox: @unchecked Sendable { var error: Error?; var done = false }
            let box = ErrorBox()
            let sema = DispatchSemaphore(value: 0)
            service.unregister { error in
                box.error = error
                box.done = true
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 30)
            if !box.done {
                print("unregister: FAILED — timed out waiting for launchd")
                failed = true
            } else if let error = box.error {
                print("unregister: FAILED — \(error.localizedDescription)")
                failed = true
            } else {
                print("unregister: ok")
            }
        }
    }
    print("helper status: \(describe(service.status))")
    exit(failed ? 1 : 0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()
