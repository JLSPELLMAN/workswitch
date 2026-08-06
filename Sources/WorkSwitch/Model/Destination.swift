import AppKit
import ApplicationServices

/// The kind of work surface a destination points at.
/// Milestone 1 only produces `.nativeWindow`; `.browserTab` arrives with the Chrome bridge.
enum DestinationType: String, Codable {
    case nativeWindow = "native_window"
    case browserTab = "browser_tab"

    var badge: String {
        switch self {
        case .nativeWindow: return "Window"
        case .browserTab: return "Tab"
        }
    }
}

/// The normalized cross-app destination model.
///
/// Every field from the product spec lives here even though Milestone 1 only fills the
/// native-window subset. Chrome tabs populate `url`/`domain`/`browserProfile`/`tabID`/
/// `browserWindowID` and reuse everything else unchanged, so Milestone 2 adds a provider
/// rather than reshaping the model, the ranker, or the UI.
struct Destination: Identifiable {

    // Identity
    let id: String
    var type: DestinationType

    // Presentation
    var appName: String
    var bundleID: String?
    var title: String

    // Browser fields (Milestone 2)
    var url: String?
    var domain: String?
    var browserProfile: String?
    var tabID: Int?
    var browserWindowID: Int?

    // Native handles
    var pid: pid_t
    var windowID: CGWindowID?

    // Behavioral fields (persisted from Milestone 3; in-memory for now)
    var lastActivated: Date?
    var visitCount: Int = 0
    var totalActiveDuration: TimeInterval = 0

    // State
    var isActive: Bool = false
    var isMinimized: Bool = false
    var isPinned: Bool = false
    var isHidden: Bool = false

    /// Informational only — never used to exclude a destination from the list. A window on
    /// another Space, behind another window, or belonging to a hidden app is just as valid
    /// a destination as one currently on screen; these exist so ranking/presentation can use
    /// the distinction without enumeration depending on it.
    var isCurrentlyVisible: Bool = false
    /// nil when the window couldn't be bridged to a CGWindowID and the answer is unknown,
    /// rather than defaulting to false and implying "not on this Space" incorrectly.
    var isOnCurrentSpace: Bool?

    /// Front-to-back index from CGWindowList; lower is closer to the front.
    /// Seeds most-recently-used ordering before any activation history exists.
    var zOrder: Int = Int.max

    /// Live Accessibility handle used for activation. Not part of identity.
    var axWindow: AXUIElement?

    /// Set instead of `axWindow` for a Chrome window discovered via AppleScript rather than
    /// Accessibility — see `ChromeAppleScriptProvider`. Chrome's AppleScript window id has no
    /// public bridge to an `AXUIElement`, so activation for these routes through AppleScript
    /// too, in `WindowActivator`.
    var chromeAppleScriptWindowID: Int?

    /// For browser tabs: which extension connection (i.e. which Chrome profile) owns this
    /// tab, so an activation command is routed back to the profile it came from.
    var connectionID: NativeMessagingServer.ConnectionID?

    /// Real windows can legitimately have no AX title (some Finder and Preview windows),
    /// so they get a readable label instead of being dropped from the list.
    var displayTitle: String {
        title.isEmpty ? "\(appName) — Untitled" : title
    }

    var icon: NSImage? {
        if let running = NSRunningApplication(processIdentifier: pid), let icon = running.icon {
            return icon
        }
        // A browser tab still needs the Chrome icon even when the PID lookup misses.
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

extension Destination: Hashable {
    static func == (lhs: Destination, rhs: Destination) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Debug serialization

extension Destination {
    /// Backs `--dump-destinations`, which lets enumeration and filtering be verified
    /// headlessly without any GUI interaction.
    var debugDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "type": type.rawValue,
            "app_name": appName,
            "title": title,
            "display_title": displayTitle,
            "pid": Int(pid),
            "is_active": isActive,
            "is_minimized": isMinimized,
            "is_currently_visible": isCurrentlyVisible,
            "z_order": zOrder == Int.max ? -1 : zOrder,
        ]
        if let isOnCurrentSpace { dict["is_on_current_space"] = isOnCurrentSpace }
        if let bundleID { dict["bundle_id"] = bundleID }
        if let windowID { dict["window_id"] = Int(windowID) }
        if let url { dict["url"] = url }
        if let domain { dict["domain"] = domain }
        if let browserProfile { dict["browser_profile"] = browserProfile }
        return dict
    }
}
