import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var hotkey: GlobalHotkey?
    private let permission = AccessibilityPermission()
    private let bridge = BridgeCoordinator()
    private lazy var overlay = OverlayController(permission: permission, bridge: bridge)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.logStartup()
        setUpStatusItem()
        setUpPermissionWatch()
        setUpBridge()
        setUpHotkey()

        // Build the panel now so the first Ctrl-Space opens instantly.
        overlay.prewarm()

        // The onboarding screen is shown, but the system prompt is NOT raised here.
        // macOS only displays that dialog once per identity and ignores later calls, so
        // firing it automatically would show a dialog that silently does nothing on every
        // subsequent launch. It is raised only from the button in the onboarding UI.
        if !permission.isTrusted {
            overlay.show()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "WorkSwitch"
        )
        item.menu = buildMenu()
        statusItem = item
        updateStatusItemAppearance()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "Open Switcher",
            action: #selector(openSwitcher),
            keyEquivalent: " "
        )
        open.keyEquivalentModifierMask = [.control]
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let permissionItem = NSMenuItem(
            title: "Accessibility Permission…",
            action: #selector(openPermissionSettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        permissionItem.tag = Self.permissionMenuTag
        menu.addItem(permissionItem)

        // Connection state is shown rather than left to guesswork — a silently missing
        // extension is otherwise indistinguishable from "Chrome has no tabs open".
        let bridgeItem = NSMenuItem(title: "Chrome Extension: Not Connected", action: nil, keyEquivalent: "")
        bridgeItem.tag = Self.bridgeMenuTag
        bridgeItem.isEnabled = false
        menu.addItem(bridgeItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WorkSwitch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private static let permissionMenuTag = 100
    private static let bridgeMenuTag = 101

    private func setUpBridge() {
        bridge.addChangeObserver { [weak self] in
            self?.updateBridgeMenuItem()
        }
        bridge.start()
        updateBridgeMenuItem()
    }

    private func updateBridgeMenuItem() {
        statusItem?.menu?.item(withTag: Self.bridgeMenuTag)?.title = bridge.status.menuTitle
    }

    /// The menu bar surfaces the untrusted state rather than letting the app fail silently.
    private func updateStatusItemAppearance() {
        let trusted = permission.isTrusted
        statusItem?.button?.image = NSImage(
            systemSymbolName: trusted ? "square.stack.3d.up" : "exclamationmark.triangle",
            accessibilityDescription: "WorkSwitch"
        )
        statusItem?.button?.toolTip = trusted
            ? "WorkSwitch — Ctrl-Space"
            : "WorkSwitch — Accessibility permission required"

        if let item = statusItem?.menu?.item(withTag: Self.permissionMenuTag) {
            item.title = trusted ? "Accessibility: Granted" : "Grant Accessibility Permission…"
            item.isEnabled = !trusted
        }
    }

    private func setUpPermissionWatch() {
        permission.onChange = { [weak self] trusted in
            guard let self else { return }
            self.updateStatusItemAppearance()
            self.overlay.setTrusted(trusted)
        }
        if !permission.isTrusted { permission.startPolling() }
    }

    private func setUpHotkey() {
        hotkey = GlobalHotkey { [weak self] in
            self?.overlay.toggle()
        }
        if hotkey == nil {
            NSLog("[WorkSwitch] Failed to register Ctrl-Space. Another app may already own it.")
        }
    }

    // MARK: - Actions

    @objc private func openSwitcher() {
        overlay.show()
    }

    @objc private func openPermissionSettings() {
        permission.requestAccess()
        permission.openSystemSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
