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
    /// The toggle is a round trip to a root daemon; a second click mid-flight would
    /// compute its target from a stale value and undo the first one.
    private var toggleInFlight = false
    /// When lid-closed mode should switch itself back off. nil = never.
    private var autoOffDeadline: Date?
    private let settings = SettingsWindowController()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        settings.onChange = { [weak self] in self?.updateIcon() }
        settings.onAutoOffChanged = { [weak self] in self?.armAutoOff(); self?.updateIcon() }
        settings.onToggleLoginItem = { [weak self] in self?.toggleLoginItem() }
        settings.onManageHelper = { [weak self] in self?.manageHelper() }
        if Settings.keepAwakeAtLaunch { KeepAwake.set(true) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        // No `statusItem.menu` — that would swallow every click into the menu.
        // Left click toggles; right/control click pops the menu (see statusItemClicked).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        let was = isEnabled
        // Unknown state keeps the last known value rather than falsely showing "off".
        if let state = readDisableSleep() { isEnabled = state }
        // Arm on any off→on transition, including one made from a terminal, and on
        // finding it already on at launch — that's exactly the forgotten-overnight
        // case the timer exists for.
        if isEnabled && !was { armAutoOff() }
        if !isEnabled { autoOffDeadline = nil }
        fireAutoOffIfDue()
        updateIcon()
    }

    // MARK: - Actions

    /// Left click = toggle lid-closed mode. Option-click = Keep Me Awake.
    /// Right (or control) click = the menu — control-click is the same gesture as
    /// right-click on a trackpad, so both have to land here.
    @objc private func statusItemClicked() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if NSApp.currentEvent?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.option) {
            toggleKeepAwake()
        } else {
            toggle()
        }
    }

    @objc private func openSettings() {
        settings.show()
    }

    // MARK: - Auto-off

    /// Lid-closed mode is a system setting that survives a restart, so the failure
    /// mode is a laptop cooking itself in a bag overnight. This is the backstop.
    /// No Timer: the existing 5s poll already runs, and a deadline survives the
    /// clock changes and sleep/wake cycles a scheduled timer doesn't.
    private func armAutoOff() {
        let minutes = Settings.autoOffMinutes
        autoOffDeadline = (isEnabled && minutes > 0)
            ? Date().addingTimeInterval(Double(minutes) * 60)
            : nil
    }

    private func fireAutoOffIfDue() {
        guard isEnabled, let deadline = autoOffDeadline, Date() >= deadline else { return }
        autoOffDeadline = nil   // one shot; a failed attempt shouldn't loop every 5s
        guard HelperClient.isEnabled, !toggleInFlight else { return }
        toggleInFlight = true
        Task {
            let result = await HelperClient.setDisableSleep(false)
            toggleInFlight = false
            // Deliberately silent on failure: this fires unattended, often with the
            // lid shut, so an alert nobody sees would just block the next attempt.
            if !result.ok { NSLog("Clamshelled: auto-off failed: \(result.output)") }
            refreshState()
        }
    }

    /// "in 47 min" / "in 2 hr 5 min", or nil when nothing is scheduled.
    private var autoOffSummary: String? {
        guard let deadline = autoOffDeadline else { return nil }
        let minutes = max(0, Int((deadline.timeIntervalSinceNow / 60).rounded(.up)))
        if minutes < 60 { return "in \(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "in \(hours) hr" : "in \(hours) hr \(rest) min"
    }

    /// Attach the menu just long enough to click it open. `performClick` runs the
    /// menu's own tracking loop and returns once it closes, so detaching afterwards
    /// is safe — and necessary, or the next left click would open the menu instead
    /// of toggling.
    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggle() {
        guard !toggleInFlight else { return }
        guard HelperClient.isEnabled else {
            presentHelperProblem(detail: "")
            return
        }
        let target = !isEnabled
        toggleInFlight = true
        Task {
            let result = await HelperClient.setDisableSleep(target)
            toggleInFlight = false
            if !result.ok { presentHelperProblem(detail: result.output) }
            refreshState()
        }
    }

    @objc private func toggleKeepAwake() {
        guard KeepAwake.set(!KeepAwake.isOn) else {
            presentError(title: "Couldn’t change Keep Me Awake",
                         body: "macOS refused the power assertion. Try again, or restart Clamshelled.")
            return
        }
        updateIcon()   // tooltip carries the state; the menu is rebuilt on next open
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
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Clamshelled \(Self.displayVersion)"
        alert.informativeText = """
        Keeps your Mac awake while the lid is closed — no external display or \
        charger required.

        Click the menu-bar icon to turn it on or off; right-click for this menu. \
        The icon shows a closed MacBook while it’s active, an open one when your \
        Mac sleeps normally.

        “Keep Me Awake” is the milder option: it stops your Mac idling to sleep \
        while Clamshelled is running, but the lid still has to stay open, and it \
        ends when you quit.

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
            return
        }
        if HelperClient.status == .requiresApproval { presentApprovalNeeded() }
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
        var label = isEnabled ? "Clamshelled: Mac staying awake"
                              : "Clamshelled: Mac sleeps normally"
        if KeepAwake.isOn { label += ", Keep Me Awake on" }
        // Colour is a second axis on the same two shapes: shape = lid-closed mode,
        // tint = Keep Me Awake. Never the only cue — the label and menu say it too.
        let onDarkBar = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tint = (KeepAwake.isOn && Settings.tintWhenKeepAwake)
            ? (onDarkBar ? Self.tintOnDarkBar : Self.tintOnLightBar)
            : nil
        button.image = Self.menuBarImage(named: asset, label: label, tint: tint)
            ?? NSImage(systemSymbolName: isEnabled ? "zzz" : "laptopcomputer",
                       accessibilityDescription: label)
        // Never let a missing asset leave a blank, zero-width, unclickable item —
        // a title guarantees the menulet stays visible and reachable.
        button.title = (button.image == nil) ? (isEnabled ? "AWAKE" : "Clam") : ""
        button.imagePosition = (button.image == nil) ? .noImage : .imageOnly
        // An image-only status item is invisible to VoiceOver without this.
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp("Click to turn lid-closed stay-awake on or off. Option-click for Keep Me Awake. Right-click for the menu.")
        var tip = isEnabled
            ? "Staying awake — this Mac won’t sleep, even with the lid closed"
            : "Normal — this Mac sleeps when idle or when the lid is closed"
        if let summary = autoOffSummary { tip += " (turns off \(summary))" }
        if KeepAwake.isOn { tip += "\nKeep Me Awake is on (lid must stay open)" }
        tip += "\nClick to toggle · option-click for Keep Me Awake · right-click for the menu"
        button.toolTip = tip
    }

    /// Keep Me Awake tint. The menu bar is dark in Dark Mode and light in Light
    /// Mode, and one light orange can't read on both — so go pale on a dark bar and
    /// a shade deeper on a light one, where a pale orange washes out.
    private static let tintOnDarkBar  = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.45, alpha: 1)
    private static let tintOnLightBar = NSColor(srgbRed: 0.95, green: 0.58, blue: 0.18, alpha: 1)

    private static func menuBarImage(named name: String, label: String, tint: NSColor?) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let base = NSImage(contentsOf: url) else {
            NSLog("Clamshelled: missing menu-bar asset \(name).png — using fallback")
            return nil
        }
        base.size = NSSize(width: 18, height: 18)
        guard let tint else {
            base.isTemplate = true       // macOS recolours it for light/dark menu bars
            base.accessibilityDescription = label
            return base
        }
        // A template image is recoloured by the system, so a tinted one can't be one.
        // sourceAtop paints only where the glyph already is, keeping the alpha shape.
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.accessibilityDescription = label
        return tinted
    }

    /// Built fresh each time it's opened, so it never shows stale state.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Be honest: `disablesleep 1` stops ALL sleep, not just the lid-closed kind.
        var headerTitle: String
        if isEnabled            { headerTitle = "Never sleeps — lid can stay closed" }
        else if KeepAwake.isOn  { headerTitle = "Staying awake — but only with the lid open" }
        else                    { headerTitle = "Sleeps normally" }
        if let summary = autoOffSummary { headerTitle += " · off \(summary)" }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if isEnabled || KeepAwake.isOn {
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
        toggleItem.toolTip = "Same as clicking the menu-bar icon. Needs the privileged helper."
        menu.addItem(toggleItem)

        let awakeItem = NSMenuItem(title: "Keep Me Awake",
                                   action: #selector(toggleKeepAwake), keyEquivalent: "a")
        awakeItem.target = self
        awakeItem.state = KeepAwake.isOn ? .on : .off
        awakeItem.toolTip = "Option-click the menu-bar icon does this too. Stops idle sleep while Clamshelled runs; ends when you quit, and the lid still has to stay open."
        menu.addItem(awakeItem)

        menu.addItem(.separator())

        // Version, author, GitHub, Launch at Login and the helper all live in
        // Settings now — the menu is for the two things you actually click.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Clamshelled",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clamshelled",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }
}
