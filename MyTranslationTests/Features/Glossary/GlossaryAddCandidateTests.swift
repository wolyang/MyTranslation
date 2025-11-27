import Foundation
import Testing
@testable import MyTranslation

struct GlossaryAddCandidateTests {
    @Test
    func unmatchedCandidatesRespectAnchorOrderingFromMetadata() {
        let entryA = GlossaryEntry(
            source: "凯",
            target: "가이",
            variants: ["카이", "케이"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "termperson_6b5084f18cbb")
        )
        let entryB = GlossaryEntry(
            source: "伽古拉",
            target: "쟈그라",
            variants: ["가고라", "가구라"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "termperson_5dd6e5c5e67f")
        )

        let originalText = "当凯问伽古拉是否喜欢凯时，伽古拉笑了."
        let originalRanges: [TermRange] = [
            TermRange(entry: entryA, range: find("凯", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryB, range: find("伽古拉", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("凯", in: originalText, occurrence: 1), type: .normalized),
            TermRange(entry: entryB, range: find("伽古拉", in: originalText, occurrence: 1), type: .normalized)
        ]

        let finalText = "Guy가 쟈그라에게 가이를 좋아하냐고 물었을 때, Juggler는 미소를 지었다."
        let finalRanges: [TermRange] = [
            TermRange(entry: entryB, range: find("쟈그라", in: finalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("가이", in: finalText, occurrence: 0), type: .normalized)
        ]

        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: finalRanges,
            preNormalizedTermRanges: nil
        )

        let front = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "Guy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: 0
        )
        #expect(front.candidates.first?.entry.source == "凯")

        let back = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "Juggler",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: finalText.count
        )
        #expect(back.candidates.first?.entry.source == "伽古拉")
    }

    @Test
    func unmatchedCandidatesRespectAnchorOrdering() {
        let entryA = GlossaryEntry(
            source: "A",
            target: "A-tgt",
            variants: ["A-alt"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "A")
        )
        let entryB = GlossaryEntry(
            source: "B",
            target: "B-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "B")
        )

        let originalText = "A B A B"
        let originalRanges: [TermRange] = [
            TermRange(entry: entryA, range: find("A", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryB, range: find("B", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("A", in: originalText, occurrence: 1), type: .normalized),
            TermRange(entry: entryB, range: find("B", in: originalText, occurrence: 1), type: .normalized)
        ]

        let finalText = "B-tgt ... A-tgt"
        let finalRanges: [TermRange] = [
            TermRange(entry: entryB, range: find("B-tgt", in: finalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("A-tgt", in: finalText, occurrence: 0), type: .normalized)
        ]

        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: finalRanges,
            preNormalizedTermRanges: nil
        )

        let front = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 5
        )
        #expect(front.candidates.first?.entry.source == "A")

        let back = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: finalText.count,
            maxCount: 5
        )
        #expect(back.candidates.first?.entry.source == "B")
    }

    @Test
    func unmatchedCandidatesTruncateWhenTooMany() {
        let base = GlossaryEntry(
            source: "X",
            target: "X-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "X")
        )
        let originalText = (0..<20).map { _ in "X" }.joined(separator: " ")
        let originalRanges: [TermRange] = (0..<20).map { idx in
            TermRange(entry: base, range: find("X", in: originalText, occurrence: idx), type: .normalized)
        }
        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )

        let result = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: nil,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 5
        )
        #expect(result.candidates.count == 5)
        #expect(result.truncated == true)
    }

    @Test
    func matchedEntryForOriginalFindsExactRange() {
        let text = "Hello A and B"
        let entryA = GlossaryEntry(
            source: "A",
            target: "A-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "A")
        )
        let entryB = GlossaryEntry(
            source: "B",
            target: "B-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "B")
        )

        let rA = find("A", in: text, occurrence: 0)
        let rB = find("B", in: text, occurrence: 0)
        let meta = TermHighlightMetadata(
            originalTermRanges: [
                TermRange(entry: entryA, range: rA, type: .normalized),
                TermRange(entry: entryB, range: rB, type: .normalized)
            ],
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )

        let nsA = NSRange(rA, in: text)
        let nsB = NSRange(rB, in: text)
        #expect(meta.matchedEntryForOriginal(nsRange: nsA, in: text)?.source == "A")
        #expect(meta.matchedEntryForOriginal(nsRange: nsB, in: text)?.source == "B")
        let miss = NSRange(location: 0, length: 3)
        #expect(meta.matchedEntryForOriginal(nsRange: miss, in: text) == nil)
    }

    @Test
    func composerCandidateProducesMultipleKeys() {
        let componentTerms: [GlossaryEntry.ComponentTerm] = [
            .init(key: "L", target: "L-tgt", variants: [], source: "A"),
            .init(key: "R", target: "R-tgt", variants: [], source: "B")
        ]
        let entry = GlossaryEntry(
            source: "AB",
            target: "AB-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .composer(composerId: "comp", leftKey: "L", rightKey: "R", needPairCheck: false),
            componentTerms: componentTerms
        )
        let originalText = "AB"
        let range = find("AB", in: originalText, occurrence: 0)
        let meta = TermHighlightMetadata(
            originalTermRanges: [TermRange(entry: entry, range: range, type: .normalized)],
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )
        let result = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: meta,
            selectedText: "dummy",
            finalText: nil,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 10
        )
        let keys = result.candidates.compactMap { $0.termKey }
        #expect(keys.contains("L"))
        #expect(keys.contains("R"))
        #expect(keys.count == 2)
    }
}

private func find(_ needle: String, in haystack: String, occurrence: Int) -> Range<String.Index> {
    var start = haystack.startIndex
    var count = 0
    while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
        if count == occurrence {
            return range
        }
        count += 1
        start = range.upperBound
    }
    return haystack.startIndex..<haystack.startIndex
}
