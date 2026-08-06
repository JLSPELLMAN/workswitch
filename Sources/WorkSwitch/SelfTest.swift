import AppKit
import Foundation

/// Assertion checks for the pure ranking and merging logic, reachable via `--self-test`.
///
/// XCTest is not available here: it ships with Xcode, and this machine only has the Command
/// Line Tools SDK. Rather than restructure the package around a testable library, these run
/// through the same debug-flag pattern as `--dump-destinations`. They cover the logic that
/// decides what the user sees, which is the part hardest to eyeball in a running app.
enum SelfTest {

    private static var failures: [String] = []
    private static var passes = 0

    static func run() -> Int32 {
        failures = []
        passes = 0

        duplicateSuppressionTests()
        crossTypeOrderingTests()
        searchTests()
        titleTests()

        print("")
        if failures.isEmpty {
            print("All \(passes) checks passed.")
            return 0
        }
        print("\(failures.count) of \(passes + failures.count) checks FAILED:")
        for failure in failures { print("  - \(failure)") }
        return 1
    }

    // MARK: - Assertions

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
            print("  PASS  \(label)")
        } else {
            failures.append(label)
            print("  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        check(label, actual == expected, "got \(actual), expected \(expected)")
    }

    // MARK: - Fixtures

    private static func window(
        id: String,
        app: String,
        bundle: String?,
        title: String,
        zOrder: Int = 0,
        minimized: Bool = false,
        active: Bool = false
    ) -> Destination {
        Destination(
            id: id, type: .nativeWindow, appName: app, bundleID: bundle, title: title,
            pid: 1, isActive: active, isMinimized: minimized, zOrder: zOrder
        )
    }

    private static func tab(
        id: String,
        title: String,
        domain: String? = nil,
        lastAccessed: Date? = nil,
        pinned: Bool = false,
        active: Bool = false
    ) -> Destination {
        Destination(
            id: id, type: .browserTab, appName: "Google Chrome",
            bundleID: "com.google.Chrome", title: title,
            url: domain.map { "https://\($0)/" }, domain: domain,
            tabID: 1, browserWindowID: 1, pid: 2,
            lastActivated: lastAccessed, isActive: active, isPinned: pinned
        )
    }

    // MARK: - Duplicate suppression

    private static func duplicateSuppressionTests() {
        print("== duplicate suppression ==")

        let native = [
            window(id: "w1", app: "Google Chrome", bundle: "com.google.Chrome", title: "Hacker News"),
            window(id: "w2", app: "Terminal", bundle: "com.apple.Terminal", title: "zsh"),
        ]
        let tabs = [tab(id: "t1", title: "Hacker News", domain: "news.ycombinator.com")]

        let merged = DestinationMerger.merge(
            nativeWindows: native, chromeTabs: tabs, isExtensionConnected: true
        )
        check("Chrome's native window is suppressed when tabs exist", !merged.contains { $0.id == "w1" })
        check("non-Chrome windows survive the merge", merged.contains { $0.id == "w2" })
        check("tabs appear in the merged list", merged.contains { $0.id == "t1" })

        // Without the extension the app must degrade to Milestone 1 behaviour rather than
        // hiding Chrome entirely.
        let degraded = DestinationMerger.merge(
            nativeWindows: native, chromeTabs: [], isExtensionConnected: false
        )
        check("Chrome windows survive when the extension is disconnected",
              degraded.contains { $0.id == "w1" })

        let canary = window(id: "w3", app: "Google Chrome Canary",
                            bundle: "com.google.Chrome.canary", title: "Test")
        check("Chrome channel variants are recognised", DestinationMerger.isChromeWindow(canary))
        check("unrelated apps are not treated as Chrome",
              !DestinationMerger.isChromeWindow(
                  window(id: "w4", app: "Terminal", bundle: "com.apple.Terminal", title: "zsh")))
    }

    // MARK: - Cross-type ordering

    private static func crossTypeOrderingTests() {
        print("== cross-type ordering ==")
        let ranker = Ranker()

        // Chrome reports real timestamps but native windows have none. Without a shared
        // recency basis, every tab would sort above every window.
        let staleTab = tab(id: "t1", title: "Old tab", domain: "example.com",
                           lastAccessed: Date().addingTimeInterval(-86_400))
        let frontWindow = window(id: "w1", app: "Terminal", bundle: "com.apple.Terminal",
                                 title: "zsh", zOrder: 0)
        checkEqual("an on-screen window outranks a day-old tab",
                   ranker.rank([staleTab, frontWindow], query: "").first?.id, "w1")

        let freshTab = tab(id: "t2", title: "Just used", domain: "example.com", lastAccessed: Date())
        let buriedWindow = window(id: "w2", app: "Notes", bundle: "com.apple.Notes",
                                  title: "Notes", zOrder: 40)
        checkEqual("a just-used tab outranks a buried window",
                   ranker.rank([freshTab, buriedWindow], query: "").first?.id, "t2")

        let minimized = window(id: "w3", app: "Preview", bundle: "com.apple.Preview",
                               title: "Paper.pdf", zOrder: 0, minimized: true)
        let onScreen = window(id: "w4", app: "Notes", bundle: "com.apple.Notes",
                              title: "Notes", zOrder: 30)
        checkEqual("minimized windows sink below on-screen ones",
                   ranker.rank([minimized, onScreen], query: "").map(\.id), ["w4", "w3"])

        let current = window(id: "w5", app: "Terminal", bundle: "com.apple.Terminal",
                             title: "zsh", zOrder: 0, active: true)
        let other = window(id: "w6", app: "Notes", bundle: "com.apple.Notes",
                           title: "Notes", zOrder: 5)
        checkEqual("the destination you are already in sorts last",
                   ranker.rank([current, other], query: "").last?.id, "w5")

        // Regression: a window with no resolved on-screen z-order (Chrome windows routinely
        // land here — see `effectiveRecency`'s doc comment for why) must not sort below a
        // destination with a real, but old, timestamp. An earlier version of this fallback
        // scaled z-order into a pseudo-date and mishandled Chrome's specific "unresolved"
        // sentinel, sending it so far into the past it always sorted dead last, even below a
        // tab untouched for a week.
        let unresolvedChromeWindow = window(id: "w7", app: "Google Chrome", bundle: "com.google.Chrome",
                                            title: "Some Page", zOrder: Int.max - 1)
        let weekOldTab = tab(id: "t3", title: "Old page", domain: "example.com",
                             lastAccessed: Date().addingTimeInterval(-7 * 86_400))
        checkEqual("an unresolved-z-order Chrome window still outranks a week-old tab",
                   ranker.rank([weekOldTab, unresolvedChromeWindow], query: "").first?.id, "w7")

        let justUsedTab = tab(id: "t4", title: "Fresh", domain: "example.com", lastAccessed: Date())
        checkEqual("a just-used tab still outranks an unresolved-z-order Chrome window",
                   ranker.rank([justUsedTab, unresolvedChromeWindow], query: "").first?.id, "t4")

        // Regression: two destinations with no real timestamp but wildly different z-order
        // values must land in the same tied bucket, not have one beat the other because of it.
        // z-order flickers unpredictably in practice — Stage Manager and full-screen Spaces
        // change which windows happen to resolve a position from one refresh to the next — so
        // basing ranking on it produced the same overlay, reopened seconds apart, showing two
        // different orderings.
        let untimedA = window(id: "w9", app: "AppA", bundle: "com.example.a", title: "Alpha", zOrder: 0)
        let untimedB = window(id: "w10", app: "AppB", bundle: "com.example.b", title: "Beta", zOrder: 200)
        checkEqual("untimed destinations rank by title, not leftover z-order",
                   ranker.rank([untimedB, untimedA], query: "").map(\.id), ["w9", "w10"])
    }

    // MARK: - Search

    private static func searchTests() {
        print("== search ==")
        let ranker = Ranker()

        let githubTab = tab(id: "t1", title: "Issues · anthropics", domain: "github.com")
        let noise = window(id: "w1", app: "Notes", bundle: "com.apple.Notes", title: "Shopping list")
        checkEqual("a domain match is found when the title does not contain the query",
                   ranker.rank([noise, githubTab], query: "github").map(\.id), ["t1"])

        let vsCode = window(id: "w2", app: "Visual Studio Code",
                            bundle: "com.microsoft.VSCode", title: "main.swift")
        // The noise title contains v, s and c as a subsequence but only two of them fall on
        // word boundaries, so a genuine app-initials match should beat it.
        let incidental = window(id: "w3", app: "Notes", bundle: "com.apple.Notes",
                                title: "Advanced services catalog")
        checkEqual("app initials beat an incidental subsequence in a title",
                   ranker.rank([incidental, vsCode], query: "vsc").first?.id, "w2")

        check("non-matching destinations are excluded",
              ranker.rank([githubTab], query: "zzzzqqq").isEmpty)
    }

    // MARK: - Titles

    private static func titleTests() {
        print("== titles ==")
        checkEqual("untitled windows get a readable label",
                   window(id: "w1", app: "Finder", bundle: "com.apple.finder", title: "").displayTitle,
                   "Finder — Untitled")
    }
}
