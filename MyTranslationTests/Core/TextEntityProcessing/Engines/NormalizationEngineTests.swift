import Foundation
import Testing
@testable import MyTranslation

struct NormalizationEngineTests {

    @Test
    func normalizeWithOrderTracksNormalizedRanges() {
        let original = "I love grey and grey"
        let translation = "나는 grey와 grey를 좋아함"
        let entry = GlossaryEntry(
            source: "grey",
            target: "gray",
            variants: ["grey"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "grey")
        )

        let r1 = original.range(of: "grey")!
        let r2 = original.range(of: "grey", range: r1.upperBound..<original.endIndex)!
        let pieces = SegmentPieces(
            segmentID: "seg3",
            originalText: original,
            pieces: [
                .text(String(original[original.startIndex..<r1.lowerBound]), range: original.startIndex..<r1.lowerBound),
                .term(entry, range: r1),
                .text(String(original[r1.upperBound..<r2.lowerBound]), range: r1.upperBound..<r2.lowerBound),
                .term(entry, range: r2),
                .text(String(original[r2.upperBound..<original.endIndex]), range: r2.upperBound..<original.endIndex)
            ]
        )

        let name = NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: translation,
            pieces: pieces,
            nameGlossaries: [name]
        )

        #expect(result.text.contains("gray"))
        #expect(result.ranges.count == 2)
        #expect(result.preNormalizedRanges.count == 2)
        for range in result.ranges {
            #expect(String(result.text[range.range]) == "gray")
            #expect(range.type == .normalized)
        }
        for range in result.preNormalizedRanges {
            #expect(range.type == .normalized)
        }
    }

    @Test
    func normalizeWithOrderHandlesResidualVariantsInPhase4() {
        let original = "凯文说话"
        guard let nameRange = original.range(of: "凯文") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "凯文",
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "c1")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4",
            originalText: original,
            pieces: [
                .text(String(original[original.startIndex..<nameRange.lowerBound]), range: original.startIndex..<nameRange.lowerBound),
                .term(entry, range: nameRange),
                .text(String(original[nameRange.upperBound..<original.endIndex]), range: nameRange.upperBound..<original.endIndex)
            ]
        )

        let glossary = NameGlossary(
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "케이빈이 말할 때, 케이빈도",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "케빈이 말할 때, 케빈도")
        #expect(result.ranges.count == 2)
        #expect(result.ranges.allSatisfy { String(result.text[$0.range]) == "케빈" })
    }

    @Test
    func normalizeWithOrderRespectsProtectedRangesInPhase4() {
        let original = "凯和k,凯"
        guard let firstKai = original.range(of: "凯"),
              let secondKai = original.range(of: "凯", range: firstKai.upperBound..<original.endIndex),
              let kRange = original.range(of: "k") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let kaiEntry = GlossaryEntry(
            source: "凯",
            target: "가이",
            variants: ["카이", "케이"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "kai")
        )
        let kEntry = GlossaryEntry(
            source: "k",
            target: "케이",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "k")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-protected",
            originalText: original,
            pieces: [
                .term(kaiEntry, range: firstKai),
                .text(String(original[firstKai.upperBound..<kRange.lowerBound]), range: firstKai.upperBound..<kRange.lowerBound),
                .term(kEntry, range: kRange),
                .text(String(original[kRange.upperBound..<secondKai.lowerBound]), range: kRange.upperBound..<secondKai.lowerBound),
                .term(kaiEntry, range: secondKai)
            ]
        )

        let kaiGlossary = NameGlossary(
            target: "가이",
            variants: ["카이", "케이"],
            expectedCount: 2,
            fallbackTerms: nil
        )
        let kGlossary = NameGlossary(
            target: "케이",
            variants: [],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "카이와 케이, 카이의 친구",
            pieces: pieces,
            nameGlossaries: [kaiGlossary, kGlossary]
        )

        #expect(result.text == "가이와 케이, 가이의 친구")
        let kaiCount = result.ranges.filter { $0.entry.target == "가이" }.count
        let keiCount = result.ranges.filter { $0.entry.target == "케이" }.count
        #expect(kaiCount == 2)
        #expect(keiCount == 1)
        #expect(result.ranges.contains { $0.entry.target == "케이" && String(result.text[$0.range]) == "케이" })
    }

    @Test
    func normalizeWithOrderHandlesMultipleResidualInstances() {
        let original = "凯文"
        guard let kaiwenRange = original.range(of: "凯文") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "凯文",
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "c2")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-multi",
            originalText: original,
            pieces: [
                .term(entry, range: kaiwenRange)
            ]
        )

        let glossary = NameGlossary(
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "케이빈과 케이빈과 케이빈",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "케빈과 케빈과 케빈")
        #expect(result.ranges.count == 3)
    }

    @Test
    func normalizeWithOrderIgnoresEmptyVariants() {
        let original = "凯文"
        guard let kaiwenRange = original.range(of: "凯文") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "凯文",
            target: "케빈",
            variants: [""],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "c3")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-empty-variant",
            originalText: original,
            pieces: [
                .term(entry, range: kaiwenRange)
            ]
        )

        let glossary = NameGlossary(
            target: "케빈",
            variants: [""],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "케빈",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "케빈")
        #expect(result.ranges.count == 1)
    }

    @Test
    func normalizeWithOrderFiltersSingleCharacterVariantsInPhase4() {
        let original = "奥の力"
        guard let range = original.range(of: "奥") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "奥",
            target: "울트라",
            variants: ["오", "오쿠", "올림픽"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "ao")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-single-char",
            originalText: original,
            pieces: [
                .term(entry, range: range)
            ]
        )

        let glossary = NameGlossary(
            target: "울트라",
            variants: ["오", "오쿠", "올림픽"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "오를 바라보고 오늘은",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "울트라를 바라보고 오늘은")
        #expect(result.text.contains("오늘은"))
    }

    @Test
    func normalizeWithOrderReusesOnlyMatchedVariantsInPhase4() {
        let original = "伽古拉"
        guard let range = original.range(of: "伽古拉") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "伽古拉",
            target: "쟈그라",
            variants: ["가고라", "가구라"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "jg")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-matched-only",
            originalText: original,
            pieces: [
                .term(entry, range: range)
            ]
        )

        let glossary = NameGlossary(
            target: "쟈그라",
            variants: ["가고라", "가굴라"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "가고라는 그 가구라도 사기로 했다.",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "쟈그라는 그 가구라도 사기로 했다.")
    }

    @Test
    func normalizeWithOrderHandlesMatchedFallbackVariantsInPhase4() {
        let original = "가이"
        guard let range = original.range(of: "가이") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let entry = GlossaryEntry(
            source: "가이",
            target: "가이",
            variants: [],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "guy")
        )

        let pieces = SegmentPieces(
            segmentID: "seg3-phase4-fallback-positive",
            originalText: original,
            pieces: [
                .term(entry, range: range)
            ]
        )

        let glossary = NameGlossary(
            target: "가이",
            variants: [],
            expectedCount: 1,
            fallbackTerms: [
                .init(termKey: "guy-fallback", target: "가이", variants: ["Guy"])
            ]
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeWithOrder(
            in: "Guy와 Guy를 만났다",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "가이와 가이를 만났다")
        #expect(result.ranges.count == 2)
        #expect(result.ranges.allSatisfy { String(result.text[$0.range]) == "가이" })
    }

    @Test
    func normalizeVariantsAndParticlesTracksPreNormalizedRanges() {
        let text = "나는 grey와 grey를 좋아함"
        let name = NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let entry = GlossaryEntry(
            source: "grey",
            target: "gray",
            variants: ["grey"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "tGrey")
        )

        let engine = NormalizationEngine()
        let result = engine.normalizeVariantsAndParticles(
            in: text,
            entries: [(name, entry)],
            baseText: text,
            cumulativeDelta: 0
        )

        #expect(result.preNormalizedRanges.count == 2)
        #expect(result.ranges.count == 2)
        for r in result.preNormalizedRanges {
            #expect(String(text[r.range]) == "grey")
            #expect(r.type == .normalized)
        }
        for r in result.ranges {
            #expect(String(result.text[r.range]) == "gray")
        }
        #expect(result.matchedVariants["gray"]?.contains("grey") == true)
    }

    @Test
    func normalizeEntitiesHandlesAuxiliarySequences() {
        let engine = NormalizationEngine()
        let names = [
            NameGlossary(target: "쟈그라", variants: ["가구라", "가굴라", "가고라"], expectedCount: 1, fallbackTerms: nil),
            NameGlossary(target: "쿠레나이 가이", variants: ["홍카이"], expectedCount: 1, fallbackTerms: nil)
        ]
        let entries: [GlossaryEntry] = [
            .init(
                source: "쟈그라",
                target: "쟈그라",
                variants: ["가구라", "가굴라", "가고라"],
                preMask: false,
                isAppellation: false,
                origin: .termStandalone(termKey: "name1")
            ),
            .init(
                source: "쿠레나이 가이",
                target: "쿠레나이 가이",
                variants: ["홍카이"],
                preMask: false,
                isAppellation: false,
                origin: .termStandalone(termKey: "name2")
            )
        ]

        let text = "가구라만이가 나타났고 홍카이만에게 경고했다."
        let normalized = engine.normalizeVariantsAndParticles(
            in: text,
            entries: Array(zip(names, entries)),
            baseText: text,
            cumulativeDelta: 0
        )

        #expect(normalized.text.contains("쟈그라만이"))
        #expect(normalized.text.contains("쿠레나이 가이만에게"))
    }
}
