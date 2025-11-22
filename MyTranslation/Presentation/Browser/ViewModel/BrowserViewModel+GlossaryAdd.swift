import Foundation

@MainActor
extension BrowserViewModel {
    func onGlossaryAddRequested(
        selectedText: String,
        selectedRange: NSRange,
        section: OverlayTextSection
    ) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        let kind: GlossaryAddSheetState.SelectionKind = {
            switch section {
            case .original:
                return .original
            case .improved, .primaryFinal, .primaryPreNormalized, .alternative:
                return .translated
            }
        }()

        let matched = matchedTerm(for: kind, selectedRange: selectedRange)
        let candidates = extractUnmatchedCandidates(
            selectedText: trimmed,
            kind: kind
        )

        glossaryAddSheet = GlossaryAddSheetState(
            selectedText: trimmed,
            originalText: overlayState?.selectedText ?? "",
            selectedRange: selectedRange,
            section: section,
            selectionKind: kind,
            matchedTerm: matched,
            unmatchedCandidates: candidates
        )
    }

    private func matchedTerm(
        for kind: GlossaryAddSheetState.SelectionKind,
        selectedRange: NSRange
    ) -> GlossaryAddSheetState.MatchedTerm? {
        guard kind == .original,
              let overlay = overlayState,
              let metadata = overlay.primaryHighlightMetadata,
              let entry = metadata.matchedEntryForOriginal(nsRange: selectedRange, in: overlay.selectedText)
        else { return nil }
        guard case let .termStandalone(termKey) = entry.origin else { return nil }
        return .init(key: termKey, entry: entry)
    }

    private func extractUnmatchedCandidates(
        selectedText: String,
        kind: GlossaryAddSheetState.SelectionKind
    ) -> [GlossaryAddSheetState.UnmatchedTermCandidate] {
        Log.info("")
        guard kind == .translated,
              let metadata = overlayState?.primaryHighlightMetadata else {
            Log.info("no metadata")
            return [] }

        let matchedSources = Set(
            metadata.finalTermRanges.map { $0.entry.source } +
            (metadata.preNormalizedTermRanges ?? []).map { $0.entry.source }
        )
        Log.info("matchedSources = \(matchedSources)")

        let loweredSelection = selectedText.lowercased()
        let candidates: [GlossaryAddSheetState.UnmatchedTermCandidate] = metadata.originalTermRanges.enumerated().compactMap { index, termRange in
            if matchedSources.contains(termRange.entry.source) { return nil }
            let entry = termRange.entry
            let score = bestSimilarityScore(for: entry, against: loweredSelection)
            let termKey: String?
            switch entry.origin {
            case let .termStandalone(key):
                termKey = key
            case let .composer(composerId, _, _, _):
                termKey = composerId
            }
            return .init(
                termKey: termKey,
                entry: entry,
                appearanceOrder: index,
                similarity: score
            )
        }
        Log.info("candidates: \(candidates)")

        return candidates.sorted { lhs, rhs in
            if abs(lhs.similarity - rhs.similarity) > 0.001 {
                return lhs.similarity > rhs.similarity
            }
            return lhs.appearanceOrder < rhs.appearanceOrder
        }
    }

    private func bestSimilarityScore(for entry: GlossaryEntry, against text: String) -> Double {
        let candidates = [entry.target] + Array(entry.variants)
        return candidates.map { similarityScore($0.lowercased(), text) }.max() ?? 0
    }

    private func similarityScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let dist = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 0 : 1 - (Double(dist) / Double(maxLen))
    }

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let aCount = aChars.count
        let bCount = bChars.count
        var dp = Array(repeating: Array(repeating: 0, count: bCount + 1), count: aCount + 1)

        for i in 0...aCount { dp[i][0] = i }
        for j in 0...bCount { dp[0][j] = j }

        for i in 1...aCount {
            for j in 1...bCount {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1,
                    dp[i - 1][j - 1] + cost
                )
            }
        }
        return dp[aCount][bCount]
    }
}
