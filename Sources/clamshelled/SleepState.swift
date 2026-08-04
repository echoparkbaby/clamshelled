import Foundation

/// Parses `pmset -g` output for the SleepDisabled flag.
/// Returns true/false for an exact `SleepDisabled 0|1` line, or nil when the key
/// is absent or the value isn't recognised. Matching whole tokens matters: the
/// same output also contains an unrelated `sleep 1 (...)` line.
func parseSleepDisabled(_ output: String) -> Bool? {
    for line in output.split(separator: "\n") {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2, tokens[0] == "SleepDisabled" else { continue }
        switch tokens[1] {
        case "1": return true
        case "0": return false
        default:  return nil   // unrecognised value — don't guess
        }
    }
    return nil // key absent — caller decides (macOS omits it when unset)
}

/// Runs pmset and returns its output. nil = couldn't launch or exited non-zero.
func runPmset(_ arguments: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return nil
    }
    // Drain before waiting — waiting first can deadlock on a full pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    // Lossy on purpose. pmset's output is not guaranteed valid UTF-8 — it mangles
    // non-ASCII in assertion names — and a strict decode returns nil for the WHOLE
    // blob over one bad byte, which silently looks like "pmset told us nothing".
    return String(decoding: data, as: UTF8.self)
}

/// Reads the live SleepDisabled value. Unprivileged — no helper needed.
/// nil = couldn't determine (pmset failed / unrecognised output) — NOT "off".
func readDisableSleep() -> Bool? {
    guard let output = runPmset(["-g"]) else { return nil }
    return parseSleepDisabled(output)
}

/// `--self-test`: runnable checks for the parser and the Keep Me Awake assertion.
/// Run with:
///   Clamshelled.app/Contents/MacOS/clamshelled --self-test
/// Uses `precondition`, not `assert` — assertions are compiled out in release, so
/// an assert-based check would pass vacuously in the shipped binary.
@MainActor
func runSelfTest() -> Never {
    let real = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standbydelayhigh     86400
     sleep                1 (sleep prevented by coreaudiod)
     hibernatemode        3
    """
    precondition(parseSleepDisabled(real) == false, "must not be fooled by the later 'sleep 1' line")
    precondition(parseSleepDisabled(" SleepDisabled\t\t1") == true)
    precondition(parseSleepDisabled(" SleepDisabled 0") == false)
    precondition(parseSleepDisabled("Currently in use:\n sleep 1") == nil, "key absent → unknown")
    precondition(parseSleepDisabled("") == nil, "empty (pmset failed) → unknown, never 'off'")
    precondition(parseSleepDisabled(" SleepDisabled banana") == nil, "unparseable → unknown")
    precondition(parseSleepDisabled("SleepDisabledExtra 1") == nil, "prefix must not match")
    print("✓ parseSleepDisabled: all checks passed")

    // Real round trip against IOKit — catches bad assertion arguments.
    precondition(KeepAwake.isOn == false, "starts off")
    precondition(KeepAwake.set(true), "IOKit refused the assertion")
    precondition(KeepAwake.isOn, "should report on")

    // Ask the system what it thinks we asserted. This is the check that matters:
    // "create succeeded" says nothing about WHICH sleep got prevented, and
    // PreventUserIdleSystemSleep keeps the machine awake while letting the screen
    // go dark — which shipped once and is not what "Keep Me Awake" means.
    let assertions = runPmset(["-g", "assertions"]) ?? ""
    let ours = assertions.split(separator: "\n").filter { $0.contains(KeepAwake.assertionName) }
    precondition(!ours.isEmpty, "system doesn't list our assertion at all:\n\(assertions)")
    precondition(ours.contains { $0.contains("PreventUserIdleDisplaySleep") },
                 "assertion does not prevent DISPLAY sleep — the screen will still go dark:\n\(ours.joined(separator: "\n"))")

    precondition(KeepAwake.set(true), "re-enabling is a no-op, not an error")
    precondition(KeepAwake.set(false), "release failed")
    precondition(KeepAwake.isOn == false, "should report off")
    precondition(!(runPmset(["-g", "assertions"]) ?? "").contains(KeepAwake.assertionName),
                 "assertion outlived its release")
    print("✓ KeepAwake: holds a display-sleep assertion, and releases it")
    exit(0)
}
