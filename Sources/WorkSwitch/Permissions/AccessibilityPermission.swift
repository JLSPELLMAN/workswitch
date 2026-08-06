import AppKit
import ApplicationServices

/// Accessibility is required for both halves of the product: it is the only source of
/// window titles, and the only way to focus a specific window. Onboarding is therefore
/// part of the core flow, not an edge case.
final class AccessibilityPermission {

    /// Records that the grant has worked at least once for this build's identity. If trust
    /// is later lost, the cause is almost certainly a changed code-signing identity rather
    /// than the user revoking it by hand — which is what the troubleshooting hint keys on.
    private static let hasBeenTrustedKey = "WorkSwitch.hasBeenTrusted"

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private(set) var isTrusted: Bool = AXIsProcessTrusted()

    /// Fires on the main queue whenever trust changes.
    var onChange: ((Bool) -> Void)?

    init() {
        if isTrusted { UserDefaults.standard.set(true, forKey: Self.hasBeenTrustedKey) }
        observeActivation()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        pollTimer?.invalidate()
    }

    /// True when the app was trusted at some point but is not now. In practice this means
    /// the build's identity changed, so System Settings still lists an entry that no longer
    /// matches the running binary.
    var looksLikeStaleGrant: Bool {
        !isTrusted && UserDefaults.standard.bool(forKey: Self.hasBeenTrustedKey)
    }

    // MARK: - Checking

    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted {
            UserDefaults.standard.set(true, forKey: Self.hasBeenTrustedKey)
        }
        if trusted != isTrusted {
            isTrusted = trusted
            NSLog("[WorkSwitch] Accessibility trust changed: %@", trusted ? "granted" : "lost")
            onChange?(trusted)
        }
        return trusted
    }

    /// Re-checks the moment the app comes forward — which is exactly what happens when the
    /// user returns from System Settings after toggling the permission. Without this the UI
    /// would sit stale until the next poll.
    private func observeActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            else { return }
            self?.refresh()
        }
    }

    /// Backstop for the case where the grant is toggled while WorkSwitch is already frontmost,
    /// which produces no activation notification. Polling only reads state; it never prompts.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.refresh() { self.stopPolling() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requesting

    /// Raises the system permission prompt.
    ///
    /// Only ever called from an explicit user action. macOS shows this prompt once per
    /// identity and silently ignores later calls, so invoking it on launch or on every
    /// render would train the user to see a dialog that does nothing.
    func requestAccess() {
        NSLog("[WorkSwitch] Accessibility prompt requested by user action")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startPolling()
    }

    func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Clears a stale grant so the app can be added again under its current identity.
    func resetGrantCommand() -> String {
        Diagnostics.resetCommand
    }
}
