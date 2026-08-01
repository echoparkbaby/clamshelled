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

/// Reads the live SleepDisabled value. Unprivileged — no helper needed.
/// nil = couldn't determine (pmset failed / unrecognised output) — NOT "off".
func readDisableSleep() -> Bool? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
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
    return parseSleepDisabled(String(data: data, encoding: .utf8) ?? "")
}

/// `--self-test`: runnable check for the parser. Run with:
///   Clamshelled.app/Contents/MacOS/clamshelled --self-test
/// Uses `precondition`, not `assert` — assertions are compiled out in release, so
/// an assert-based check would pass vacuously in the shipped binary.
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
    exit(0)
}
