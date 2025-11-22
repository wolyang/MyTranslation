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
            kind: kind,
            selectionAnchor: selectedRange.location
        )
        let recommendationMessage: String? = {
            guard kind == .translated else { return nil }
            if overlayState?.primaryHighlightMetadata == nil {
                return "하이라이트 정보가 없어 추천을 계산할 수 없습니다."
            }
            if candidates.isEmpty {
                return "추천할 용어가 없습니다. 새 용어 추가나 직접 선택을 진행해 주세요."
            }
            return nil
        }()

        glossaryAddSheet = GlossaryAddSheetState(
            selectedText: trimmed,
            originalText: overlayState?.selectedText ?? "",
            selectedRange: selectedRange,
            section: section,
            selectionKind: kind,
            matchedTerm: matched,
            unmatchedCandidates: candidates,
            recommendationMessage: recommendationMessage
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
        kind: GlossaryAddSheetState.SelectionKind,
        selectionAnchor: Int
    ) -> [GlossaryAddSheetState.UnmatchedTermCandidate] {
        guard kind == .translated,
              let metadata = overlayState?.primaryHighlightMetadata else {
            return [] }

        return GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: selectedText,
            finalText: overlayState?.primaryFinalText,
            preNormalizedText: overlayState?.primaryPreNormalizedText,
            selectionAnchor: selectionAnchor
        )
    }
}

// MARK: - Candidate computation (shared for testing)

enum GlossaryAddCandidateUtil {
    static func computeUnmatchedCandidates(
        metadata: TermHighlightMetadata,
        selectedText: String,
        finalText: String?,
        preNormalizedText: String?,
        selectionAnchor: Int
    ) -> [GlossaryAddSheetState.UnmatchedTermCandidate] {
        let rangesForAnchor: [TermRange] = {
            if finalText != nil {
                return metadata.finalTermRanges
            }
            return metadata.preNormalizedTermRanges ?? []
        }()

        var remainingMatchedCount: [String: Int] = [:]
        var remainingMatchedBeforeAnchor: [String: Int] = [:]
        let anchorText = finalText ?? preNormalizedText ?? ""

        for range in rangesForAnchor.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            remainingMatchedCount[range.entry.source, default: 0] += 1
            let start = range.range.lowerBound.utf16Offset(in: anchorText)
            if start < selectionAnchor {
                remainingMatchedBeforeAnchor[range.entry.source, default: 0] += 1
            }
        }

        let loweredSelection = selectedText.lowercased()

        let candidates: [GlossaryAddSheetState.UnmatchedTermCandidate] = metadata.originalTermRanges.enumerated().flatMap { index, termRange in
            let source = termRange.entry.source
            if let before = remainingMatchedBeforeAnchor[source], before > 0 {
                remainingMatchedBeforeAnchor[source] = before - 1
                remainingMatchedCount[source] = max((remainingMatchedCount[source] ?? 0) - 1, 0)
                return []
            }
            if let count = remainingMatchedCount[source], count > 0 {
                remainingMatchedCount[source] = count - 1
                return []
            }

            let entry = termRange.entry
            let score = bestSimilarityScore(for: entry, against: loweredSelection)
            switch entry.origin {
            case let .termStandalone(key):
                return [GlossaryAddSheetState.UnmatchedTermCandidate(
                    termKey: key,
                    entry: entry,
                    appearanceOrder: index,
                    similarity: score
                )]
            case let .composer(_, leftKey, rightKey, _):
                let keys = [leftKey, rightKey].compactMap { $0 }
                if keys.isEmpty {
                    return [GlossaryAddSheetState.UnmatchedTermCandidate(
                        termKey: nil,
                        entry: entry,
                        appearanceOrder: index,
                        similarity: score
                    )]
                }
                return keys.map { key in
                    GlossaryAddSheetState.UnmatchedTermCandidate(
                        termKey: key,
                        entry: entry,
                        appearanceOrder: index,
                        similarity: score
                    )
                }
            }
        }

        return candidates.sorted { lhs, rhs in
            if abs(lhs.similarity - rhs.similarity) > 0.001 {
                return lhs.similarity > rhs.similarity
            }
            return lhs.appearanceOrder < rhs.appearanceOrder
        }
    }

    private static func bestSimilarityScore(for entry: GlossaryEntry, against text: String) -> Double {
        let candidates = [entry.target] + Array(entry.variants)
        return candidates.map { similarityScore($0.lowercased(), text) }.max() ?? 0
    }

    private static func similarityScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let dist = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 0 : 1 - (Double(dist) / Double(maxLen))
    }

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
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
