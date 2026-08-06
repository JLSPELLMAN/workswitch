import AppKit
import ApplicationServices
import CoreGraphics

/// Enumerates meaningful native macOS windows.
///
/// Accessibility is the primary source (it is the only one that yields titles), and
/// CoreGraphics is used strictly as a supplement for on-screen state and z-order.
/// CoreGraphics also over-reports: a single Chrome window surfaces as several layer-0
/// compositing surfaces, whereas Accessibility reports the one logical window.
///
/// Enumeration is intentionally unconditional on Space, screen, frontmost app, or on-screen
/// state: every `.regular` running app is queried, regardless of which Space its windows are
/// on, whether it's hidden, or whether it's currently frontmost. The one CoreGraphics call in
/// this file (`buildZOrderIndex`) uses `.optionOnScreenOnly`, but only to seed ranking order
/// and the informational `isOnCurrentSpace`/`isCurrentlyVisible` fields — never to decide
/// which destinations are included. Do not change that: an onscreen-only query determining
/// inclusion is exactly the bug this file was rewritten to fix.
///
/// `@unchecked Sendable` is accurate here: every stored property is a `let`, so instances
/// carry no mutable state across the enumeration queue.
final class NativeWindowProvider: DestinationProvider, @unchecked Sendable {

    let typeName = "native_window"

    /// Windows smaller than this are chrome, not content — Control Center strips and
    /// similar accessory surfaces sit well under it.
    private let minimumSize = CGSize(width: 120, height: 80)

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Per-app enumeration outcome, kept for diagnostics (Fix 7): distinguishing a discovery
    /// failure (AX error/timeout) from a working app that correctly filtered down to nothing.
    struct AppDiscoveryInfo {
        let appName: String
        let bundleID: String?
        let pid: pid_t
        let rawWindowCount: Int
        let axError: String?
        let attempts: Int
        let usedFallback: Bool
        let acceptedCount: Int
        let filterReasons: [String]
    }

    struct DiscoveryReport {
        var totalRunningApps: Int = 0
        var eligibleApps: Int = 0
        var perApp: [AppDiscoveryInfo] = []
        /// Every raw AX window belonging to a Chrome-family app, accepted or not — see
        /// `ChromeWindowDiscoveryEntry`. Populated regardless of whether Chrome is even
        /// running, so an empty array here is itself informative (0 Chrome windows exist,
        /// as opposed to "existing windows got filtered out").
        var chromeWindows: [ChromeWindowDiscoveryEntry] = []
        /// Real, used-for-the-UI Chrome window count, from `ChromeAppleScriptProvider` — as
        /// opposed to `chromeWindows` above, which is purely AX diagnostics and is no longer
        /// what actually populates the destination list for Chrome.
        var chromeAppleScriptWindowCount: Int = 0
        var chromeAppleScriptError: String?

        var totalRawWindows: Int { perApp.reduce(0) { $0 + $1.rawWindowCount } }
        var totalAcceptedDestinations: Int { perApp.reduce(0) { $0 + $1.acceptedCount } }
        var appsWithZeroRawWindows: [String] { perApp.filter { $0.rawWindowCount == 0 }.map(\.appName) }
        var appsWithErrors: [(app: String, error: String)] {
            perApp.compactMap { info in info.axError.map { (info.appName, $0) } }
        }

        var chromeAcceptedCount: Int { chromeWindows.filter { !$0.rejected }.count }
        var chromeRejectedCount: Int { chromeWindows.filter { $0.rejected }.count }
    }

    /// One raw AX window belonging to a Chrome-family process, captured before any filtering
    /// decision, so a rejection is provable from the log rather than asserted.
    struct ChromeWindowDiscoveryEntry {
        let pid: pid_t
        let bundleID: String?
        let appName: String
        let axElementDescription: String
        let cgWindowID: CGWindowID?
        let axTitle: String
        let axRole: String?
        let axSubrole: String?
        let axPosition: CGPoint?
        let axSize: CGSize?
        let isMinimized: Bool
        let isFullScreen: Bool?
        /// nil when no CGWindowID could be resolved (bridge unavailable), so "unknown" and
        /// "not on screen" stay distinguishable.
        let isOnscreen: Bool?
        /// macOS exposes no public API to name an arbitrary window's Space directly; this
        /// explains what the on-screen signal does and doesn't tell you, rather than
        /// asserting a Space membership this code cannot actually verify.
        let spaceNote: String
        let rejected: Bool
        let rejectionReason: String?
        let destinationID: String?
    }

    func enumerate() -> [Destination] {
        enumerateWithDiagnostics().destinations
    }

    func enumerateWithDiagnostics() -> (destinations: [Destination], report: DiscoveryReport) {
        var report = DiscoveryReport()

        guard AXIsProcessTrusted() else { return ([], report) }

        let zOrderIndex = buildZOrderIndex()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
        report.totalRunningApps = runningApps.count

        var destinations: [Destination] = []
        // Kept aside rather than discarded: if AppleScript can't run (Automation permission
        // not yet granted, most commonly, the first time this ships), this is the fallback —
        // strictly worse than the AppleScript path (only the one window AX isn't Space-gating
        // away), but strictly better than silently dropping Chrome to zero results.
        var axChromeDestinations: [Destination] = []

        for app in runningApps {
            // `.regular` excludes daemons, agents, and menu-bar-only helpers. This is the
            // only filter applied before querying AX — it does not depend on Space,
            // visibility, hidden state, or whether the app is frontmost.
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  app.processIdentifier > 0
            else { continue }
            report.eligibleApps += 1

            let appName = app.localizedName ?? "Unknown"
            let bundleID = app.bundleIdentifier
            let appElement = AX.application(pid: app.processIdentifier)

            let result = AX.windows(of: appElement)
            var filterReasons: [String] = []
            var accepted = 0
            let isChromeFamily = (bundleID ?? "").hasPrefix(Self.chromeBundlePrefix)

            for window in result.windows {
                var rejectionReason: String?
                let destination = makeDestination(
                    window: window,
                    pid: app.processIdentifier,
                    appName: appName,
                    bundleID: bundleID,
                    isFrontmostApp: app.processIdentifier == frontmostPID,
                    zOrderIndex: zOrderIndex,
                    filterReasons: &filterReasons,
                    rejectionReason: &rejectionReason
                )
                if let destination {
                    accepted += 1
                    // AX-derived Chrome destinations are kept out of the main list and set
                    // aside instead: AX only ever sees the one window that isn't Space-gated
                    // away, so including it here would just be a redundant, less-complete
                    // duplicate of what `chromeAppleScriptDestinations` below produces for all
                    // of Chrome's windows. The AX pass still runs, unconditionally, so the
                    // diagnostics above stay truthful about what Accessibility itself actually
                    // returns, and `axChromeDestinations` is the fallback if AppleScript can't
                    // run at all.
                    if isChromeFamily {
                        axChromeDestinations.append(destination)
                    } else {
                        destinations.append(destination)
                    }
                }
                if isChromeFamily {
                    report.chromeWindows.append(chromeDiagnosticEntry(
                        window: window,
                        pid: app.processIdentifier,
                        bundleID: bundleID,
                        appName: appName,
                        zOrderIndex: zOrderIndex,
                        rejectionReason: rejectionReason,
                        destination: destination
                    ))
                }
            }

            report.perApp.append(AppDiscoveryInfo(
                appName: appName,
                bundleID: bundleID,
                pid: app.processIdentifier,
                rawWindowCount: result.windows.count,
                axError: result.error.map { "\($0.rawValue)" },
                attempts: result.attempts,
                usedFallback: result.usedFallback,
                acceptedCount: accepted,
                filterReasons: filterReasons
            ))
        }

        let (chromeDestinations, chromeScriptError) = chromeAppleScriptDestinations(
            zOrderIndex: zOrderIndex, frontmostPID: frontmostPID
        )
        report.chromeAppleScriptWindowCount = chromeDestinations.count
        report.chromeAppleScriptError = chromeScriptError

        if chromeScriptError != nil {
            // AppleScript genuinely failed (as opposed to "Chrome isn't running", which
            // returns no error and an empty array) — fall back rather than show nothing.
            destinations.append(contentsOf: axChromeDestinations)
        } else {
            destinations.append(contentsOf: chromeDestinations)
        }

        return (destinations, report)
    }

    // MARK: - Chrome window discovery (AppleScript)

    /// One raw CGWindowList entry, kept just long enough to bounds-match a Chrome AppleScript
    /// window against the real, globally-ordered on-screen list — giving whichever of Chrome's
    /// windows happens to be visible right now an accurate `zOrder` and on-screen state,
    /// consistent with every other app's native windows, instead of a Chrome-only numbering
    /// that wouldn't compare meaningfully against them in the ranker.
    private func onscreenLayer0Windows(forPID pid: pid_t) -> [(windowID: CGWindowID, bounds: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) == pid,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w >= minimumSize.width, h >= minimumSize.height
            else { return nil }
            return (CGWindowID(number), CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func chromeAppleScriptDestinations(
        zOrderIndex: [CGWindowID: ZOrderEntry],
        frontmostPID: pid_t?
    ) -> (destinations: [Destination], error: String?) {
        guard let chromeApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.chromeBundlePrefix
        }) else {
            return ([], nil) // Chrome isn't running — not an error.
        }
        guard let windows = ChromeAppleScriptProvider.windows() else {
            return ([], "AppleScript enumeration failed or returned nothing — Automation "
                + "permission for WorkSwitch → Google Chrome may not be granted")
        }

        let onscreen = onscreenLayer0Windows(forPID: chromeApp.processIdentifier)
        let isFrontmostApp = chromeApp.processIdentifier == frontmostPID
        let appName = chromeApp.localizedName ?? "Google Chrome"

        let destinations = windows.map { window -> Destination in
            let match = onscreen.first { approximatelyEqual($0.bounds, window.bounds) }
            let zEntry = match.flatMap { zOrderIndex[$0.windowID] }

            return Destination(
                id: Self.chromeDestinationID(appleScriptWindowID: window.id),
                type: .nativeWindow,
                appName: appName,
                bundleID: chromeApp.bundleIdentifier,
                title: window.title,
                pid: chromeApp.processIdentifier,
                windowID: match?.windowID,
                // Only Chrome's own frontmost window (AppleScript index 1) can be "where you
                // are", and only while Chrome itself is the frontmost app.
                isActive: isFrontmostApp && window.index == 1,
                isMinimized: window.isMinimized,
                isCurrentlyVisible: match != nil && !window.isMinimized,
                // A bounds match proves it's on the current Space; no match is ambiguous
                // (could be another Space, or just not layer-0-visible for some other reason)
                // rather than a confident "no", except when it's minimized — that already
                // fully explains the absence.
                isOnCurrentSpace: match != nil ? true : (window.isMinimized ? false : nil),
                zOrder: zEntry?.position ?? (Int.max - 1),
                axWindow: nil,
                chromeAppleScriptWindowID: window.id
            )
        }
        return (destinations, nil)
    }

    // MARK: - Filtering

    private func makeDestination(
        window: AXUIElement,
        pid: pid_t,
        appName: String,
        bundleID: String?,
        isFrontmostApp: Bool,
        zOrderIndex: [CGWindowID: ZOrderEntry],
        filterReasons: inout [String],
        rejectionReason: inout String?
    ) -> Destination? {

        // Standard windows only. This drops sheets, drawers, popovers, palettes,
        // tooltips, and system accessory surfaces in one check. Confirmed live against
        // Chrome specifically: kAXWindowsAttribute returns Chrome's tab strip, bookmark
        // bar, and toolbar as their own top-level AXWindow elements (0 children, empty
        // title) with subrole AXUnknown — this filter is what keeps those out of the list,
        // not a coincidence to revisit.
        guard let subrole = AX.string(window, kAXSubroleAttribute),
              subrole == (kAXStandardWindowSubrole as String)
        else {
            let actual = AX.string(window, kAXSubroleAttribute) ?? "nil"
            filterReasons.append("subrole")
            rejectionReason = "subrole (\(actual), expected AXStandardWindow)"
            return nil
        }

        let isMinimized = AX.bool(window, kAXMinimizedAttribute) ?? false

        // A minimized window reports a zero or stale size, so the size floor is only
        // meaningful for on-screen windows. Minimized windows stay in the list — being
        // able to reach them is a large part of the point, and neither minimized state
        // nor Space membership ever excludes a window here.
        if !isMinimized, let size = AX.size(of: window) {
            guard size.width >= minimumSize.width, size.height >= minimumSize.height else {
                filterReasons.append("too small (\(Int(size.width))x\(Int(size.height)))")
                rejectionReason = "too small (\(Int(size.width))x\(Int(size.height)))"
                return nil
            }
        }

        let title = AX.string(window, kAXTitleAttribute) ?? ""
        let windowID = AX.windowID(of: window)
        let destinationID = Self.destinationID(bundleID: bundleID, appName: appName, windowID: windowID, title: title)

        let zEntry = windowID.flatMap { zOrderIndex[$0] }
        let zOrder = zEntry?.position ?? Int.max

        // Only the frontmost window of the frontmost app is genuinely "where you are".
        // z-order 0 is the front of the layer-0 window layer.
        let isActive = isFrontmostApp && zOrder == 0

        rejectionReason = nil
        return Destination(
            id: destinationID,
            type: .nativeWindow,
            appName: appName,
            bundleID: bundleID,
            title: title,
            pid: pid,
            windowID: windowID,
            isActive: isActive,
            isMinimized: isMinimized,
            isCurrentlyVisible: zEntry != nil && !isMinimized,
            // `kCGWindowListOptionOnScreenOnly` is documented as restricted to windows on
            // the currently displayed Space(s), so presence in that index is a reasonable
            // proxy for Space membership. nil (not false) when the AX↔CG bridge failed,
            // since "unknown" and "not on this Space" are different claims.
            isOnCurrentSpace: windowID != nil ? (zEntry != nil) : nil,
            zOrder: zOrder,
            axWindow: window
        )
    }

    // MARK: - Chrome window discovery diagnostics

    /// Matches release Chrome plus its Beta/Dev/Canary variants, same as
    /// `DestinationMerger.isChromeWindow`.
    static let chromeBundlePrefix = "com.google.Chrome"

    private func chromeDiagnosticEntry(
        window: AXUIElement,
        pid: pid_t,
        bundleID: String?,
        appName: String,
        zOrderIndex: [CGWindowID: ZOrderEntry],
        rejectionReason: String?,
        destination: Destination?
    ) -> ChromeWindowDiscoveryEntry {
        let cgWindowID = AX.windowID(of: window)
        let onscreen = cgWindowID.map { zOrderIndex[$0] != nil }
        let spaceNote = onscreen == true
            ? "present in the on-screen CG window list (current Space)"
            : "absent from the on-screen CG window list — this means one of: on another "
                + "Space, minimized, fully occluded, or off-screen. macOS has no public API "
                + "that names a window's Space directly, so this cannot be narrowed further."

        return ChromeWindowDiscoveryEntry(
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            axElementDescription: String(describing: window),
            cgWindowID: cgWindowID,
            axTitle: AX.string(window, kAXTitleAttribute) ?? "",
            axRole: AX.string(window, kAXRoleAttribute),
            axSubrole: AX.string(window, kAXSubroleAttribute),
            axPosition: AX.point(window, kAXPositionAttribute),
            axSize: AX.size(of: window),
            isMinimized: AX.bool(window, kAXMinimizedAttribute) ?? false,
            isFullScreen: AX.bool(window, "AXFullScreen"),
            isOnscreen: onscreen,
            spaceNote: spaceNote,
            rejected: destination == nil,
            rejectionReason: rejectionReason,
            destinationID: destination?.id
        )
    }

    // MARK: - CoreGraphics supplement

    private struct ZOrderEntry {
        let position: Int
    }

    /// Front-to-back ordering keyed by window ID, restricted to the currently displayed
    /// Space(s). Used only for ordering and the informational visibility fields — never to
    /// decide which destinations are included in the list. See the type-level doc comment.
    private func buildZOrderIndex() -> [CGWindowID: ZOrderEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var index: [CGWindowID: ZOrderEntry] = [:]
        var position = 0
        for entry in info {
            // Layer 0 is the normal application window layer; higher layers are system UI.
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? Int
            else { continue }
            index[CGWindowID(number)] = ZOrderEntry(position: position)
            position += 1
        }
        return index
    }

    private static func stableHash(_ string: String) -> UInt64 {
        // FNV-1a: deterministic across launches, unlike Swift's seeded Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - Shared identity

    /// The single source of truth for a native window's destination id — `static` and public
    /// so the real-time focus-change tracker (`OverlayController`) can build the exact same id
    /// for a window it resolves independently via AX, without duplicating this format and
    /// risking it drifting out of sync with what discovery actually produces. A mismatch here
    /// would silently mean recorded activity never matches the destination it was meant for.
    static func destinationID(bundleID: String?, appName: String, windowID: CGWindowID?, title: String) -> String {
        if let windowID {
            return "native:\(bundleID ?? appName):\(windowID)"
        }
        // Fallback keeps identity stable enough to rank on when the private bridge is
        // unavailable.
        return "native:\(bundleID ?? appName):t\(stableHash(title))"
    }

    /// Mirrors the id format `chromeAppleScriptDestinations` builds inline, for the same
    /// reason as `destinationID(bundleID:appName:windowID:title:)` above.
    static func chromeDestinationID(appleScriptWindowID: Int) -> String {
        "native:\(chromeBundlePrefix):as\(appleScriptWindowID)"
    }
}
