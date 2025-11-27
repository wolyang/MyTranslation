import Foundation
import Testing
@testable import MyTranslation

struct TermMaskerUnitTests {

    @Test
    func chooseJosaResolvesCompositeParticles() {
        let masker = TermMasker()

        #expect(masker.chooseJosa(for: "만가", baseHasBatchim: false, baseIsRieul: false) == "만이")
        #expect(masker.chooseJosa(for: "만 는", baseHasBatchim: false, baseIsRieul: false) == "만 는")
        #expect(masker.chooseJosa(for: "만로", baseHasBatchim: true, baseIsRieul: true) == "만으로")
        #expect(masker.chooseJosa(for: "에게만", baseHasBatchim: true, baseIsRieul: false) == "에게만")
    }

    @Test
    func normalizeDamagedETokensRestoresCorruptedPlaceholders() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#31__": .init(placeholder: "__E#31__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "텍스트 E#３１__ 와 __ E #31 __ 그리고 #31__ 을 포함"
        let restored = masker.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored.contains("__E#31__"))
        #expect(restored.components(separatedBy: "__E#31__").count == 4)
    }

    @Test
    func normalizeDamagedETokensIgnoresUnknownIds() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#7__": .init(placeholder: "__E#7__", target: "Seven", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "E#99__ 는 모르는 토큰이다."
        let restored = masker.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored == corrupted)
    }

    @Test
    func surroundTokenWithNBSPAddsSpacingAroundLatin() {
        let masker = TermMasker()
        let token = "__E#1__"
        let text = "Hello__E#1__World"

        let spaced = masker.surroundTokenWithNBSP(text, token: token)

        #expect(spaced.contains("Hello\u{00A0}\(token)\u{00A0}World"))
    }

    @Test
    func insertSpacesAroundTokensOnlyForPunctOnlyParagraphs() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments

        let text = "__E#1__,__E#2__!"
        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ , __E#2__ !"))
    }

    @Test
    func insertSpacesAroundTokensKeepsNormalParagraphsUntouched() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments

        let text = "본문과__E#1__이 섞여 있다."
        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced == text)
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentRemovesExtraSpaces() {
        let masker = TermMasker()
        let text = ",   Alpha   !"

        let collapsed = masker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == ",Alpha!")
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentKeepsParticles() {
        let masker = TermMasker()
        let text = ", Alpha의 "

        let collapsed = masker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == text)
    }

    @Test
    func normalizeTokensAndParticlesReplacesMultipleTokens() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#1__": .init(placeholder: "__E#1__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false),
            "__E#2__": .init(placeholder: "__E#2__", target: "Beta", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let text = "__E#1____E#2__를 본다"
        let normalized = masker.normalizeTokensAndParticles(in: text, locksByToken: locks)

        #expect(normalized.contains("AlphaBeta"))
        #expect(normalized.hasSuffix("본다"))
    }

    @Test
    func insertSpacesAroundTokensAddsSpaceNearPunctuation() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments
        let text = "__E#1__!__E#2__?"

        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ ! __E#2__ ?"))
    }

    @Test
    func segmentPiecesTracksRanges() {
        let text = "Hello 최강자님, welcome!"
        let segment = Segment(
            id: "seg1",
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

        let masker = TermMasker()
        let (pieces, _) = masker.buildSegmentPieces(
            segment: segment,
            matchedTerms: [term],
            patterns: [],
            matchedSources: [term.key: Set([source.text])],
            termActivationFilter: TermActivationFilter()
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

        let masker = TermMasker()
        let (pieces, _) = masker.buildSegmentPieces(
            segment: segment,
            matchedTerms: [term],
            patterns: [],
            matchedSources: [term.key: Set([source.text])],
            termActivationFilter: TermActivationFilter()
        )
        let pack = masker.maskFromPieces(pieces: pieces, segment: segment)

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

        let name = TermMasker.NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let kaiGlossary = TermMasker.NameGlossary(
            target: "가이",
            variants: ["카이", "케이"],
            expectedCount: 2,
            fallbackTerms: nil
        )
        let kGlossary = TermMasker.NameGlossary(
            target: "케이",
            variants: [],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "케빈",
            variants: ["케이빈", "Kevin"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "케빈",
            variants: [""],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "울트라",
            variants: ["오", "오쿠", "올림픽"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "쟈그라",
            variants: ["가고라", "가굴라"],
            expectedCount: 1,
            fallbackTerms: nil
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
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

        let glossary = TermMasker.NameGlossary(
            target: "가이",
            variants: [],
            expectedCount: 1,
            fallbackTerms: [
                .init(termKey: "guy-fallback", target: "가이", variants: ["Guy"])
            ]
        )

        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
            in: "Guy와 Guy를 만났다",
            pieces: pieces,
            nameGlossaries: [glossary]
        )

        #expect(result.text == "가이와 가이를 만났다")
        #expect(result.ranges.count == 2)
        #expect(result.ranges.allSatisfy { String(result.text[$0.range]) == "가이" })
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

        let masker = TermMasker()
        let result = masker.unmaskWithOrder(
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

    @Test
    func normalizeVariantsAndParticlesTracksPreNormalizedRanges() {
        let text = "나는 grey와 grey를 좋아함"
        let name = TermMasker.NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let entry = GlossaryEntry(
            source: "grey",
            target: "gray",
            variants: ["grey"],
            preMask: false,
            isAppellation: false,
            origin: .termStandalone(termKey: "tGrey")
        )

        let masker = TermMasker()
        let result = masker.normalizeVariantsAndParticles(
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
        let masker = TermMasker()
        let names = [
            TermMasker.NameGlossary(target: "쟈그라", variants: ["가구라", "가굴라", "가고라"], expectedCount: 1, fallbackTerms: nil),
            TermMasker.NameGlossary(target: "쿠레나이 가이", variants: ["홍카이"], expectedCount: 1, fallbackTerms: nil)
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
        let normalized = masker.normalizeVariantsAndParticles(
            in: text,
            entries: Array(zip(names, entries)),
            baseText: text,
            cumulativeDelta: 0
        )

        #expect(normalized.text.contains("쟈그라만이"))
        #expect(normalized.text.contains("쿠레나이 가이만에게"))
    }
}
