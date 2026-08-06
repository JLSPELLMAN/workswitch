import AppKit
import ApplicationServices
import BridgeShared
import Foundation
import Security

/// Startup identity reporting.
///
/// When the Accessibility grant silently stops working, the cause is almost always that the
/// running binary is not the one macOS granted — either it was re-signed with a new identity,
/// or a different copy is being launched. Both are invisible without printing what is
/// actually running, so the app reports its own identity on every launch.
enum Diagnostics {

    /// Where `make install` puts the app. Anything else is a stale or duplicate copy.
    static var canonicalBundlePath: String {
        NSHomeDirectory() + "/Applications/WorkSwitch.app"
    }

    struct Report {
        var bundleIdentifier: String?
        var bundlePath: String
        var executablePath: String?
        var isTrusted: Bool
        var designatedRequirement: String?
        var isAdHocSigned: Bool
        var isRunningFromCanonicalPath: Bool
    }

    static func current() -> Report {
        let bundle = Bundle.main
        let signing = signingInfo()

        return Report(
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundle.bundleURL.path,
            executablePath: bundle.executableURL?.path,
            isTrusted: AXIsProcessTrusted(),
            designatedRequirement: signing.requirement,
            isAdHocSigned: signing.isAdHoc,
            isRunningFromCanonicalPath: bundle.bundleURL
                .standardizedFileURL.path == URL(fileURLWithPath: canonicalBundlePath)
                .standardizedFileURL.path
        )
    }

    /// Startup diagnostics are also written here, rewritten on each launch.
    ///
    /// NSLog output from a self-signed app does not reliably surface in the unified log, and
    /// a menu-bar app has no console to watch. Without a file there is no way to see the
    /// app's *own* trust state — running the binary from a terminal reports the terminal's
    /// grant instead, because TCC attributes a child process to whatever launched it.
    static var logFileURL: URL {
        BridgeSocket.supportDirectory.appendingPathComponent("startup.log")
    }

    private static func writeLogFile(_ report: Report) {
        let formatter = ISO8601DateFormatter()
        let contents = """
        WorkSwitch startup diagnostics
        written: \(formatter.string(from: Date()))

        \(formattedReport(report))

        Reset command if the grant is stale:
          \(resetCommand)

        """
        do {
            try FileManager.default.createDirectory(
                at: BridgeSocket.supportDirectory, withIntermediateDirectories: true
            )
            try contents.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[WorkSwitch] Could not write startup log: %@", String(describing: error))
        }
    }

    /// Records what each overlay refresh actually found, rewritten on every open.
    ///
    /// This is the tool for diagnosing "the switcher only shows the current app" style
    /// reports: it captures the frontmost app (and whether it's full-screen, since that
    /// puts it in its own Space) alongside exactly what got enumerated, so a Space-related
    /// regression shows up as data instead of having to be reproduced live under a debugger.
    static var refreshLogFileURL: URL {
        BridgeSocket.supportDirectory.appendingPathComponent("last_refresh.log")
    }

    /// Every recorded activation, appended (not rewritten) — the point is the *sequence*,
    /// which a single rewritten-each-time file like `last_refresh.log` can't show. Same reason
    /// this exists at all rather than relying on `NSLog`: it doesn't reliably surface in the
    /// unified log for a self-signed app (see `logStartup`'s doc comment).
    static var activityLogFileURL: URL {
        BridgeSocket.supportDirectory.appendingPathComponent("activity.log")
    }

    private static let activityLogMaxLines = 500

    static func logActivity(
        source: String, previous: String?, new: String, title: String, appName: String,
        lastActivatedAt: Date, interactionCount: Int, top5: [String]
    ) {
        let formatter = ISO8601DateFormatter()
        let line = """
        \(formatter.string(from: Date())) [\(source)] previous=\(previous ?? "nil") \
        new=\(new) (\(appName): \(title)) lastActivatedAt=\(formatter.string(from: lastActivatedAt)) \
        interactionCount=\(interactionCount) top5=[\(top5.joined(separator: " | "))]
        """
        do {
            try FileManager.default.createDirectory(
                at: BridgeSocket.supportDirectory, withIntermediateDirectories: true
            )
            let existing = (try? String(contentsOf: activityLogFileURL, encoding: .utf8)) ?? ""
            var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines.append(line)
            if lines.count > activityLogMaxLines {
                lines.removeFirst(lines.count - activityLogMaxLines)
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: activityLogFileURL, atomically: true, encoding: .utf8
            )
        } catch {
            NSLog("[WorkSwitch] Could not write activity log: %@", String(describing: error))
        }
    }

    static func logRefresh(
        destinations: [Destination],
        report: NativeWindowProvider.DiscoveryReport?,
        chromeTabCount: Int,
        isExtensionConnected: Bool,
        invokedFrom: NSRunningApplication?
    ) {
        let formatter = ISO8601DateFormatter()
        // The frontmost app at the moment the overlay was invoked, captured before
        // NSApp.activate(ignoringOtherApps:) makes WorkSwitch itself frontmost — querying
        // NSWorkspace.shared.frontmostApplication here would always just say "WorkSwitch".
        let invokedName = invokedFrom?.localizedName ?? "nil"
        let isFullScreen = invokedFrom.map(Self.isAppFullScreen) ?? false

        var lines = [
            "WorkSwitch refresh diagnostics",
            "written: \(formatter.string(from: Date()))",
            "invoked from: \(invokedName) (fullScreen: \(isFullScreen))",
            "AXIsProcessTrusted: \(AXIsProcessTrusted())",
            "chrome extension connected: \(isExtensionConnected), tabs received: \(chromeTabCount)",
            "overlay level/collectionBehavior: \(OverlayPanel.diagnosticDescription)",
            "destination count: \(destinations.count)",
        ]

        if let report {
            lines.append("")
            lines.append("── discovery (Fix 7) ──")
            lines.append("total running applications: \(report.totalRunningApps)")
            lines.append("eligible (.regular) applications: \(report.eligibleApps)")
            lines.append("total raw AX windows returned: \(report.totalRawWindows)")
            lines.append("total accepted destinations: \(report.totalAcceptedDestinations)")

            let zeroWindowApps = report.appsWithZeroRawWindows
            lines.append("apps that returned zero windows (\(zeroWindowApps.count)): \(zeroWindowApps.joined(separator: ", "))")

            let errored = report.appsWithErrors
            if errored.isEmpty {
                lines.append("apps with AX errors: none")
            } else {
                lines.append("apps with AX errors (\(errored.count)):")
                for entry in errored { lines.append("  - \(entry.app): AXError \(entry.error)") }
            }

            lines.append("")
            lines.append("── per-app detail ──")
            for info in report.perApp {
                let errorText = info.axError.map { " ERROR=\($0)" } ?? ""
                let fallbackText = info.usedFallback ? " [used AXFocusedWindow/AXMainWindow fallback]" : ""
                lines.append(
                    "  \(info.appName) (pid \(info.pid)): raw=\(info.rawWindowCount) "
                    + "accepted=\(info.acceptedCount) attempts=\(info.attempts)\(errorText)\(fallbackText)"
                )
                if !info.filterReasons.isEmpty {
                    lines.append("      filtered: \(info.filterReasons.joined(separator: "; "))")
                }
            }

            lines.append("")
            lines.append("[Chrome Window Discovery — Accessibility path, diagnostic only]")
            lines.append(
                "This section is proof of *why* AX under-counts Chrome's windows, kept for "
                + "transparency — it no longer feeds the UI. See [Destination Pipeline] below "
                + "for what actually populates the switcher."
            )
            lines.append("Raw Chrome windows found via AX: \(report.chromeWindows.count)")
            lines.append("Accepted by the AX path: \(report.chromeAcceptedCount)")
            lines.append("Rejected by the AX path: \(report.chromeRejectedCount)")
            lines.append("")
            for (index, entry) in report.chromeWindows.enumerated() {
                lines.append("  [\(index)] pid=\(entry.pid) bundleID=\(entry.bundleID ?? "nil") appName=\(entry.appName)")
                lines.append("      AX element: \(entry.axElementDescription)")
                lines.append("      CGWindowID: \(entry.cgWindowID.map(String.init) ?? "nil (private AX↔CG bridge unavailable)")")
                lines.append("      AXTitle: \"\(entry.axTitle)\"")
                lines.append("      AXRole: \(entry.axRole ?? "nil")  AXSubrole: \(entry.axSubrole ?? "nil")")
                lines.append("      AXPosition: \(entry.axPosition.map { "(\($0.x), \($0.y))" } ?? "nil")"
                    + "  AXSize: \(entry.axSize.map { "(\($0.width), \($0.height))" } ?? "nil")")
                lines.append("      minimized: \(entry.isMinimized)  fullscreen: \(entry.isFullScreen.map(String.init) ?? "unknown")")
                lines.append("      onscreen: \(entry.isOnscreen.map(String.init) ?? "unknown")  space: \(entry.spaceNote)")
                if entry.rejected {
                    lines.append("      REJECTED — reason: \(entry.rejectionReason ?? "unknown")")
                } else {
                    lines.append("      accepted — destination ID: \(entry.destinationID ?? "nil")")
                }
            }

            lines.append("")
            lines.append("[Destination Pipeline]")
            lines.append(
                "Chrome native windows are discovered via AppleScript (ChromeAppleScriptProvider), "
                + "not the AX path above — AX alone silently under-counts Chrome's windows on "
                + "inactive Spaces (see the section above), and Chrome's own AppleScript "
                + "\"windows\" collection is not subject to that gating."
            )
            let chromeFromScript = destinations.filter { $0.chromeAppleScriptWindowID != nil }
            lines.append("Chrome AppleScript windows found: \(report.chromeAppleScriptWindowCount)")
            lines.append("Chrome AppleScript error: \(report.chromeAppleScriptError ?? "none")")
            if report.chromeAppleScriptError != nil {
                lines.append(
                    "  falling back to the AX path's \(report.chromeAcceptedCount) window(s) — "
                    + "check System Settings → Privacy & Security → Automation → WorkSwitch → "
                    + "Google Chrome is enabled"
                )
            }
            lines.append("Chrome destinations after discovery (AppleScript path): \(chromeFromScript.count)")
            lines.append(
                "Chrome destinations after normalization: \(chromeFromScript.count) "
                + "(no separate normalization stage exists — each window maps directly to one Destination)"
            )
            let distinctChromeIDs = Set(chromeFromScript.map(\.id)).count
            lines.append(
                "Chrome destinations after deduplication: \(chromeFromScript.count) "
                + "(no dictionary/grouping step exists; each destination's id is "
                + "\"native:<bundleID>:as<AppleScript window id>\", unique per window by "
                + "construction — verified below by distinct-ID count)"
            )
            lines.append("  distinct Chrome destination IDs: \(distinctChromeIDs)")
            let chromeInFinal = destinations.filter {
                ($0.bundleID ?? "").hasPrefix(NativeWindowProvider.chromeBundlePrefix)
                    && $0.type == .nativeWindow
            }.count
            lines.append("Chrome native-window destinations passed to UI (post merge): \(chromeInFinal)")
            if isExtensionConnected && chromeTabCount > 0 {
                lines.append(
                    "  note: Chrome extension is connected with \(chromeTabCount) tab(s) — "
                    + "DestinationMerger suppresses ALL native Chrome windows whenever this is "
                    + "true, replacing them with tabs. That suppression is unconditional on "
                    + "profile, so if the connected profile differs from other open Chrome "
                    + "windows' profiles, those other windows disappear from the UI entirely "
                    + "regardless of what discovery above found."
                )
            }
        }

        lines.append("")
        lines.append("── destinations ──")
        for destination in destinations {
            let visibility = "visible=\(destination.isCurrentlyVisible) "
                + "onCurrentSpace=\(destination.isOnCurrentSpace.map(String.init) ?? "unknown") "
                + "minimized=\(destination.isMinimized)"
            lines.append("  - [\(destination.type.rawValue)] \(destination.appName): \(destination.displayTitle) (\(visibility))")
        }

        do {
            try FileManager.default.createDirectory(
                at: BridgeSocket.supportDirectory, withIntermediateDirectories: true
            )
            try lines.joined(separator: "\n").write(
                to: refreshLogFileURL, atomically: true, encoding: .utf8
            )
        } catch {
            NSLog("[WorkSwitch] Could not write refresh log: %@", String(describing: error))
        }
    }

    /// True when the app's frontmost window is in macOS full-screen mode, i.e. running in
    /// its own dedicated Space rather than sharing the desktop Space with everything else.
    private static func isAppFullScreen(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &window
        ) == .success, let window else { return false }

        var fullScreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, "AXFullScreen" as CFString, &fullScreenValue
        ) == .success else { return false }
        return (fullScreenValue as? Bool) ?? false
    }

    static func logStartup() {
        let report = current()
        writeLogFile(report)

        NSLog("[WorkSwitch] ───── startup diagnostics ─────")
        NSLog("[WorkSwitch] bundleIdentifier : %@", report.bundleIdentifier ?? "nil")
        NSLog("[WorkSwitch] bundleURL.path   : %@", report.bundlePath)
        NSLog("[WorkSwitch] executableURL    : %@", report.executablePath ?? "nil")
        NSLog("[WorkSwitch] AXIsProcessTrusted: %@", report.isTrusted ? "true" : "false")
        NSLog("[WorkSwitch] signature        : %@", report.isAdHocSigned ? "ad-hoc" : "certificate")
        NSLog("[WorkSwitch] designated req   : %@", report.designatedRequirement ?? "unavailable")

        if !report.isRunningFromCanonicalPath {
            NSLog("""
            [WorkSwitch] WARNING: running from a non-canonical path. \
            Expected %@. Different copies are different TCC identities, so a grant given to \
            one will not apply here.
            """, canonicalBundlePath)
        }

        if report.isAdHocSigned {
            NSLog("""
            [WorkSwitch] WARNING: ad-hoc signature. The designated requirement is the \
            binary's cdhash, so the Accessibility grant will break on every rebuild. \
            Fix once with: make signing-identity
            """)
        }

        NSLog("[WorkSwitch] ────────────────────────────────")
    }

    /// Human-readable block used by the troubleshooting UI, `--diagnose`, and the log file.
    static func formattedReport() -> String {
        formattedReport(current())
    }

    static func formattedReport(_ report: Report) -> String {
        var lines = [
            "bundleIdentifier:  \(report.bundleIdentifier ?? "nil")",
            "bundleURL.path:    \(report.bundlePath)",
            "executableURL:     \(report.executablePath ?? "nil")",
            "AXIsProcessTrusted: \(report.isTrusted)",
            "signature:         \(report.isAdHocSigned ? "ad-hoc (unstable)" : "certificate (stable)")",
            "designated req:    \(report.designatedRequirement ?? "unavailable")",
        ]
        if !report.isRunningFromCanonicalPath {
            lines.append("WARNING:           not running from \(canonicalBundlePath)")
        }
        return lines.joined(separator: "\n")
    }

    static var resetCommand: String {
        "tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "com.lorenzospellman.workswitch")"
    }

    // MARK: - Code signing

    private static func signingInfo() -> (requirement: String?, isAdHoc: Bool) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL, [], &staticCode
        ) == errSecSuccess, let staticCode else {
            return (nil, false)
        }

        var requirementText: String?
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
                requirementText = text as String?
            }
        }

        // An ad-hoc signature sets the adhoc flag in the code signature's flags word.
        var isAdHoc = false
        var information: CFDictionary?
        if SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
           let info = information as? [String: Any],
           let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            let adhocFlag: UInt32 = 0x0000_0002
            isAdHoc = (flags & adhocFlag) != 0
        }

        return (requirementText, isAdHoc)
    }
}
