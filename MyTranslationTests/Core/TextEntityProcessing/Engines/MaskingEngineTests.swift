import Foundation
import Testing
@testable import MyTranslation

struct MaskingEngineTests {

    @Test
    func normalizeDamagedETokensRestoresCorruptedPlaceholders() {
        let engine = MaskingEngine()
        let locks: [String: LockInfo] = [
            "__E#31__": .init(placeholder: "__E#31__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "텍스트 E#３１__ 와 __ E #31 __ 그리고 #31__ 을 포함"
        let restored = engine.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored.contains("__E#31__"))
        #expect(restored.components(separatedBy: "__E#31__").count == 4)
    }

    @Test
    func normalizeDamagedETokensIgnoresUnknownIds() {
        let engine = MaskingEngine()
        let locks: [String: LockInfo] = [
            "__E#7__": .init(placeholder: "__E#7__", target: "Seven", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "E#99__ 는 모르는 토큰이다."
        let restored = engine.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored == corrupted)
    }

    @Test
    func surroundTokenWithNBSPAddsSpacingAroundLatin() {
        let engine = MaskingEngine()
        let token = "__E#1__"
        let text = "Hello__E#1__World"

        let spaced = engine.surroundTokenWithNBSP(text, token: token)

        #expect(spaced.contains("Hello\u{00A0}\(token)\u{00A0}World"))
    }

    @Test
    func insertSpacesAroundTokensOnlyForPunctOnlyParagraphs() {
        let engine = MaskingEngine()
        engine.tokenSpacingBehavior = .isolatedSegments

        let text = "__E#1__,__E#2__!"
        let spaced = engine.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ , __E#2__ !"))
    }

    @Test
    func insertSpacesAroundTokensKeepsNormalParagraphsUntouched() {
        let engine = MaskingEngine()
        engine.tokenSpacingBehavior = .isolatedSegments

        let text = "본문과__E#1__이 섞여 있다."
        let spaced = engine.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced == text)
    }

    @Test
    func normalizeTokensAndParticlesReplacesMultipleTokens() {
        let engine = MaskingEngine()
        let locks: [String: LockInfo] = [
            "__E#1__": .init(placeholder: "__E#1__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false),
            "__E#2__": .init(placeholder: "__E#2__", target: "Beta", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let text = "__E#1____E#2__를 본다"
        let normalized = engine.normalizeTokensAndParticles(in: text, locksByToken: locks)

        #expect(normalized.contains("AlphaBeta"))
        #expect(normalized.hasSuffix("본다"))
    }

    @Test
    func insertSpacesAroundTokensAddsSpaceNearPunctuation() {
        let engine = MaskingEngine()
        engine.tokenSpacingBehavior = .isolatedSegments
        let text = "__E#1__!__E#2__?"

        let spaced = engine.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ ! __E#2__ ?"))
    }

    @Test
    func maskFromPiecesTracksRanges() {
        let text = "Hello 최강자님"
        let segment = Segment(
            id: "seg2",
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )
        let term = Glossary.SDModel.SDTerm(
            key: "t2",
            target: "Choigangja",
            variants: [],
            isAppellation: true,
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

        let engine = MaskingEngine()
        let pieces = SegmentPieces(
            segmentID: segment.id,
            originalText: text,
            pieces: [.text("Hello ", range: text.startIndex..<text.index(text.startIndex, offsetBy: 6)),
                     .term(entry, range: text.index(text.startIndex, offsetBy: 6)..<text.index(text.startIndex, offsetBy: 9)),
                     .text("님", range: text.index(text.startIndex, offsetBy: 9)..<text.endIndex)]
        )
        let pack = engine.maskFromPieces(pieces: pieces, segment: segment)

        #expect(pack.tokenEntries.count == 1)
        #expect(pack.maskedRanges.count == 1)
        if let token = pack.tokenEntries.keys.first,
           let range = pack.maskedRanges.first(where: { $0.type == .masked })?.range {
            #expect(String(pack.masked[range]) == token)
        } else {
            #expect(false, "마스킹된 토큰과 range를 찾지 못했습니다.")
        }
    }

    @Test
    func unmaskWithOrderTracksRanges() {
        let original = "안녕 최강자님과 용사님"
        let entry1 = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: true,
            origin: .termStandalone(termKey: "e1")
        )
        let entry2 = GlossaryEntry(
            source: "용사",
            target: "Yongsa",
            variants: [],
            preMask: true,
            isAppellation: true,
            origin: .termStandalone(termKey: "e2")
        )

        guard let r1 = original.range(of: "최강자"),
              let r2 = original.range(of: "용사") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let pieces = SegmentPieces(
            segmentID: "seg4",
            originalText: original,
            pieces: [
                .text(String(original[original.startIndex..<r1.lowerBound]), range: original.startIndex..<r1.lowerBound),
                .term(entry1, range: r1),
                .text(String(original[r1.upperBound..<r2.lowerBound]), range: r1.upperBound..<r2.lowerBound),
                .term(entry2, range: r2),
                .text(String(original[r2.upperBound..<original.endIndex]), range: r2.upperBound..<original.endIndex)
            ]
        )

        let textWithTokens = "안녕 __E#1__님과 __E#2__님"
        let locks: [String: LockInfo] = [
            "__E#1__": .init(placeholder: "__E#1__", target: entry1.target, endsWithBatchim: false, endsWithRieul: false, isAppellation: true),
            "__E#2__": .init(placeholder: "__E#2__", target: entry2.target, endsWithBatchim: false, endsWithRieul: false, isAppellation: true)
        ]
        let tokenEntries: [String: GlossaryEntry] = [
            "__E#1__": entry1,
            "__E#2__": entry2
        ]

        let engine = MaskingEngine()
        let result = engine.unmaskWithOrder(
            in: textWithTokens,
            pieces: pieces,
            locksByToken: locks,
            tokenEntries: tokenEntries
        )

        #expect(result.text.contains(entry1.target))
        #expect(result.text.contains(entry2.target))
        #expect(result.ranges.count == 2)
        for range in result.ranges {
            #expect(range.type == .masked)
        }
        #expect(result.deltas.count == 2)
    }
}
