import AppKit
import Foundation

/// Enumerates and activates Google Chrome's windows via AppleScript instead of Accessibility.
///
/// `kAXWindowsAttribute` is silently Space-gated (see the doc comment on `AX.windows(of:)`):
/// for a Chrome window sitting on a macOS Space other than the one currently displayed, AX
/// returns nothing for it at all, and the `AXFocusedWindow`/`AXMainWindow` fallback recovers
/// at most one window — never every hidden window an app has. Confirmed directly on this
/// machine: with two real Chrome windows open across Spaces, AX enumeration found exactly one,
/// via that fallback.
///
/// Chrome's own "windows" AppleScript collection is a separate IPC path (Apple Events, not
/// Accessibility/WindowServer) and is not subject to that gating — querying it while on a
/// different Space still returns every open window, confirmed live. It also supports
/// activating a window by id, which macOS resolves correctly even across a Space switch,
/// closing the gap CoreGraphics-only discovery could not: CGWindowList can list windows across
/// Spaces too, but gives no way to raise one, since it carries no actionable handle.
///
/// Trade-off accepted deliberately: Chrome's scripting dictionary exposes a tab's title, not
/// the OS-level window title AX gives (which includes " - <Profile Name>"), and no profile
/// property at all. Windows here get a generic label; never blocking on profile-name detection
/// matters more than having it. This also only reaches the single Chrome instance Launch
/// Services resolves for "Google Chrome" — a second, separately-launched Chrome process
/// (e.g. started with `--profile-directory` via `open -na`) is a different scripting target
/// this does not address.
enum ChromeAppleScriptProvider {

    struct ChromeWindow {
        let id: Int
        let title: String
        let bounds: CGRect
        let isMinimized: Bool
        /// 1-based, frontmost first, matching Chrome's own AppleScript `index of window`.
        let index: Int
    }

    private static let fieldDelimiter = "\u{1}"
    private static let recordDelimiter = "\u{2}"

    /// nil when Chrome isn't running the script (not installed, no windows, or the query
    /// itself failed); empty array is a legitimate "Chrome is running with zero windows".
    /// Automation permission being denied also lands here as nil rather than throwing, so a
    /// declined prompt just falls back to whatever Accessibility alone can see.
    static func windows() -> [ChromeWindow]? {
        let source = """
        tell application "Google Chrome"
            set output to {}
            repeat with w in windows
                set b to bounds of w
                set end of output to (id of w as text) & "\(fieldDelimiter)" & (name of w) & "\(fieldDelimiter)" & (minimized of w as text) & "\(fieldDelimiter)" & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & "\(fieldDelimiter)" & (index of w as text)
            end repeat
            set AppleScript's text item delimiters to "\(recordDelimiter)"
            set joined to output as text
            set AppleScript's text item delimiters to ""
            return joined
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("[WorkSwitch] Chrome AppleScript window enumeration failed: \(errorInfo)")
            return nil
        }
        guard let joined = result.stringValue, !joined.isEmpty else { return [] }

        return joined.components(separatedBy: recordDelimiter).compactMap { record in
            let fields = record.components(separatedBy: fieldDelimiter)
            guard fields.count == 5, let id = Int(fields[0]), let index = Int(fields[4]) else {
                return nil
            }
            let edges = fields[3].components(separatedBy: ",").compactMap { Double($0) }
            guard edges.count == 4 else { return nil }
            // AppleScript bounds are {left, top, right, bottom}, not {x, y, width, height}.
            let bounds = CGRect(
                x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1]
            )
            return ChromeWindow(id: id, title: fields[1], bounds: bounds, isMinimized: fields[2] == "true", index: index)
        }
    }

    /// Raises a specific window by id, switching Spaces if needed — the activation path AX
    /// gives for free but CoreGraphics-only discovery cannot provide.
    @discardableResult
    static func activate(windowID: Int) -> Bool {
        let source = """
        tell application "Google Chrome"
            activate
            set index of window id \(windowID) to 1
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("[WorkSwitch] Chrome AppleScript activation failed for window \(windowID): \(errorInfo)")
        }
        return errorInfo == nil
    }
}
