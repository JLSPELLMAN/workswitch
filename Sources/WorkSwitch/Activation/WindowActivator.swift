import AppKit
import ApplicationServices

enum ActivationResult {
    case success
    case failure(String)
}

/// Focuses the exact window a destination points at.
///
/// Reliability of activation is the top engineering priority, so the sequence below is
/// deliberate and ordered. Raising without activating leaves the app unfocused; activating
/// without raising surfaces the app's *last* window rather than the chosen one. Both steps
/// are required, in this order.
enum WindowActivator {

    @discardableResult
    static func activate(_ destination: Destination) -> ActivationResult {
        switch destination.type {
        case .nativeWindow:
            return activateNativeWindow(destination)
        case .browserTab:
            // Tabs are routed through `BridgeCoordinator`, which owns the extension
            // connection. Reaching here means a caller bypassed that routing.
            return .failure("Browser tabs must be activated through the Chrome bridge")
        }
    }

    private static func activateNativeWindow(_ destination: Destination) -> ActivationResult {
        if let scriptWindowID = destination.chromeAppleScriptWindowID {
            return ChromeAppleScriptProvider.activate(windowID: scriptWindowID)
                ? .success
                : .failure("Chrome AppleScript activation failed for \(destination.displayTitle)")
        }

        guard let window = destination.axWindow else {
            return .failure("No accessibility handle for \(destination.displayTitle)")
        }
        guard let app = NSRunningApplication(processIdentifier: destination.pid) else {
            return .failure("\(destination.appName) is no longer running")
        }

        let appElement = AX.application(pid: destination.pid)

        // 1. Restore a minimized window before anything can focus it.
        if destination.isMinimized {
            AX.setValue(window, kAXMinimizedAttribute, kCFBooleanFalse)
        }

        // 2. Mark the app frontmost via AX — the AX-level equivalent of a real user click
        // on the app. Without this, `app.activate()` alone can leave the raised window only
        // *visually* frontmost without giving it true key-window status, so the very next
        // real click on it (e.g. a toolbar button) gets eaten just bringing the window to
        // key instead of acting on the control — the window then needs a second click to
        // actually register anything.
        AX.setValue(appElement, kAXFrontmostAttribute, kCFBooleanTrue)

        // 3. Tell the app which of its windows should be focused.
        AX.setValue(appElement, kAXFocusedWindowAttribute, window)

        // 4. Bring that window to the front within its app.
        let raised = AX.perform(window, kAXRaiseAction)

        // 5. Bring the app itself to the front (Dock/menu bar bookkeeping; belt-and-braces
        // alongside the AX frontmost attribute above).
        let activated = app.activate()

        if !raised && !activated {
            return .failure("Could not focus \(destination.displayTitle)")
        }
        return .success
    }
}
