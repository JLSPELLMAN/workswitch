import AppKit
import ApplicationServices

/// Thin, failure-tolerant wrappers over the Accessibility API.
///
/// The Accessibility API is the *primary* source of window titles in WorkSwitch.
/// `CGWindowListCopyWindowInfo` does not supply them: on current macOS `kCGWindowName`
/// is gated behind Screen Recording permission and comes back nil for essentially every
/// window, so a CoreGraphics-based enumerator would produce an untitled list.
enum AX {

    /// Accessibility calls are synchronous IPC into the target app. Without a timeout a
    /// single hung application would freeze the overlay, so every app element gets one
    /// before it is read. Interface speed depends on this.
    ///
    /// 0.25s is generous in the steady state (measured under 1ms per app), but immediately
    /// after a macOS Space transition — entering or switching full-screen — the WindowServer
    /// and other apps' AX servers are measurably busier, and a single 0.25s window call can
    /// time out. `windows(of:)` retries on exactly that failure rather than raising this
    /// further, since a blanket increase would cost every steady-state call to fix a
    /// transient one.
    static let messagingTimeout: Float = 0.25

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func copyValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute)
    }

    /// Per-app enumeration outcome, kept distinct from "this app genuinely has zero windows"
    /// so a discovery failure (timeout, disabled AX) can be told apart from a correct empty
    /// result — the distinction Fix 7 diagnostics need to be useful at all.
    struct WindowsResult {
        let windows: [AXUIElement]
        /// nil on success (including a legitimately empty window list); set to the last
        /// AXError seen if every attempt failed.
        let error: AXError?
        /// How many attempts were made before returning, for diagnosing flakiness.
        let attempts: Int
        /// True when a window came from the AXFocusedWindow/AXMainWindow fallback rather
        /// than AXWindows itself — see the doc comment on `windows(of:)`.
        let usedFallback: Bool
    }

    /// Retries transient failures (timeout, "cannot complete") a couple of times with a short
    /// backoff before giving up. A blank array from a hung/slow app right after a Space
    /// transition is exactly the failure mode this recovers from; the retry budget is small
    /// enough that a genuinely dead app still fails fast.
    private static let maxAttempts = 3
    private static let retryDelays: [UInt32] = [15_000, 40_000] // microseconds

    /// `kAXWindowsAttribute` is, for a wide range of apps (confirmed directly: TextEdit,
    /// Preview, Notes, TV — this is not a single app's quirk), silently and *successfully*
    /// Space-gated: it returns `.success` with an **empty array** for an app whose windows
    /// are entirely on a macOS Space other than the one currently displayed. This is not an
    /// AXError, so the retry loop below never sees it and cannot fix it — a completely
    /// different failure mode from a timeout.
    ///
    /// `kAXFocusedWindowAttribute` and `kAXMainWindowAttribute` bypass that gate: queried
    /// directly, both reliably return the app's real, correctly-titled window even when
    /// `kAXWindowsAttribute` reports zero. Any window not already present in the `AXWindows`
    /// result is merged in here.
    ///
    /// This does not recover *every* window of an app with several windows all on a hidden
    /// Space — only its focused/main one — but it guarantees at least one representative
    /// window survives for every running app on every Space, which is what turns "the
    /// switcher only shows the current app" into "every app is present, possibly with fewer
    /// of its background windows than when it's the active Space."
    static func windows(of app: AXUIElement) -> WindowsResult {
        var lastError: AXError = .success
        var primary: [AXUIElement] = []
        var attemptsUsed = 1

        for attempt in 1...maxAttempts {
            attemptsUsed = attempt
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            if error == .success {
                primary = (value as? [AXUIElement]) ?? []
                lastError = .success
                break
            }
            lastError = error
            // Only retry errors known to be transient under system load; an app that
            // legitimately doesn't support the attribute should fail immediately.
            guard error == .cannotComplete || error == .notImplemented || error == .failure,
                  attempt < maxAttempts
            else { break }
            usleep(retryDelays[min(attempt - 1, retryDelays.count - 1)])
        }

        var merged = primary
        var usedFallback = false
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
                  let raw = value
            else { continue }
            let window = raw as! AXUIElement
            if !merged.contains(where: { CFEqual($0, window) }) {
                merged.append(window)
                usedFallback = true
            }
        }

        // A successful AXWindows call plus a successful fallback merge is not a discovery
        // failure — only report the AXError when nothing at all came back.
        let reportedError = merged.isEmpty ? (lastError == .success ? nil : lastError) : nil
        return WindowsResult(
            windows: merged, error: reportedError, attempts: attemptsUsed, usedFallback: usedFallback
        )
    }

    static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let raw = value
        else { return nil }
        var size = CGSize.zero
        guard CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cgSize, &size)
        else { return nil }
        return size
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let raw = value
        else { return nil }
        var point = CGPoint.zero
        guard CFGetTypeID(raw) == AXValueGetTypeID(),
              AXValueGetValue(raw as! AXValue, .cgPoint, &point)
        else { return nil }
        return point
    }

    @discardableResult
    static func setValue(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    // MARK: - AXUIElement → CGWindowID

    private typealias GetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` is private but long-stable, and is the only way to bridge an
    /// Accessibility window to its CoreGraphics window ID. Resolved dynamically so its
    /// absence degrades to a title-based fallback identifier instead of crashing.
    private static let getWindowFn: GetWindowFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var wid: CGWindowID = 0
        guard fn(window, &wid) == .success, wid != 0 else { return nil }
        return wid
    }
}
