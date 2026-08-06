import AppKit
import ApplicationServices
import Foundation

// MARK: - Headless debug path
//
// `--dump-destinations` prints the filtered destination list as JSON and exits. Run from a
// terminal that already holds Accessibility permission, this verifies enumeration, title
// resolution, and filtering without any GUI interaction.

// Prints this build's identity and live trust state, then exits. Backs `make doctor`.
if CommandLine.arguments.contains("--diagnose") {
    print(MainActor.assumeIsolated { Diagnostics.formattedReport() })
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

if CommandLine.arguments.contains("--dump-destinations") {
    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(Data("""
        Accessibility permission is not granted for this process.
        Grant it to the host terminal (System Settings → Privacy & Security → Accessibility),
        or run the bundled app instead.

        """.utf8))
        exit(1)
    }

    let (destinations, report) = MainActor.assumeIsolated {
        NativeWindowProvider().enumerateWithDiagnostics()
    }
    let payload: [String: Any] = [
        "count": destinations.count,
        "destinations": destinations.map(\.debugDictionary),
        "discovery": [
            "total_running_applications": report.totalRunningApps,
            "eligible_applications": report.eligibleApps,
            "total_raw_ax_windows": report.totalRawWindows,
            "total_accepted_destinations": report.totalAcceptedDestinations,
            "apps_with_zero_windows": report.appsWithZeroRawWindows,
            "apps_with_errors": report.appsWithErrors.map { ["app": $0.app, "error": $0.error] },
            "per_app": report.perApp.map { info -> [String: Any] in
                var dict: [String: Any] = [
                    "app_name": info.appName,
                    "pid": Int(info.pid),
                    "raw_window_count": info.rawWindowCount,
                    "accepted_count": info.acceptedCount,
                    "attempts": info.attempts,
                    "used_fallback": info.usedFallback,
                    "filter_reasons": info.filterReasons,
                ]
                if let bundleID = info.bundleID { dict["bundle_id"] = bundleID }
                if let axError = info.axError { dict["ax_error"] = axError }
                return dict
            },
        ],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

// MARK: - Normal launch

let application = NSApplication.shared
// Menu-bar only: no Dock icon, no app menu. Matches LSUIElement in Info.plist and keeps
// the overlay from behaving like a conventional document app.
application.setActivationPolicy(.accessory)

// Top-level code is not main-actor isolated, but this runs on the main thread before the
// run loop starts. The global binding also keeps the delegate alive, since
// `NSApplication.delegate` is a weak reference.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
