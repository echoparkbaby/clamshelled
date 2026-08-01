import AppKit
import ServiceManagement
import ClamshelledShared

// Clamshelled — a menu-bar app that toggles clamshell (lid-closed) sleep on a Mac.
//
// ON  = `pmset -a disablesleep 1`  → Mac stays awake with the lid closed.
// OFF = `pmset -a disablesleep 0`  → normal behaviour restored.
//
// Reading state is unprivileged. WRITING goes through ClamshelledHelper, a root
// LaunchDaemon registered with SMAppService and reached over XPC — macOS shows its
// own approval UI, so there's no sudoers file and no Terminal step. Both ends pin
// each other's Developer ID signature (see ClamshelledShared/HelperProtocol.swift).

@MainActor
final class AppController: NSObject, NSApplicationDelegate {

    /// Human-facing version. CFBundleShortVersionString must stay numeric for
    /// Apple, so the RC label rides along in a separate key.
    static var displayVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["ClamshelledDisplayVersion"] as? String)
            ?? (info?["CFBundleShortVersionString"] as? String)
            ?? "?"
    }

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    /// true → sleep is disabled (Mac stays awake when the lid closes).
    private var isEnabled = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        refreshState()
        // Reflect changes made elsewhere (e.g. someone runs pmset in a terminal).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
        // An app update leaves the OLD root helper running; swap it out.
        Task { await HelperClient.reregisterIfStale() }
    }

    // MARK: - State

    private func refreshState() {
        // Unknown state keeps the last known value rather than falsely showing "off".
        if let state = readDisableSleep() { isEnabled = state }
        updateIcon()
        updateMenu()
    }

    // MARK: - Actions

    @objc private func toggle() {
        guard HelperClient.isEnabled else {
            presentHelperProblem(detail: "")
            return
        }
        let target = !isEnabled
        Task {
            let result = await HelperClient.setDisableSleep(target)
            if !result.ok { presentHelperProblem(detail: result.output) }
            refreshState()
        }
    }

    @objc private func toggleLoginItem() {
        // Launch at Login can't work from a mounted DMG or a translocated copy —
        // macOS randomizes the path, so there's nothing stable to register.
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") || path.contains("AppTranslocation") {
            presentMoveToApplications(reason: "start automatically at login")
            return
        }
        // macOS may accept the registration but park it behind a user approval —
        // clicking again just errors, so send them where the switch actually is.
        if SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "Approve Clamshelled in Login Items"
            alert.informativeText = """
            macOS needs your OK before Clamshelled can start automatically.

            Turn on “Clamshelled” under Login Items in System Settings.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
            updateMenu()
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Clamshelled: login-item change failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nIf Clamshelled isn’t in your Applications folder, move it there and try again."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Clamshelled \(Self.displayVersion)"
        alert.informativeText = """
        Keeps your Mac awake while the lid is closed — no external display or \
        charger required.

        Turn it on before you shut the lid; turn it off when you’re done. The \
        menu-bar icon shows a closed MacBook while it’s active, an open one when \
        your Mac sleeps normally.

        Heads up: while it’s on, your Mac won’t sleep at all — not on idle, and not \
        from the Apple menu. That uses more battery and the machine can get warm in \
        a bag, so switch it off when you’re done.

        This is a laptop feature — a desktop Mac has no lid to close.

        By Brandon Walter · github.com/EchoParkBaby
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/EchoParkBaby") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil) // policy lives in applicationShouldTerminate
    }

    // MARK: - Termination guard

    /// `pmset disablesleep` is a SYSTEM setting that outlives this app AND survives
    /// reboot. Quitting while it's on would leave the Mac permanently awake with no
    /// indicator and no obvious way back — so make the user choose. Implemented here
    /// (not in the menu action) so Cmd-Q, logout and shutdown all get the same guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-read live: the cached value can be up to 5s stale, and "unknown" must
        // not be treated as "off" — when in doubt, ask.
        let live = readDisableSleep()
        guard live ?? true else { return .terminateNow }  // definitely off → just quit

        let alert = NSAlert()
        alert.messageText = "Restore normal sleep before quitting?"
        alert.informativeText = """
        Your Mac is currently set never to sleep. That’s a system setting — it stays \
        in effect after Clamshelled quits (and after a restart), and there will be no \
        menu-bar icon to turn it off.
        """
        alert.addButton(withTitle: "Restore Normal Sleep")   // default
        alert.addButton(withTitle: "Keep Mac Awake")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Restoring goes over XPC, which must not block the main thread — a hung
            // helper would otherwise make the app unquittable and stall logout.
            Task {
                let result = await HelperClient.setDisableSleep(false)
                if !result.ok {
                    // Don't vanish leaving the Mac awake — that's the exact hazard.
                    let fail = NSAlert()
                    fail.messageText = "Couldn’t restore normal sleep"
                    fail.informativeText = """
                    Clamshelled stayed open so your Mac doesn’t get stuck awake.

                    \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    """
                    fail.addButton(withTitle: "OK")
                    fail.runModal()
                }
                refreshState()
                NSApp.reply(toApplicationShouldTerminate: result.ok)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow // deliberately leaving it awake
        }
    }

    // MARK: - Helper management

    @objc private func manageHelper() {
        if HelperClient.isEnabled {
            presentHelperInstalled()
            return
        }
        installHelper()
    }

    private func installHelper() {
        // A daemon's BundleProgram resolves inside this bundle. Registering from a
        // DMG or a folder that can move leaves a root job pointing at a path that
        // may vanish or be replaced.
        guard HelperClient.isInStableLocation else {
            presentMoveToApplications(reason: "change your Mac’s sleep settings")
            return
        }
        do {
            try HelperClient.register()
        } catch {
            presentHelperProblem(detail: error.localizedDescription)
            updateMenu()
            return
        }
        if HelperClient.status == .requiresApproval { presentApprovalNeeded() }
        updateMenu()
    }

    private func presentHelperInstalled() {
        let alert = NSAlert()
        alert.messageText = "Helper is installed"
        alert.informativeText = "Clamshelled’s privileged helper is registered and ready."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Remove Helper")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        removeHelper()
    }

    /// Removing the helper throws away the ONLY way to restore sleep, so normal
    /// sleep has to be restored (and confirmed) first — otherwise the Mac is
    /// stranded awake with no mechanism left to fix it.
    private func removeHelper() {
        Task {
            if readDisableSleep() ?? true {
                let warn = NSAlert()
                warn.messageText = "Restore normal sleep first?"
                warn.informativeText = """
                Your Mac is currently set never to sleep. Removing the helper takes \
                away the only way Clamshelled can undo that.
                """
                warn.addButton(withTitle: "Restore Sleep, Then Remove")
                warn.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard warn.runModal() == .alertFirstButtonReturn else { return }

                let restore = await HelperClient.setDisableSleep(false)
                let confirmed = restore.ok && (readDisableSleep() == false)
                guard confirmed else {
                    presentError(title: "Couldn’t restore normal sleep",
                                 body: """
                                 The helper was left installed so your Mac doesn’t get \
                                 stuck awake.

                                 \(restore.output.trimmingCharacters(in: .whitespacesAndNewlines))
                                 """)
                    return
                }
            }
            do {
                try await HelperClient.unregister()
            } catch {
                // Never silently swallow this — the user thinks it's gone.
                presentError(title: "Couldn’t remove the helper",
                             body: error.localizedDescription)
            }
            refreshState()
        }
    }

    // MARK: - Alerts

    private func presentMoveToApplications(reason: String) {
        presentError(
            title: "Move Clamshelled to Applications",
            body: """
            Clamshelled is running from a disk image or a temporary location, so macOS \
            can’t let it \(reason).

            Drag Clamshelled to your Applications folder, open it from there, and try \
            again.
            """)
    }

    private func presentApprovalNeeded() {
        let alert = NSAlert()
        alert.messageText = "Approve Clamshelled’s helper"
        alert.informativeText = """
        macOS needs your approval before Clamshelled can change your Mac’s sleep \
        settings.

        Turn on “Clamshelled” under Login Items & Extensions in System Settings, then \
        use the toggle again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentError(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Shown when the toggle couldn't reach the helper. Distinguishes "not installed"
    /// from "awaiting approval" from "installed but not answering" — the last one
    /// needs a re-registration, not another install attempt.
    private func presentHelperProblem(detail: String) {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)

        switch HelperClient.status {
        case .requiresApproval:
            presentApprovalNeeded()

        case .enabled:
            // Registered but unreachable → almost always a stale helper after an
            // app update. Offer the repair that actually works.
            let alert = NSAlert()
            alert.messageText = "Clamshelled’s helper isn’t responding"
            var body = "The helper is installed but didn’t answer. Reinstalling it usually fixes this."
            if !trimmed.isEmpty { body += "\n\nDetails: \(trimmed)" }
            alert.informativeText = body
            alert.addButton(withTitle: "Reinstall Helper")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await HelperClient.unregister()
                    try await Task.sleep(for: .milliseconds(500))
                    try HelperClient.register()
                    if HelperClient.status == .requiresApproval { presentApprovalNeeded() }
                } catch {
                    presentError(title: "Couldn’t reinstall the helper",
                                 body: error.localizedDescription)
                }
                updateMenu()
            }

        default:
            let alert = NSAlert()
            alert.messageText = "Clamshelled needs to install a helper"
            var body = """
            Changing your Mac’s sleep setting needs administrator rights. Clamshelled \
            installs a small helper to do it — macOS will ask you to approve it once.
            """
            if !trimmed.isEmpty { body += "\n\nDetails: \(trimmed)" }
            alert.informativeText = body
            alert.addButton(withTitle: "Install Helper…")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { installHelper() }
        }
    }

    // MARK: - UI

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // ON = lid-closed stay-awake → CLOSED (clamshelled) MacBook. OFF → open one.
        let asset = isEnabled ? "clamshell-closed-template-36" : "clamshell-open-template-36"
        let label = isEnabled ? "Clamshelled: Mac staying awake"
                              : "Clamshelled: Mac sleeps normally"
        button.image = Self.menuBarImage(named: asset, label: label)
            ?? NSImage(systemSymbolName: isEnabled ? "zzz" : "laptopcomputer",
                       accessibilityDescription: label)
        // Never let a missing asset leave a blank, zero-width, unclickable item —
        // a title guarantees the menulet stays visible and reachable.
        button.title = (button.image == nil) ? (isEnabled ? "AWAKE" : "Clam") : ""
        button.imagePosition = (button.image == nil) ? .noImage : .imageOnly
        // An image-only status item is invisible to VoiceOver without this.
        button.setAccessibilityLabel(label)
        button.toolTip = isEnabled
            ? "Staying awake — this Mac won’t sleep, even with the lid closed"
            : "Normal — this Mac sleeps when idle or when the lid is closed"
    }

    private static func menuBarImage(named name: String, label: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            NSLog("Clamshelled: missing menu-bar asset \(name).png — using fallback")
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Be honest: `disablesleep 1` stops ALL sleep, not just the lid-closed kind.
        let header = NSMenuItem(
            title: isEnabled ? "Never sleeps — lid can stay closed" : "Sleeps normally",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if isEnabled {
            let warn = NSMenuItem(title: "Uses more battery — turn off when done",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Keep Awake With Lid Closed (\(isEnabled ? "On" : "Off"))",
                                    action: #selector(toggle), keyEquivalent: "k")
        toggleItem.target = self
        toggleItem.state = isEnabled ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let aboutItem = NSMenuItem(title: "What Is This?",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let helperItem = NSMenuItem(title: HelperClient.isEnabled ? "Privileged Helper (Installed)"
                                                                 : "Install Privileged Helper…",
                                    action: #selector(manageHelper), keyEquivalent: "")
        helperItem.target = self
        menu.addItem(helperItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clamshelled",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "Version \(Self.displayVersion)",
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let authorItem = NSMenuItem(title: "Brandon Walter", action: nil, keyEquivalent: "")
        authorItem.isEnabled = false
        menu.addItem(authorItem)

        let githubItem = NSMenuItem(title: "GitHub: @EchoParkBaby",
                                    action: #selector(openGitHub), keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

        statusItem.menu = menu
    }
}
