import AppKit
import ApplicationServices
import SwiftUI

/// Keeps the panel's top edge pinned while SwiftUI resizes it to fit the result list, and
/// remembers a manual drag so the next resize or reopen doesn't undo it.
private final class PanelDelegate: NSObject, NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        (notification.object as? OverlayPanel)?.applyPosition()
    }

    func windowDidMove(_ notification: Notification) {
        (notification.object as? OverlayPanel)?.noteWindowDidMove()
    }
}

/// Owns the overlay panel, its keyboard handling, and the refresh cycle.
@MainActor
final class OverlayController {

    private let model = SwitcherModel()
    private let provider = NativeWindowProvider()
    private let permission: AccessibilityPermission
    private let bridge: BridgeCoordinator

    private var panel: OverlayPanel?
    private lazy var panelDelegate = PanelDelegate()
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private let enumerationQueue = DispatchQueue(label: "com.lorenzospellman.workswitch.enumerate")

    /// The app that was in front when the overlay opened. Captured *before* the panel takes
    /// focus, because showing the panel destroys this information — and Milestone 4 ranks on
    /// "what is the current context" using exactly this.
    private(set) var previousApplication: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Set by `activate(_:)` right before it raises a window, so the
    /// `didActivateApplicationNotification` that raise triggers doesn't get recorded a second
    /// time by `handleExternalActivation`. Self-clearing after a short window rather than on
    /// first use, since app activation is asynchronous and can arrive a beat late.
    private var suppressedActivationID: String?
    private var suppressedActivationExpiry: Date?

    init(permission: AccessibilityPermission, bridge: BridgeCoordinator) {
        self.permission = permission
        self.bridge = bridge
        syncPermissionState()

        // Chrome tabs change without any window event, so the open overlay refreshes itself
        // when the tab set moves under it.
        bridge.addChangeObserver { [weak self] in
            guard let self, self.isVisible else { return }
            self.refreshDestinations()
        }

        observeWorkspaceChanges()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Keeps an already-open overlay reasonably fresh as apps come and go. This covers
    /// app-level churn (launch, quit, activate, hide, unhide); per-window events — a window
    /// created, destroyed, or retitled within an app that was already running — would need a
    /// per-app AX observer for every running process, which is a materially larger piece of
    /// plumbing left for a follow-up rather than folded into this fix.
    private var workspaceObservers: [NSObjectProtocol] = []

    private func observeWorkspaceChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let refreshOnlyNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in refreshOnlyNames {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` guarantees this runs on the main thread; the compiler just
                // can't see that through NotificationCenter's non-isolated closure type.
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.refreshDestinations()
                }
            }
            workspaceObservers.append(observer)
        }

        // Separate from the block above: this is the actual fix for recency tracking.
        // `didActivateApplicationNotification` fires for *every* app-level focus change —
        // mouse clicks, Cmd-Tab, Mission Control, Dock clicks — regardless of whether the
        // overlay is open, which the block above deliberately is not (it only refreshes an
        // already-visible panel). Recording activity was previously wired to nothing but
        // WorkSwitch's own row-activation path, so switching apps any other way never touched
        // the ranker at all — the overlay's "recent" ordering was frozen at whatever the
        // z-order-based cold-start heuristic produced, not real usage.
        let activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleExternalActivation(notification)
            }
        }
        workspaceObservers.append(activationObserver)
    }

    /// Resolves the specific window that just became frontmost and records it as activity —
    /// covering every way a user can switch outside WorkSwitch itself (mouse, Cmd-Tab, Mission
    /// Control, Dock). Deliberately excludes WorkSwitch's own activation (opening the overlay
    /// must never count as interaction) and, via `suppressedActivationID`, a WorkSwitch-driven
    /// selection's own resulting activation (already recorded once, with the exact destination
    /// identity, in `activate(_:)`).
    private func handleExternalActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        guard app.processIdentifier != ownPID else { return }

        guard let resolved = resolveFrontmostDestination(for: app) else { return }

        if let suppressedActivationID, let suppressedActivationExpiry,
           suppressedActivationID == resolved.id, Date() < suppressedActivationExpiry {
            self.suppressedActivationID = nil
            self.suppressedActivationExpiry = nil
            return
        }

        model.recordActivation(
            id: resolved.id, title: resolved.title, appName: app.localizedName ?? "Unknown",
            source: "external focus change"
        )

        if isVisible { refreshDestinations() }
    }

    private func suppressNextExternalActivation(for destinationID: String) {
        suppressedActivationID = destinationID
        // Generous but bounded: app activation from a raise is normally near-instant, but this
        // avoids a permanently-stuck suppression if the notification never arrives for some
        // reason (activation failed after all, app quit mid-raise, etc.).
        suppressedActivationExpiry = Date().addingTimeInterval(2.0)
    }

    /// Best-effort resolution of "which single window of this app is frontmost right now",
    /// using the same id format discovery uses so the ranker's record actually matches a real
    /// destination. Chrome goes through AppleScript (see `ChromeAppleScriptProvider`) since
    /// that's also its path in discovery; everything else goes through AX directly, which is
    /// safe here (unlike full enumeration) because it's one attribute read on one known app,
    /// not a scan of every running process.
    ///
    /// Known gap: switching between two windows of the *same* app without that app losing and
    /// regaining frontmost status (e.g. via the Window menu, or Mission Control's app-window
    /// picker while already in that app) fires no activation notification at all, so that
    /// transition isn't observed. Matches the existing, already-documented limitation of
    /// per-window tracking elsewhere in this file (see the doc comment on `workspaceObservers`)
    /// — full coverage needs a per-app AXObserver, deliberately left for a follow-up.
    private func resolveFrontmostDestination(for app: NSRunningApplication) -> (id: String, title: String)? {
        let bundleID = app.bundleIdentifier

        if (bundleID ?? "").hasPrefix(NativeWindowProvider.chromeBundlePrefix) {
            guard let windows = ChromeAppleScriptProvider.windows(),
                  let frontmost = windows.first(where: { $0.index == 1 })
            else { return nil }
            return (NativeWindowProvider.chromeDestinationID(appleScriptWindowID: frontmost.id), frontmost.title)
        }

        guard permission.isTrusted else { return nil }
        let appElement = AX.application(pid: app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        let window = focused as! AXUIElement

        let title = AX.string(window, kAXTitleAttribute) ?? ""
        let windowID = AX.windowID(of: window)
        let appName = app.localizedName ?? "Unknown"
        let id = NativeWindowProvider.destinationID(
            bundleID: bundleID, appName: appName, windowID: windowID, title: title
        )
        return (id, title)
    }

    func setTrusted(_ trusted: Bool) {
        syncPermissionState()
        if trusted, isVisible { refreshDestinations() }
    }

    private func syncPermissionState() {
        model.isTrusted = permission.isTrusted
        model.looksLikeStaleGrant = permission.looksLikeStaleGrant
    }

    // MARK: - Panel lifecycle

    /// Built once at launch and reused, so the first Ctrl-Space is as fast as every later one.
    /// Also seeds the destination cache in the background, so that very first press shows
    /// results immediately instead of a blank panel while the first enumeration runs.
    func prewarm() {
        _ = ensurePanel()
        refreshDestinations()
    }

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }

        let contentRect = NSRect(x: 0, y: 0, width: 320, height: 120)
        let newPanel = OverlayPanel(contentRect: contentRect)

        let view = OverlayView(
            model: model,
            onActivate: { [weak self] destination in self?.activate(destination) },
            onRequestPermission: { [weak self] in
                self?.permission.requestAccess()
                self?.permission.openSystemSettings()
            },
            onClose: { [weak self] in self?.hide() },
            onPanelHeightChange: { [weak self] height in self?.applyPanelHeight(height) }
        )

        // AppKit, not NSHostingController, drives the panel's size: a plain ScrollView never
        // reports its content's true size to an ancestor asking "how big do you want to be" —
        // it just accepts whatever height it's given — so relying on the hosting controller's
        // automatic content-size tracking left the panel stuck at whatever height it happened
        // to get on its first layout (typically the empty state, since `prewarm()` opens before
        // the first async window enumeration returns), silently clipping every longer list to
        // however many rows fit in that leftover height. `OverlayView` measures its own true
        // content height via GeometryReader and reports it through `onPanelHeightChange`
        // instead, and this class applies it directly with `setContentSize`.
        newPanel.contentViewController = NSHostingController(rootView: view)
        newPanel.delegate = panelDelegate

        panel = newPanel
        return newPanel
    }

    /// SwiftUI reports its measured height here; this is the one place that turns it into an
    /// actual window resize, keeping `OverlayPanel.applyPosition()`'s pinned-top-edge,
    /// anchored-left placement (triggered via the resize delegate) as the single source of
    /// truth for where the panel ends up.
    private func applyPanelHeight(_ height: CGFloat) {
        guard let panel, height > 0, height.isFinite else { return }
        let target = NSSize(width: panel.frame.width, height: height.rounded())
        guard abs(panel.frame.height - target.height) > 0.5 else { return }
        panel.setContentSize(target)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        previousApplication = NSWorkspace.shared.frontmostApplication

        // Re-check on open: the user may have just returned from System Settings.
        permission.refresh()
        syncPermissionState()
        if !permission.isTrusted { permission.startPolling() }

        let panel = ensurePanel()
        model.resetQuery()
        refreshDestinations()

        panel.positionOnActiveScreen()
        installKeyMonitor()
        installClickMonitor()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeKeyMonitor()
        removeClickMonitor()
        panel?.orderOut(nil)
        // Hand focus back to wherever the user came from, so dismissing costs nothing.
        previousApplication?.activate()
    }

    // MARK: - Data

    private func refreshDestinations() {
        let tabs = bridge.destinations()
        let isExtensionConnected = bridge.isConnected

        // Chrome tabs arrive over the bridge and need no Accessibility permission, so they
        // remain usable while the permission is still pending.
        guard permission.isTrusted else {
            model.update(destinations: tabs)
            Diagnostics.logRefresh(
                destinations: tabs, report: nil, chromeTabCount: tabs.count,
                isExtensionConnected: isExtensionConnected, invokedFrom: previousApplication
            )
            return
        }

        // Accessibility reads are synchronous IPC, so they never run on the main thread
        // while the user is typing.
        enumerationQueue.async { [provider] in
            let (nativeWindows, discoveryReport) = provider.enumerateWithDiagnostics()
            Task { @MainActor [weak self] in
                let merged = DestinationMerger.merge(
                    nativeWindows: nativeWindows,
                    chromeTabs: tabs,
                    isExtensionConnected: isExtensionConnected
                )
                self?.model.update(destinations: merged)
                Diagnostics.logRefresh(
                    destinations: merged,
                    report: discoveryReport,
                    chromeTabCount: tabs.count,
                    isExtensionConnected: isExtensionConnected,
                    invokedFrom: self?.previousApplication
                )
            }
        }
    }

    // MARK: - Activation

    /// Switching to a destination raises it, but deliberately does not close the panel —
    /// chaining several switches in a row (check something, come back, check something else)
    /// is a normal way to use this, and re-opening from scratch between each one would be
    /// exactly the friction this exists to remove.
    private func activate(_ destination: Destination) {
        let result: ActivationResult
        switch destination.type {
        case .nativeWindow:
            result = WindowActivator.activate(destination)
        case .browserTab:
            result = bridge.activate(destination)
        }

        switch result {
        case .success:
            // Only a *successful* activation counts as interaction — recording unconditionally
            // (the previous behavior) meant a failed activation still bumped that destination
            // to the top of "recent", which is backwards: it's exactly the one thing that
            // *didn't* just happen.
            model.recordActivation(
                id: destination.id, title: destination.displayTitle,
                appName: destination.appName, source: "WorkSwitch selection"
            )
            // The window this raises is about to fire its own
            // `didActivateApplicationNotification`; tell the external observer to skip it so
            // one selection doesn't double-count.
            suppressNextExternalActivation(for: destination.id)
            // The raise above just handed focus to the destination's app; claim it back so
            // the search field is still the thing receiving keystrokes for whatever gets
            // picked next, rather than leaving the user to click back into a panel that's
            // visibly still open. `NSRunningApplication.activate()` (inside the raise above) is
            // asynchronous cross-process IPC to the window server — its actual frontmost-switch
            // can land well after this line runs, so reclaiming immediately just loses the race
            // and gets silently undone a moment later. A short, empirically-safe delay is what
            // makes this reclaim the one that actually sticks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.reclaimFocus()
            }
            refreshDestinations()
        case .failure(let reason):
            NSLog("[WorkSwitch] Activation failed: \(reason)")
            NSSound.beep()
        }
    }

    /// Re-asserts the panel as the key window without repositioning or resetting the query —
    /// unlike `show()`, this runs while the panel is already open and mid-use.
    private func reclaimFocus() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// A click anywhere outside the panel — on the desktop, another window, another app —
    /// is the standard way people expect to dismiss a Spotlight-style overlay. Without this,
    /// that click had nowhere to go but straight through to whatever was underneath, so
    /// "just close it" could end up clicking a link or button in the app behind it instead.
    /// A global monitor only *observes* clicks in other apps' windows (it can't consume them,
    /// which would need a lower-level event tap), so the underlying app still sees the click —
    /// but the overlay now gets out of the way immediately instead of lingering on top of it.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, self.isVisible else { return }
                    if !panel.frame.contains(NSEvent.mouseLocation) {
                        self.hide()
                    }
                }
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)

        switch Int(event.keyCode) {
        case 53: // Escape
            hide()
            return true

        case 36, 76: // Return, Enter
            if let destination = model.selectedDestination {
                activate(destination)
            }
            return true

        case 126: // Up
            hasCommand ? model.moveToFirst() : model.moveSelection(by: -1)
            return true

        case 125: // Down
            hasCommand ? model.moveToLast() : model.moveSelection(by: 1)
            return true

        case 48: // Tab cycles, matching switcher convention
            model.moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true

        default:
            // Ctrl-N / Ctrl-P for keyboard-home-row navigation.
            if event.modifierFlags.contains(.control), let characters = event.charactersIgnoringModifiers {
                if characters == "n" { model.moveSelection(by: 1); return true }
                if characters == "p" { model.moveSelection(by: -1); return true }
            }
            return false
        }
    }
}
