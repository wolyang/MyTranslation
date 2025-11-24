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
        let candidateResult = extractUnmatchedCandidates(
            selectedText: trimmed,
            kind: kind,
            selectionAnchor: selectedRange.location
        )
        let recommendationMessage: String? = {
            guard kind == .translated else { return nil }
            if overlayState?.primaryHighlightMetadata == nil {
                return "하이라이트 정보가 없어 추천을 계산할 수 없습니다."
            }
            if candidateResult.candidates.isEmpty {
                return "추천할 용어가 없습니다. 새 용어 추가나 직접 선택을 진행해 주세요."
            }
            if candidateResult.truncated {
                return "추천이 많아 상위 \(candidateResult.maxCount)개만 표시합니다."
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
            unmatchedCandidates: candidateResult.candidates,
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
    ) -> (candidates: [GlossaryAddSheetState.UnmatchedTermCandidate], truncated: Bool, maxCount: Int) {
        guard kind == .translated,
              let metadata = overlayState?.primaryHighlightMetadata else {
            return ([], false, 0) }

        let maxCount = 8
        let result = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: selectedText,
            finalText: overlayState?.primaryFinalText,
            preNormalizedText: overlayState?.primaryPreNormalizedText,
            selectionAnchor: selectionAnchor,
            maxCount: maxCount
        )
        return (result.candidates, result.truncated, maxCount)
    }
}

// MARK: - Candidate computation (shared for testing)

// 하이라이트 메타데이터를 이용해 용어집 추가 후보를 계산하는 유틸.
enum GlossaryAddCandidateUtil {
    /// 하이라이트/선택 정보를 기반으로 아직 등록되지 않은 용어 후보를 우선순위로 반환한다.
    /// - Parameters:
    ///   - metadata: 하이라이트된 GlossaryEntry 정보.
    ///   - selectedText: 사용자가 선택한 텍스트.
    ///   - finalText: 정규화·언마스킹 이후 텍스트(있으면 finalTermRanges 사용).
    ///   - preNormalizedText: 정규화 이전 텍스트(없으면 빈 문자열).
    ///   - selectionAnchor: 선택 시작 위치(UTF-16 오프셋).
    ///   - maxCount: 반환할 최대 후보 개수.
    ///   - maxScanCount: 원문 하이라이트 스캔 상한(성능 보호).
    /// - Returns: 후보 목록과 상한 초과로 절단되었는지 여부.
    static func computeUnmatchedCandidates(
        metadata: TermHighlightMetadata,
        selectedText: String,
        finalText: String?,
        preNormalizedText: String?,
        selectionAnchor: Int,
        maxCount: Int = 8,
        maxScanCount: Int = 300
    ) -> (candidates: [GlossaryAddSheetState.UnmatchedTermCandidate], truncated: Bool) {
        let rangesForAnchor: [TermRange] = {
            if finalText != nil {
                return metadata.finalTermRanges
            }
            return metadata.preNormalizedTermRanges ?? []
        }()

        var remainingMatchedCount: [String: Int] = [:]
        var remainingMatchedBeforeAnchor: [String: Int] = [:]
        let anchorText = finalText ?? preNormalizedText ?? ""
        let matchedOffsets = rangesForAnchor
            .map { $0.range.lowerBound.utf16Offset(in: anchorText) }
            .sorted()
        let firstMatchedStart = matchedOffsets.first
        let lastMatchedStart = matchedOffsets.last

        for range in rangesForAnchor.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            remainingMatchedCount[range.entry.source, default: 0] += 1
            let start = range.range.lowerBound.utf16Offset(in: anchorText)
            if start < selectionAnchor {
                remainingMatchedBeforeAnchor[range.entry.source, default: 0] += 1
            }
        }

        let loweredSelection = selectedText.lowercased()

        var candidates: [GlossaryAddSheetState.UnmatchedTermCandidate] = []

        let scanList = metadata.originalTermRanges.prefix(maxScanCount)

        for (index, termRange) in scanList.enumerated() {
            let source = termRange.entry.source
            if let before = remainingMatchedBeforeAnchor[source], before > 0 {
                remainingMatchedBeforeAnchor[source] = before - 1
                remainingMatchedCount[source] = max((remainingMatchedCount[source] ?? 0) - 1, 0)
                continue
            }
            if let count = remainingMatchedCount[source], count > 0 {
                remainingMatchedCount[source] = count - 1
                continue
            }

            let entry = termRange.entry
            let score = bestSimilarityScore(for: entry, against: loweredSelection)
            switch entry.origin {
            case let .termStandalone(key):
                candidates.append(GlossaryAddSheetState.UnmatchedTermCandidate(
                    termKey: key,
                    entry: entry,
                    appearanceOrder: index,
                    similarity: score
                ))
            case let .composer(_, leftKey, rightKey, _):
                let keys = [leftKey, rightKey].compactMap { $0 }
                guard keys.isEmpty == false else { continue }
                for key in keys {
                    guard
                        let term = entry.componentTerms.first(where: { $0.key == key }),
                        let termEntry = makeCandidateEntry(from: term, selection: loweredSelection)
                    else { continue }

                    candidates.append(
                        GlossaryAddSheetState.UnmatchedTermCandidate(
                            termKey: key,
                            entry: termEntry,
                            appearanceOrder: index,
                            similarity: bestSimilarityScore(for: termEntry, against: loweredSelection)
                        )
                    )
                }
            }
        }

        let sorted: [GlossaryAddSheetState.UnmatchedTermCandidate] = {
            if let last = lastMatchedStart, selectionAnchor > last {
                // 선택 위치가 마지막 매칭 뒤라면 뒤쪽(등장 순서가 큰) 후보 우선
                return candidates.sorted { lhs, rhs in
                    if abs(lhs.similarity - rhs.similarity) > 0.001 {
                        return lhs.similarity > rhs.similarity
                    }
                    return lhs.appearanceOrder > rhs.appearanceOrder
                }
            } else if let first = firstMatchedStart, selectionAnchor < first {
                // 선택 위치가 첫 매칭 앞이라면 앞쪽 후보 우선
                return candidates.sorted { lhs, rhs in
                    if abs(lhs.similarity - rhs.similarity) > 0.001 {
                        return lhs.similarity > rhs.similarity
                    }
                    return lhs.appearanceOrder < rhs.appearanceOrder
                }
            } else {
                // 중간이면 기존 정렬(등장 순서 오름차순)
                return candidates.sorted { lhs, rhs in
                    if abs(lhs.similarity - rhs.similarity) > 0.001 {
                        return lhs.similarity > rhs.similarity
                    }
                    return lhs.appearanceOrder < rhs.appearanceOrder
                }
            }
        }()

        let limited = maxCount > 0 ? Array(sorted.prefix(maxCount)) : sorted
        let truncated = sorted.count > limited.count || metadata.originalTermRanges.count > scanList.count
        return (limited, truncated)
    }

    /// ComponentTerm 정보에서 GlossaryEntry를 생성해 후보로 사용한다.
    private static func makeCandidateEntry(
        from term: GlossaryEntry.ComponentTerm,
        selection: String
    ) -> GlossaryEntry? {
        guard let source = bestSource(for: term, selection: selection) else { return nil }
        let prohibit = term.sources.first(where: { $0.text == source })?.prohibitStandalone ?? false
        return GlossaryEntry(
            source: source,
            target: term.target,
            variants: term.variants,
            preMask: term.preMask,
            isAppellation: term.isAppellation,
            prohibitStandalone: prohibit,
            origin: .termStandalone(termKey: term.key),
            componentTerms: [term],
            activatorKeys: term.activatorKeys,
            activatesKeys: term.activatesKeys
        )
    }

    /// 매칭된 소스가 있으면 우선 사용하고, 없으면 등록된 소스 중 최적 유사도 소스를 반환한다.
    private static func bestSource(
        for term: GlossaryEntry.ComponentTerm,
        selection: String
    ) -> String? {
        let candidates = prioritizedSources(for: term)
        guard candidates.isEmpty == false else { return nil }
        guard selection.isEmpty == false else { return candidates.first }

        return candidates.max { lhs, rhs in
            similarityScore(lhs.lowercased(), selection) < similarityScore(rhs.lowercased(), selection)
        }
    }

    /// matchedSources를 우선 반환하고, 없으면 모든 등록 소스를 반환한다.
    private static func prioritizedSources(for term: GlossaryEntry.ComponentTerm) -> [String] {
        let matched = term.sources.filter { term.matchedSources.contains($0.text) }.map { $0.text }
        if matched.isEmpty == false { return matched }
        return term.sources.map { $0.text }
    }

    /// 타겟/variants 중 선택 텍스트와 가장 유사한 점수를 계산한다.
    private static func bestSimilarityScore(for entry: GlossaryEntry, against text: String) -> Double {
        let candidates = [entry.target] + Array(entry.variants)
        return candidates.map { similarityScore($0.lowercased(), text) }.max() ?? 0
    }

    /// Levenshtein 거리 기반 유사도(1 - dist/maxLen).
    private static func similarityScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        let dist = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 0 : 1 - (Double(dist) / Double(maxLen))
    }

    /// 표준 Levenshtein 거리 구현.
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
