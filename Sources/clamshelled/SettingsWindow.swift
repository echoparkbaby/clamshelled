import AppKit
import ServiceManagement

/// The Settings window. Built in code — it's one window and a dozen controls, so a
/// storyboard would be more file than UI. Built once and reused, so it remembers
/// where you put it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    /// Fired when a change here affects the menu-bar icon.
    var onChange: (() -> Void)?
    /// Separate from onChange so that fiddling with the icon tint doesn't silently
    /// restart a countdown that's already running.
    var onAutoOffChanged: (() -> Void)?
    /// Login-item and helper changes own a pile of alert flow, so AppController
    /// keeps them; this window just calls in and re-reads the result.
    var onToggleLoginItem: (() -> Void)?
    var onManageHelper: (() -> Void)?

    private var window: NSWindow?
    private var launchAtLoginBox: NSButton!
    private var keepAwakeBox: NSButton!
    private var tintBox: NSButton!
    private var autoOffPopUp: NSPopUpButton!
    private var helperLabel: NSTextField!
    private var helperButton: NSButton!

    private static let contentWidth: CGFloat = 420
    private static let textWidth: CGFloat = 420 - 44   // minus the edge insets

    func show() {
        if window == nil {
            window = build()
            window?.center()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-reads everything the system owns. Launch-at-login and helper status can
    /// both change behind our back in System Settings.
    func refresh() {
        guard window != nil else { return }
        launchAtLoginBox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        keepAwakeBox.state = Settings.keepAwakeAtLaunch ? .on : .off
        tintBox.state = Settings.tintWhenKeepAwake ? .on : .off
        autoOffPopUp.selectItem(at: Settings.autoOffChoices.firstIndex { $0.minutes == Settings.autoOffMinutes } ?? 0)

        let installed = HelperClient.isEnabled
        switch HelperClient.status {
        case .enabled:          helperLabel.stringValue = "Installed and ready."
        case .requiresApproval: helperLabel.stringValue = "Waiting for your approval in System Settings."
        default:                helperLabel.stringValue = "Not installed — lid-closed mode needs it."
        }
        helperButton.title = installed ? "Remove…" : "Install…"
    }

    // MARK: - Actions

    @objc private func launchAtLoginChanged() {
        onToggleLoginItem?()
        refresh()   // the real state is whatever SMAppService ended up with, not the box
    }

    @objc private func keepAwakeChanged() {
        Settings.keepAwakeAtLaunch = (keepAwakeBox.state == .on)
    }

    @objc private func tintChanged() {
        Settings.tintWhenKeepAwake = (tintBox.state == .on)
        onChange?()
    }

    @objc private func autoOffChanged() {
        Settings.autoOffMinutes = Settings.autoOffChoices[autoOffPopUp.indexOfSelectedItem].minutes
        onAutoOffChanged?()
    }

    @objc private func helperTapped() {
        onManageHelper?()
        refresh()
    }

    @objc private func openGitHub() { open("https://github.com/EchoParkBaby") }
    @objc private func openCoffee() { open("https://buymeacoffee.com/echoparkbaby") }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Construction

    private func build() -> NSWindow {
        launchAtLoginBox = checkbox("Launch Clamshelled at login", #selector(launchAtLoginChanged))
        keepAwakeBox = checkbox("Turn on Keep Me Awake when Clamshelled starts", #selector(keepAwakeChanged))
        tintBox = checkbox("Tint the menu-bar icon while Keep Me Awake is on", #selector(tintChanged))

        autoOffPopUp = NSPopUpButton()
        autoOffPopUp.addItems(withTitles: Settings.autoOffChoices.map(\.title))
        autoOffPopUp.target = self
        autoOffPopUp.action = #selector(autoOffChanged)

        helperLabel = caption("")
        helperButton = NSButton(title: "Install…", target: self, action: #selector(helperTapped))

        let stack = NSStackView(views: [
            heading("General"),
            launchAtLoginBox,
            keepAwakeBox,
            tintBox,
            caption("Keep Me Awake stops your Mac idling to sleep while Clamshelled is running. It ends when you quit, and the lid still has to stay open."),

            separator(),
            heading("Safety net"),
            row("Turn off lid-closed mode:", autoOffPopUp),
            caption("Lid-closed mode is a system setting that survives a restart. This turns it back off for you after a while, so a laptop in a bag doesn’t stay awake all night."),

            separator(),
            heading("Privileged helper"),
            helperLabel,
            helperButton,

            separator(),
            aboutBlock(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.setCustomSpacing(16, after: tintBox)   // caption reads as its own note

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        container.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: container.fittingSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Clamshelled Settings"
        window.contentView = container
        window.isReleasedWhenClosed = false   // reused on the next Settings… click
        window.delegate = self
        return window
    }

    private func aboutBlock() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
        ])

        let name = NSTextField(labelWithString: "Clamshelled \(AppController.displayVersion)")
        name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let links = NSStackView(views: [
            link("GitHub: @EchoParkBaby", #selector(openGitHub)),
            link("Buy Me a Coffee", #selector(openCoffee)),
        ])
        links.orientation = .horizontal
        links.spacing = 12

        let text = NSStackView(views: [name, caption("by Brandon Walter"), links])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let block = NSStackView(views: [icon, text])
        block.orientation = .horizontal
        block.alignment = .top
        block.spacing = 12
        // Without an explicit width the outer stack stretches this to the full
        // window and the icon ends up flush against the left edge, ignoring insets.
        block.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        return block
    }

    // MARK: - Control factories

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    /// Secondary explanatory text. Wraps, so it needs an explicit width — an
    /// unconstrained label in a stack view lays out as one very long line.
    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.textWidth
        label.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        return label
    }

    private func link(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.controlSize = .small
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        return box
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), control])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }
}
