import Foundation

/// Produces the overlay's two display lines — a clean primary title and a secondary
/// app/context line — for any `Destination`, regardless of which app or window kind it came
/// from. Unlike `Destination.displayTitle` (used for search matching, activation error
/// messages, and logging, and deliberately left untouched so none of that behavior changes),
/// this exists purely for presentation and is free to reshape the raw title for readability.
enum DestinationTitleFormatter {

    struct Formatted {
        let primary: String
        let secondary: String
    }

    /// A few apps' window titles carry their marketing/product name rather than the name
    /// Accessibility reports for the running process (e.g. VS Code's process is "Code" but its
    /// windows end in "Visual Studio Code"). This is the one place that mismatch is recorded,
    /// so both the suffix-stripping rule below and the secondary line agree on it. Ordinary
    /// apps whose title suffix already matches their process name (Chrome, Safari, Slack,
    /// Figma, …) need no entry here — the appName-based rule below already catches them.
    private static let appDisplayNameOverrides: [String: String] = [
        "Code": "Visual Studio Code",
    ]

    private static let dashes = [" — ", " – ", " - "]

    static func format(_ destination: Destination) -> Formatted {
        let appName = destination.appName
        let displayAppName = appDisplayNameOverrides[appName] ?? appName
        let rawTitle = destination.title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawTitle.isEmpty else {
            return Formatted(primary: "\(appName) — Untitled", secondary: displayAppName)
        }

        let primary = cleanedPrimary(rawTitle, appName: appName)
        let secondary = secondaryLine(displayAppName: displayAppName, destination: destination, primary: primary)

        return Formatted(primary: primary, secondary: secondary)
    }

    private static func cleanedPrimary(_ title: String, appName: String) -> String {
        var result = title

        // Many apps append their own name to every window title (browsers, editors). It's
        // redundant with the secondary line, so strip it — trying both the Accessibility
        // process name and any known product-name override for that app.
        let candidateSuffixes = [appName] + Array(Set(appDisplayNameOverrides.values))
        suffixLoop: for suffixName in candidateSuffixes {
            for dash in dashes {
                let suffix = dash + suffixName
                if result.hasSuffix(suffix) {
                    result = String(result.dropLast(suffix.count))
                    break suffixLoop
                }
            }
        }

        // Terminal-style trailing pane dimensions ("… — 204×60") carry no real destination
        // info. Terminal.app renders these with the Unicode multiplication sign (×), not an
        // ASCII "x", so both are matched.
        if let range = result.range(of: #" — \d+[x×]\d+$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }

        result = result.trimmingCharacters(in: .whitespaces)

        // A bare filesystem path (no internal spaces) reads as a folder/location name once
        // reduced to its last component — e.g. a Terminal or Finder title of
        // "~/dev/workswitch" becomes "workswitch" instead of showing the full path as noise.
        if (result.hasPrefix("/") || result.hasPrefix("~/")) && !result.contains(" ") {
            let expanded = (result as NSString).expandingTildeInPath
            let last = (expanded as NSString).lastPathComponent
            if !last.isEmpty {
                result = last
            }
        }

        return result.isEmpty ? title : result
    }

    private static func secondaryLine(
        displayAppName: String, destination: Destination, primary: String
    ) -> String {
        var parts = [displayAppName]

        // Only surface domain/profile when they add information the primary line doesn't
        // already show, so the two lines don't repeat each other.
        if let domain = destination.domain, let profile = destination.browserProfile {
            parts.append("\(domain) · \(profile)")
        } else if let domain = destination.domain {
            if !primary.localizedCaseInsensitiveContains(domain) {
                parts.append(domain)
            }
        } else if let profile = destination.browserProfile {
            parts.append(profile)
        }

        return parts.joined(separator: " · ")
    }
}

/// Quiet, glanceable recency text ("Just now", "2m ago", "Today", "Yesterday") for rows that
/// carry a real activation timestamp. Deliberately returns nil — rather than a guess — for
/// destinations whose only "recency" signal is the ranker's synthetic z-order proxy, since
/// that isn't a real point in time and shouldn't be presented as one.
enum RecencyFormatter {
    static func string(for date: Date?, now: Date = Date()) -> String? {
        guard let date, date <= now else { return nil }
        let interval = now.timeIntervalSince(date)

        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return nil
    }
}
