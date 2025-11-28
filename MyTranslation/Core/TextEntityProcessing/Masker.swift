//
//  TermMasker.swift
//  MyTranslation
//

import Foundation

// MARK: - Term-only Masker

public final class TermMasker {
    private let termMatcher = SegmentTermMatcher()
    private let entriesBuilder = SegmentEntriesBuilder()
    private let piecesBuilder = SegmentPiecesBuilder()
    

    public init() { }

    private func makeComponentTerm(
        from appearedTerm: AppearedTerm,
        source: String
    ) -> GlossaryEntry.ComponentTerm {
        GlossaryEntry.ComponentTerm(
            key: appearedTerm.key,
            target: appearedTerm.target,
            variants: appearedTerm.variants,
            source: source
        )
    }
    
    // ---- 유틸
    func allOccurrences(of needle: String, in hay: String) -> [Int] {
        guard !needle.isEmpty, !hay.isEmpty else { return [] }
        var out: [Int] = []; var from = hay.startIndex
        while from < hay.endIndex, let r = hay.range(of: needle, range: from..<hay.endIndex) {
            out.append(hay.distance(from: hay.startIndex, to: r.lowerBound))
            from = hay.index(after: r.lowerBound) // 겹치기 허용
        }
        return out
    }
    
    /// 주어진 entries에서 사용된 모든 Term 키를 수집한다.
    /// - Parameter entries: GlossaryEntry 배열
    /// - Returns: Entry에 포함된 모든 Term 키의 집합
    func buildSegmentPieces(
        segment: Segment,
        matchedTerms: [Glossary.SDModel.SDTerm],
        patterns: [Glossary.SDModel.SDPattern],
        matchedSources: [String: Set<String>]
    ) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry]) {
        let text = segment.originalText

        guard text.isEmpty == false, matchedTerms.isEmpty == false else {
            return (
                pieces: SegmentPieces(
                    segmentID: segment.id,
                    originalText: text,
                    pieces: [.text(text, range: text.startIndex..<text.endIndex)]
                ),
                glossaryEntries: []
            )
        }

        var usedTermKeys: Set<String> = []
        var sourceToEntry: [String: GlossaryEntry] = [:]

        // Phase 0: 등장 + 비활성화 필터링
        let appearedTerms: [AppearedTerm] = termMatcher.findAppearedTerms(
            segmentText: text,
            matchedTerms: matchedTerms,
            matchedSources: matchedSources
        )

        // Phase 1: Standalone Activation
        for appearedTerm in appearedTerms {
            let matchedSet = matchedSources[appearedTerm.key] ?? []
            for source in appearedTerm.appearedSources where source.prohibitStandalone == false {
                sourceToEntry[source.text] = GlossaryEntry(
                    source: source.text,
                    target: appearedTerm.target,
                    variants: appearedTerm.variants,
                    preMask: appearedTerm.preMask,
                    isAppellation: appearedTerm.isAppellation,
                    origin: .termStandalone(termKey: appearedTerm.key),
                    componentTerms: [
                        makeComponentTerm(
                            from: appearedTerm,
                            source: source.text
                        )
                    ]
                )
                usedTermKeys.insert(appearedTerm.key)
            }
        }

        // Phase 2: Term-to-Term Activation
        for appearedTerm in appearedTerms where !usedTermKeys.contains(appearedTerm.key) {
            let activatorKeys = Set(appearedTerm.activators.map { $0.key })
            guard !activatorKeys.isEmpty && !activatorKeys.isDisjoint(with: usedTermKeys) else {
                continue
            }
            
            for source in appearedTerm.appearedSources where source.prohibitStandalone {
                sourceToEntry[source.text] = GlossaryEntry(
                    source: source.text,
                    target: appearedTerm.target,
                    variants: appearedTerm.variants,
                    preMask: appearedTerm.preMask,
                    isAppellation: appearedTerm.isAppellation,
                    origin: .termStandalone(termKey: appearedTerm.key),
                    componentTerms: [
                        makeComponentTerm(
                            from: appearedTerm,
                            source: source.text
                        )
                    ]
                )
            }

            usedTermKeys.insert(appearedTerm.key)
        }

        // Phase 3: Composer Entries
        let composerEntries = entriesBuilder.buildComposerEntries(
            patterns: patterns,
            appearedTerms: appearedTerms,
            segmentText: text
        )
        for entry in composerEntries where sourceToEntry[entry.source] == nil {
            sourceToEntry[entry.source] = entry
        }

        // Phase 4: Longest-first Segmentation
        let segmentPieces = piecesBuilder.buildSegmentPieces(
            segmentText: text,
            segmentID: segment.id,
            sourceToEntry: sourceToEntry
        )

        return (pieces: segmentPieces, glossaryEntries: Array(sourceToEntry.values))
    }
}
