import AppKit
import Combine

/// Observable state backing the overlay.
final class SwitcherModel: ObservableObject {

    @Published var query: String = "" {
        didSet { recompute() }
    }
    @Published private(set) var results: [Destination] = []
    @Published var selectedIndex: Int = 0
    @Published var statusMessage: String?
    @Published var isTrusted: Bool = false

    /// Set when the app was trusted previously but is not now, i.e. the signing identity
    /// changed. Drives the troubleshooting message instead of the generic prompt.
    @Published var looksLikeStaleGrant: Bool = false

    /// Exact `tccutil` command for this build's bundle identifier.
    let resetCommand: String = Diagnostics.resetCommand

    private var allDestinations: [Destination] = []
    private var ranker = Ranker()

    /// The last id recorded through `recordActivation`, purely for the previous→new pair in
    /// the debug log — not read anywhere ranking-relevant.
    private var lastRecordedID: String?

    var selectedDestination: Destination? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    func update(destinations: [Destination]) {
        allDestinations = destinations
        // Without this, a closed window's recency/frequency would sit orphaned in the ranker
        // forever — harmless to ranking today (dead ids can't appear in `results` since they
        // aren't in `allDestinations`), but exactly the kind of stale state that becomes a
        // real bug the moment an id gets reused (e.g. a title-hash fallback id colliding with
        // a new, unrelated window).
        ranker.prune(keeping: Set(destinations.map(\.id)))
        recompute()
    }

    func resetQuery() {
        // Assigning through the published property would trigger recompute twice.
        query = ""
        selectedIndex = 0
    }

    private func recompute() {
        let previousSelectionID = results.indices.contains(selectedIndex)
            ? results[selectedIndex].id
            : nil

        results = ranker.rank(allDestinations, query: query)

        // Keep the highlight on the same destination across background refreshes, so the
        // list does not shift under the user's fingers mid-keystroke.
        if let previousSelectionID,
           let index = results.firstIndex(where: { $0.id == previousSelectionID }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    // MARK: - Keyboard navigation

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + offset
        selectedIndex = min(max(next, 0), results.count - 1)
    }

    func moveToFirst() { selectedIndex = 0 }

    func moveToLast() {
        guard !results.isEmpty else { return }
        selectedIndex = results.count - 1
    }

    /// `source` is purely descriptive, for the debug log (e.g. "WorkSwitch selection" vs.
    /// "external focus change") — it plays no role in ranking.
    func recordActivation(id: String, title: String, appName: String, source: String) {
        let previous = lastRecordedID
        let (lastActivatedAt, interactionCount) = ranker.recordActivation(id: id)
        lastRecordedID = id

        // Re-rank immediately: if the overlay happens to be open when an external switch is
        // observed, the list must reflect it without waiting for the next full refresh.
        recompute()

        let top5Display = results.prefix(5).enumerated()
            .map { "\($0.offset + 1). \($0.element.appName): \($0.element.displayTitle)" }
        NSLog("""
        [WorkSwitch] Activity (\(source)): previous=\(previous ?? "nil") \
        new=\(id) (\(appName): \(title)) lastActivatedAt=\(lastActivatedAt) \
        interactionCount=\(interactionCount) top5=[\(top5Display.joined(separator: " | "))]
        """)
        // NSLog above doesn't reliably surface in the unified log for a self-signed build —
        // this file is the one that's actually inspectable.
        Diagnostics.logActivity(
            source: source, previous: previous, new: id, title: title, appName: appName,
            lastActivatedAt: lastActivatedAt, interactionCount: interactionCount, top5: top5Display
        )
    }
}
