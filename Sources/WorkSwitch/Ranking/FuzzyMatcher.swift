import Foundation

/// Subsequence matcher with contiguity and word-boundary bonuses.
///
/// Bonuses are what make "vsc" rank "VS Code" above an incidental match elsewhere, and
/// what make an acronym-style query behave the way people expect from Spotlight.
enum FuzzyMatcher {

    struct Match {
        let score: Double
        let matchedIndices: [Int]
    }

    /// Returns nil when the query is not a subsequence of the candidate.
    static func match(query: String, candidate: String) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, matchedIndices: []) }

        let queryChars = Array(query.lowercased())
        let candidateChars = Array(candidate)
        let loweredCandidate = Array(candidate.lowercased())
        guard !candidateChars.isEmpty else { return nil }

        var score = 0.0
        var matched: [Int] = []
        var queryIndex = 0
        var previousMatchIndex = -1

        for (index, character) in loweredCandidate.enumerated() {
            guard queryIndex < queryChars.count, character == queryChars[queryIndex] else { continue }

            var characterScore = 1.0

            // Contiguous run: strongly preferred, so a literal substring wins.
            if previousMatchIndex == index - 1 {
                characterScore += 3.0
            }

            // Word boundary: start of string, after a separator, or a camel-case hump.
            if isWordBoundary(at: index, in: candidateChars) {
                characterScore += 2.5
            }

            // Prefix matches lead.
            if index == 0 {
                characterScore += 2.0
            }

            score += characterScore
            matched.append(index)
            previousMatchIndex = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }

        // Normalize lightly against candidate length so short titles are not swamped by
        // long ones that happen to contain the same characters.
        let lengthPenalty = Double(candidateChars.count) / 100.0
        return Match(score: score - lengthPenalty, matchedIndices: matched)
    }

    private static func isWordBoundary(at index: Int, in characters: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "/"
            || previous == "." || previous == ":" || previous == "—" {
            return true
        }
        // camelCase hump
        let current = characters[index]
        return previous.isLowercase && current.isUppercase
    }
}
