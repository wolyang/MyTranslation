import Foundation
import Testing
@testable import MyTranslation

struct SegmentPiecesBuilderTests {

    @Test
    func segmentPiecesTracksRanges() {
        let text = "Hello 최강자님, welcome!"
        let segmentID = "seg1"
        let segment = Segment(
            id: segmentID,
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )

        let term = Glossary.SDModel.SDTerm(
            key: "t1",
            target: "Choigangja",
            variants: [],
            isAppellation: false,
            preMask: true
        )
        let source = Glossary.SDModel.SDSource(text: "최강자", prohibitStandalone: false, term: term)
        term.sources.append(source)

        let entry = GlossaryEntry(
            source: source.text,
            target: term.target,
            variants: term.variants,
            preMask: term.preMask,
            isAppellation: term.isAppellation,
            origin: .termStandalone(termKey: term.key),
            componentTerms: [
                .init(
                    key: term.key,
                    target: term.target,
                    variants: term.variants,
                    source: source.text
                )
            ]
        )

        let builder = SegmentPiecesBuilder()
        let pieces = builder.buildSegmentPieces(
            segmentText: segment.originalText,
            segmentID: segment.id,
            sourceToEntry: [source.text: entry]
        )

        #expect(pieces.originalText == text)
        #expect(pieces.pieces.count == 3)

        if case let .text(prefix, range1) = pieces.pieces[0] {
            #expect(prefix == "Hello ")
            #expect(String(text[range1]) == "Hello ")
        } else {
            #expect(false, "첫 번째 조각이 text 이어야 합니다.")
        }

        if case let .term(termEntry, range2) = pieces.pieces[1] {
            #expect(termEntry.source == "최강자")
            #expect(String(text[range2]) == "최강자")
        } else {
            #expect(false, "두 번째 조각이 term 이어야 합니다.")
        }

        if case let .text(suffix, range3) = pieces.pieces[2] {
            #expect(suffix == "님, welcome!")
            #expect(String(text[range3]) == "님, welcome!")
        } else {
            #expect(false, "세 번째 조각이 text 이어야 합니다.")
        }
    }
}
