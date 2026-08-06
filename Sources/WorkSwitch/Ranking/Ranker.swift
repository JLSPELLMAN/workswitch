import Foundation

/// Milestone 1 ranking: deterministic, in-memory, and easy to explain.
///
/// Persistence (Milestone 3) and behavioral signals — transitions, co-usage, time of day
/// (Milestone 4) — layer on top of this without changing its shape. The spec's requirement
/// that ranking stay understandable and never feel random is why every rule here is a
/// simple ordered comparison rather than a tuned weighted sum.
struct Ranker {

    /// In-session activation history. Milestone 3 moves this into SQLite.
    private var lastActivated: [String: Date] = [:]
    private var visitCounts: [String: Int] = [:]

    /// Takes an id rather than a full `Destination` because the real-time focus-change path
    /// (`OverlayController`'s workspace observer) only ever has an id, a title, and an app
    /// name available — resolving a full enumerated `Destination` for every external app
    /// switch would mean a synchronous AX round-trip on every focus change, for data this
    /// method doesn't use anyway.
    @discardableResult
    mutating func recordActivation(id: String) -> (lastActivatedAt: Date, interactionCount: Int) {
        let now = Date()
        lastActivated[id] = now
        let count = visitCounts[id, default: 0] + 1
        visitCounts[id] = count
        return (now, count)
    }

    /// Drops tracked history for any id no longer present in the live destination set, so a
    /// closed window's old activity can never resurface — e.g. if a different, unrelated
    /// window later happens to reuse a hash-based fallback id.
    mutating func prune(keeping liveIDs: Set<String>) {
        lastActivated = lastActivated.filter { liveIDs.contains($0.key) }
        visitCounts = visitCounts.filter { liveIDs.contains($0.key) }
    }

    func decorate(_ destinations: [Destination]) -> [Destination] {
        destinations.map { destination in
            var copy = destination
            // Chrome supplies its own `lastAccessed` for tabs, so it is only overwritten
            // when this session has a more recent, first-hand activation to report.
            if let sessionActivation = lastActivated[destination.id] {
                copy.lastActivated = max(sessionActivation, destination.lastActivated ?? .distantPast)
            }
            copy.visitCount = visitCounts[destination.id] ?? 0
            return copy
        }
    }

    /// A single comparable "how recently was this used" value across both destination types.
    ///
    /// A destination's on-screen window z-order used to be scaled into a pseudo-timestamp here,
    /// on the theory that a window sitting on screen has probably been used more recently than
    /// one that hasn't. In practice that signal turned out to be unreliable enough to actively
    /// mislead: a window running full-screen sits on its own dedicated macOS Space and is
    /// completely absent from the on-screen window list unless that exact Space is the one
    /// currently displayed — true of any full-screen Chrome window, for instance, regardless of
    /// how recently it was actually used — and Stage Manager collapses every backgrounded app to
    /// a small thumbnail proxy, so which windows happened to resolve a "real" position reflected
    /// Stage Manager's current layout, not genuine recency. Live logs showed the same overlay,
    /// reopened seconds apart with no activation in between, producing two entirely different
    /// orderings as that proxy flickered. Rather than continue patching a heuristic that can't be
    /// made reliable, destinations with no real timestamp all land in the same flat bucket —
    /// less informative, but honest about what's actually known (nothing), and stable regardless
    /// of window-server state. Ties break on `visitCount`, then alphabetically, in
    /// `rankWithoutQuery` below — both deterministic.
    private func effectiveRecency(_ destination: Destination, now: Date) -> Date {
        if let lastActivated = destination.lastActivated {
            return lastActivated
        }
        if destination.isMinimized {
            return now.addingTimeInterval(-86_400)
        }
        return now.addingTimeInterval(-3_600)
    }

    func rank(_ destinations: [Destination], query: String) -> [Destination] {
        let decorated = decorate(destinations)
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        if trimmedQuery.isEmpty {
            return rankWithoutQuery(decorated)
        }
        return rankWithQuery(decorated, query: trimmedQuery)
    }

    // MARK: - No query

    private func rankWithoutQuery(_ destinations: [Destination]) -> [Destination] {
        let now = Date()
        return destinations.sorted { a, b in
            // The destination you are already in goes last. Switching to where you already
            // are is never the intent, and burying it is predictable in a way that a
            // scoring penalty would not be.
            if a.isActive != b.isActive { return !a.isActive }

            // Cold-start order: pinned, then recency, then frequency, then everything else.
            // (Previously pinned sat below recency, on the reasoning that many pinned tabs
            // would swamp recent work — revised per explicit product direction; moot today
            // either way, since nothing currently sets `isPinned`.)
            if a.isPinned != b.isPinned { return a.isPinned }

            let recencyA = effectiveRecency(a, now: now)
            let recencyB = effectiveRecency(b, now: now)
            if recencyA != recencyB { return recencyA > recencyB }

            if a.visitCount != b.visitCount { return a.visitCount > b.visitCount }
            if a.isMinimized != b.isMinimized { return !a.isMinimized }

            return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
        }
    }

    // MARK: - With query

    private func rankWithQuery(_ destinations: [Destination], query: String) -> [Destination] {
        let scored: [(destination: Destination, score: Double)] = destinations.compactMap { destination in
            // Title carries the most signal; an app-name match is worth less so that typing
            // "chrome" does not bury a window actually titled "Chrome DevTools".
            let titleMatch = FuzzyMatcher.match(query: query, candidate: destination.displayTitle)
            let appMatch = FuzzyMatcher.match(query: query, candidate: destination.appName)
            // Typing "github" should find a github.com tab even when its title never says so.
            let domainMatch = destination.domain.flatMap {
                FuzzyMatcher.match(query: query, candidate: $0)
            }

            guard titleMatch != nil || appMatch != nil || domainMatch != nil else { return nil }

            // Title is the strongest signal, but app-name matches are weighted close behind
            // it: typing an app's initials ("vsc", "chr") is one of the most common ways
            // people reach for a window, and a heavy discount there loses to any title that
            // happens to contain the same letters.
            var score = max(
                titleMatch?.score ?? 0,
                max((appMatch?.score ?? 0) * 0.85, (domainMatch?.score ?? 0) * 0.9)
            )

            // Recency and frequency act as tiebreakers, never overriding relevance.
            if let last = destination.lastActivated {
                score += 2.0 / (1.0 + Date().timeIntervalSince(last) / 300.0)
            }
            score += min(Double(destination.visitCount) * 0.15, 1.5)
            if destination.isPinned { score += 5.0 }
            if destination.isActive { score -= 1.0 }

            return (destination, score)
        }

        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                // Text relevance first (above), recency as the tie-break — zOrder only
                // decides ties between two destinations neither of which has ever been
                // activated this session.
                let recencyA = a.destination.lastActivated ?? .distantPast
                let recencyB = b.destination.lastActivated ?? .distantPast
                if recencyA != recencyB { return recencyA > recencyB }
                return a.destination.zOrder < b.destination.zOrder
            }
            .map(\.destination)
    }
}
