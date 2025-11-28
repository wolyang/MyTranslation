import Foundation
import SwiftData
import Testing
@testable import MyTranslation

/// SPEC_TERM_DEACTIVATION 7.x 케이스 전용 테스트 모음
struct TextEntityProcessorIntegrationTests {
    private let processor = TextEntityProcessor()
    
    // Test 1 (Phase 0) 기본 등장 체크
    @Test
    func test1_appearanceFiltersMatchedSources() {
        let term = makeTerm(key: "sorato", sources: [
            makeSource("宙人", prohibitStandalone: false),
            makeSource("ソラト", prohibitStandalone: false)
        ])
        let matchedSources = ["sorato": Set(["宙人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宙人是地球人."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.contains { $0.source == "宙人" })
        #expect(result.glossaryEntries.allSatisfy { $0.source != "ソラト" })
    }

    // Test 2 (Phase 0) deactivatedIn 단일 문맥
    @Test
    func test2_filtersSingleDeactivationContext() {
        let term = makeTerm(
            key: "sorato",
            sources: [makeSource("宙人", prohibitStandalone: false)],
            deactivatedIn: ["宇宙人"]
        )
        let matchedSources = ["sorato": Set(["宙人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宇宙人宙人来了."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
        #expect(result.pieces.pieces.allSatisfy { if case .term = $0 { return false } else { return true } })
    }

    // Test 3 (Phase 0) deactivatedIn 복수 문맥
    @Test
    func test3_filtersMultipleDeactivationContexts() {
        let term = makeTerm(
            key: "sorato",
            sources: [makeSource("宙人", prohibitStandalone: false)],
            deactivatedIn: ["宇宙人", "外星人"]
        )
        let matchedSources = ["sorato": Set(["宙人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("外星人宙人来了."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 4 (Phase 0) deactivatedIn 비어있음
    @Test
    func test4_allowsWhenDeactivatedEmpty() {
        let term = makeTerm(
            key: "sorato",
            sources: [makeSource("宙人", prohibitStandalone: false)],
            deactivatedIn: []
        )
        let matchedSources = ["sorato": Set(["宙人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宇宙人宙人来了."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.count == 1)
        #expect(result.glossaryEntries.first?.source == "宙人")
    }

    // Test 5 (Phase 0) 비활성화 문맥이 없으면 활성화
    @Test
    func test5_allowsWhenContextNotPresent() {
        let term = makeTerm(
            key: "sorato",
            sources: [makeSource("宙人", prohibitStandalone: false)],
            deactivatedIn: ["宇宙人"]
        )
        let matchedSources = ["sorato": Set(["宙人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宙人来了."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.count == 1)
    }

    // Test 6 (Phase 1) permit source 즉시 활성화
    @Test
    func test6_activatesPermitStandalone() {
        let term = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
        )
        let matchedSources = ["ultraman": Set(["ウルトラマン"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン登場!"),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.count == 1)
        #expect(result.glossaryEntries.first?.origin == .termStandalone(termKey: "ultraman"))
    }

    // Test 7 (Phase 1) prohibitStandalone=true는 스킵
    @Test
    func test7_skipsProhibitWithoutActivator() {
        let term = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)]
        )
        let matchedSources = ["taro": Set(["太郎"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("太郎登場!"),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 8 (Phase 1) 복수 소스 중 permit만 활성화
    @Test
    func test8_activatesOnlyPermittedSources() {
        let term = makeTerm(
            key: "ultraman",
            sources: [
                makeSource("ウルトラマン", prohibitStandalone: false),
                makeSource("超人", prohibitStandalone: true)
            ]
        )
        let matchedSources = ["ultraman": Set(["ウルトラマン", "超人"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン和超人."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.count == 1)
        #expect(result.glossaryEntries.first?.source == "ウルトラマン")
    }

    // Test 9 (Phase 1) usedTermKeys 추적
    @Test
    func test9_tracksUsedTermKeys() {
        let term1 = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
        )
        let term2 = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)],
            activators: [term1]
        )
        let matchedSources = [
            "ultraman": Set(["ウルトラマン"]),
            "taro": Set(["太郎"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン太郎登場!"),
            matchedTerms: [term1, term2],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.count == 2)
    }

    // Test 10 (Phase 2) Activator 없음 → 스킵
    @Test
    func test10_skipsProhibitWithoutActivator() {
        let term = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)]
        )
        let matchedSources = ["taro": Set(["太郎"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("太郎登場!"),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 11 (Phase 2) Activator가 비활성화되면 스킵
    @Test
    func test11_skipsWhenActivatorDeactivated() {
        let activator = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: false)],
            deactivatedIn: ["宇宙人"]
        )
        let prohibited = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)],
            activators: [activator]
        )
        let matchedSources = [
            "ultraman": Set(["ウルトラマン"]),
            "taro": Set(["太郎"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宇宙人ウルトラマン太郎登場!"),
            matchedTerms: [activator, prohibited],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 12 (Phase 2) Activator가 usedTermKeys에 있으면 활성화
    @Test
    func test12_activatesWhenActivatorUsed() {
        let activator = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
        )
        let prohibited = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)],
            activators: [activator]
        )
        let matchedSources = [
            "ultraman": Set(["ウルトラマン"]),
            "taro": Set(["太郎"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン太郎登場!"),
            matchedTerms: [activator, prohibited],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.contains { $0.source == "太郎" })
    }

    // Test 13 (Phase 2) 복수 activators OR 조건
    @Test
    func test13_multipleActivatorsAreOrCondition() {
        let term1 = makeTerm(key: "ultraman", sources: [makeSource("ウルトラマン", prohibitStandalone: false)])
        let term2 = makeTerm(key: "zero", sources: [makeSource("ゼロ", prohibitStandalone: false)])
        let term3 = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)],
            activators: [term1, term2]
        )
        let matchedSources = [
            "ultraman": Set(["ウルトラマン"]),
            "taro": Set(["太郎"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン太郎登場!"),
            matchedTerms: [term1, term2, term3],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.contains { $0.source == "太郎" })
    }

    // Test 14 (Phase 2) 자기 자신을 activator로 지정한 경우 스킵
    @Test
    func test14_selfActivatorIsIgnored() {
        let term = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: true)]
        )
        term.activators.append(term)
        let matchedSources = ["ultraman": Set(["ウルトラマン"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン登場!"),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 15 (Phase 3) Pair pattern + ComponentTerm.source(left/right)
    @Test
    func test15_pairPatternKeepsComponentSources() {
        let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
        let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
        addComponent(family, pattern: "person", role: "family")
        addComponent(given, pattern: "person", role: "given")
        let pattern = makePattern(
            name: "person",
            leftRole: "family",
            rightRole: "given",
            sourceTemplates: ["{L}{R}"],
            targetTemplates: ["{L} {R}"]
        )
        let matchedSources = ["hong": Set(["홍"]), "gildong": Set(["길동"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("홍길동은 위인이다."),
            matchedTerms: [family, given],
            patterns: [pattern],
            matchedSources: matchedSources
        )
        let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true } else { return false } }
        #expect(composer?.source == "홍길동")
        #expect(composer?.componentTerms.map(\.source) == ["홍", "길동"])
    }

    // Test 16 (Phase 3) Left-only pattern (suffix)
    @Test
    func test16_leftOnlyPatternCreatesComposer() {
        let base = makeTerm(
            key: "taro",
            target: "타로",
            sources: [makeSource("太郎", prohibitStandalone: false)],
            variants: ["태랑", "태로"]
        )
        addComponent(base, pattern: "suffix", role: nil)
        let pattern = makePattern(
            name: "suffix",
            leftRole: nil,
            rightRole: nil,
            sourceTemplates: ["{L}さん"],
            targetTemplates: ["{L}씨"]
        )
        let matchedSources = ["taro": Set(["太郎"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("太郎さん登場!"),
            matchedTerms: [base],
            patterns: [pattern],
            matchedSources: matchedSources
        )
        let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true } else { return false } }
        #expect(composer?.source == "太郎さん")
        #expect(composer?.target == "타로씨")
        if let variants = composer?.variants {
            #expect(Set(variants) == Set(["태랑씨", "태로씨"]))
        }
        #expect(composer?.componentTerms.count == 1)
        #expect(composer?.componentTerms.first?.source == "太郎")
        #expect(composer?.componentTerms.first?.key == "taro")
        if case .composer(_, let left, let right, _) = composer?.origin {
            #expect(left == "taro")
            #expect(right == nil)
        }
    }

    // Test 17 (Phase 3) skipPairsIfSameTerm=true
    @Test
    func test17_skipsWhenSameTermPair() {
        let term = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
        addComponent(term, pattern: "person", role: "family")
        addComponent(term, pattern: "person", role: "given")
        let pattern = makePattern(
            name: "person",
            leftRole: "family",
            rightRole: "given",
            skipPairsIfSameTerm: true
        )
        let matchedSources = ["hong": Set(["홍"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("홍홍은 누구?"),
            matchedTerms: [term],
            patterns: [pattern],
            matchedSources: matchedSources
        )
        let composers = result.glossaryEntries.filter { if case .composer = $0.origin { return true } else { return false } }
        #expect(composers.isEmpty)
    }

    // Test 18 (Phase 3) 그룹 매칭
    @Test
    func test18_groupMatchingProducesAllPairs() {
        let family1 = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
        let family2 = makeTerm(key: "kim", sources: [makeSource("김", prohibitStandalone: false)])
        let given1 = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
        let given2 = makeTerm(key: "chulsoo", sources: [makeSource("철수", prohibitStandalone: false)])

        let group = makeGroup(pattern: "person", name: "A")
        [family1, family2].forEach { addComponent($0, pattern: "person", role: "family", groups: [group]) }
        [given1, given2].forEach { addComponent($0, pattern: "person", role: "given", groups: [group]) }

        let matchedSources: [String: Set<String>] = [
            "hong": Set(["홍"]),
            "kim": Set(["김"]),
            "gildong": Set(["길동"]),
            "chulsoo": Set(["철수"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("홍길동김철수."),
            matchedTerms: [family1, family2, given1, given2],
            patterns: [makePersonPattern()],
            matchedSources: matchedSources
        )
        let composers = result.glossaryEntries.filter { if case .composer = $0.origin { return true } else { return false } }
        #expect(composers.count == 4)
    }

    // Test 19 (Phase 3) Composer보다 standalone 우선
    @Test
    func test19_standaloneBeatsComposer() {
        let full = makeTerm(key: "hong-gildong", sources: [makeSource("홍길동", prohibitStandalone: false)])
        let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
        let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
        addComponent(family, pattern: "person", role: "family")
        addComponent(given, pattern: "person", role: "given")
        let pattern = makePattern(name: "person", leftRole: "family", rightRole: "given", sourceTemplates: ["{L}{R}"])
        let matchedSources: [String: Set<String>] = [
            "hong-gildong": Set(["홍길동"]),
            "hong": Set(["홍"]),
            "gildong": Set(["길동"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("홍길동은 위인."),
            matchedTerms: [full, family, given],
            patterns: [pattern],
            matchedSources: matchedSources
        )
        let entry = result.glossaryEntries.first { $0.source == "홍길동" }
        #expect(entry?.origin == .termStandalone(termKey: "hong-gildong"))
    }

    // Test 20 (Phase 3) Composer 생성 시 deactivated source 필터
    @Test
    func test20_composerSkipsDeactivatedSource() {
        let family = makeTerm(
            key: "hong",
            sources: [
                makeSource("홍", prohibitStandalone: false),
                makeSource("洪", prohibitStandalone: false)
            ],
            deactivatedIn: ["宇宙"]
        )
        let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
        addComponent(family, pattern: "person", role: "family")
        addComponent(given, pattern: "person", role: "given")
        let matchedSources: [String: Set<String>] = [
            "hong": Set(["홍", "洪"]),
            "gildong": Set(["길동"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("宇宙洪길동."),
            matchedTerms: [family, given],
            patterns: [makePersonPattern()],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.allSatisfy { $0.source != "洪길동" })
    }

    // Test 21 (Phase 4) 더 긴 source 우선 분할
    @Test
    func test21_longestSourceWins() {
        let full = makeTerm(key: "ultraman-taro", sources: [makeSource("ウルトラマン太郎", prohibitStandalone: false)])
        let left = makeTerm(key: "ultraman", sources: [makeSource("ウルトラマン", prohibitStandalone: false)])
        let right = makeTerm(key: "taro", sources: [makeSource("太郎", prohibitStandalone: false)])
        let matchedSources: [String: Set<String>] = [
            "ultraman-taro": Set(["ウルトラマン太郎"]),
            "ultraman": Set(["ウルトラマン"]),
            "taro": Set(["太郎"])
        ]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン太郎登場!"),
            matchedTerms: [full, left, right],
            patterns: [],
            matchedSources: matchedSources
        )
        let termPieces = result.pieces.pieces.compactMap { if case .term(let entry, _) = $0 { return entry } else { return nil } }
        #expect(termPieces.count == 1)
        #expect(termPieces.first?.source == "ウルトラマン太郎")
    }

    // Test 22 (Phase 4) 동일 길이 source의 비결정적 순서
    @Test
    func test22_sameLengthMatchesOnce() {
        let t1 = makeTerm(key: "k1", sources: [makeSource("AAA", prohibitStandalone: false)])
        let t2 = makeTerm(key: "k2", sources: [makeSource("AAA", prohibitStandalone: false)])
        let matchedSources: [String: Set<String>] = ["k1": Set(["AAA"]), "k2": Set(["AAA"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("AAA登場!"),
            matchedTerms: [t1, t2],
            patterns: [],
            matchedSources: matchedSources
        )
        let termPieces = result.pieces.pieces.compactMap { if case .term(let entry, _) = $0 { return entry } else { return nil } }
        #expect(termPieces.count == 1)
        #expect(termPieces.first?.source == "AAA")
    }

    // Test 23 (Phase 4) range 계산
    @Test
    func test23_rangeCalculation() {
        let term = makeTerm(key: "ultraman-taro", sources: [makeSource("ウルトラマン太郎", prohibitStandalone: false)])
        let matchedSources = ["ultraman-taro": Set(["ウルトラマン太郎"])]
        let segment = makeSegment("前置詞ウルトラマン太郎登場!")
        let result = processor.buildSegmentPieces(
            segment: segment,
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        if case .term(_, let range) = result.pieces.pieces.first(where: { if case .term = $0 { return true } else { return false } }) {
            let extracted = String(segment.originalText[range])
            #expect(extracted == "ウルトラマン太郎")
            #expect(segment.originalText.distance(from: segment.originalText.startIndex, to: range.lowerBound) == 3)
        } else {
            Issue.record("용어가 생성되지 않았습니다.")
        }
    }

    // Test 24 (Phase 4) 동일 source 다회 등장
    @Test
    func test24_matchesRepeatedSources() {
        let term = makeTerm(key: "taro", sources: [makeSource("太郎", prohibitStandalone: false)])
        let matchedSources = ["taro": Set(["太郎"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("太郎和太郎是兄弟."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        let termPieces = result.pieces.pieces.filter { if case .term = $0 { return true } else { return false } }
        #expect(termPieces.count == 2)
    }

    // Test 25 (통합) Phase 0-4 종합 시나리오
    @Test
    func test25_fullPipelineScenario() {
        let term1 = makeTerm(
            key: "kai",
            target: "가이",
            sources: [makeSource("凯", prohibitStandalone: false)],
            variants: ["카이"]
        )
        let term2 = makeTerm(
            key: "san",
            target: "상",
            sources: [makeSource("桑", prohibitStandalone: true)],
            variants: ["산"]
        )
        addComponent(term1, pattern: "appellation", role: "name")
        addComponent(term2, pattern: "appellation", role: "marker")
        let matchedSources: [String: Set<String>] = [
            "kai": Set(["凯"]),
            "san": Set(["桑"])
        ]
        let pattern = makePattern(
            name: "appellation",
            leftRole: "name",
            rightRole: "marker",
            sourceTemplates: ["{L}{R}"],
            targetTemplates: ["{L} {R}"],
            sourceJoiners: ["", " "],
            skipPairsIfSameTerm: false
        )
        
        let result = processor.buildSegmentPieces(
            segment: makeSegment("难道我就要陪你和凯桑在这片什么都没有的地方呆三天嘛！"),
            matchedTerms: [term1, term2],
            patterns: [pattern],
            matchedSources: matchedSources
        )
        guard let composer = result.glossaryEntries.first(where:{ if case .composer = $0.origin { return true } else { return false } }) else {
            #expect(Bool(false), "조합어가 생성되지 않았습니다.")
            return
        }
        #expect(result.glossaryEntries.count == 2)
        #expect(composer.source == "凯桑")
        #expect(composer.target == "가이 상")
        #expect(composer.variants.contains("카이산"))
        #expect(composer.componentTerms.map(\.source) == ["凯", "桑"])
        let termPieces = result.pieces.pieces.filter { if case .term = $0 { return true } else { return false } }
        #expect(termPieces.count == 1)  // longest-first로 composer만 사용
    }

    // Test 26 (통합) Deduplicator 통합
    @Test
    func test26_deduplicatorMergesVariants() {
        let term = makeTerm(
            key: "key1",
            target: "TARGET",
            sources: [
                makeSource("AAA", prohibitStandalone: false),
                makeSource("AAA", prohibitStandalone: false)
            ]
        )
        let matchedSources = ["key1": Set(["AAA"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("AAA登場!"),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        let deduped = Deduplicator.deduplicate(result.glossaryEntries)
        #expect(result.glossaryEntries.count == 1)
        #expect(deduped.count == 1)
    }

    // Test 27 (통합) DefaultTranslationRouter.prepareMaskingContext 대체 검증
    @Test
    func test27_routerPreparesMaskingContext() async {
        let segment = makeSegment("ウルトラマン太郎登場!")
        let activator = makeTerm(
            key: "ultraman",
            sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
        )
        let prohibited = makeTerm(
            key: "taro",
            sources: [makeSource("太郎", prohibitStandalone: true)],
            activators: [activator]
        )
        let glossaryData = GlossaryData(
            matchedTerms: [activator, prohibited],
            patterns: [makePersonPattern()],
            matchedSourcesByKey: ["ultraman": Set(["ウルトラマン"]), "taro": Set(["太郎"])]
        )

        let context = await prepareMaskingContextForTest(
            segments: [segment],
            glossaryData: glossaryData
        )

        #expect(context.segmentPieces.count == 1)
        #expect(context.segmentPieces.first?.pieces.contains { if case .term = $0 { return true } else { return false } } == true)
        #expect(context.glossaryEntries.first?.isEmpty == false)
    }

    // Test 28 (Edge) 빈 세그먼트
    @Test
    func test28_handlesEmptySegment() {
        let result = processor.buildSegmentPieces(
            segment: makeSegment(""),
            matchedTerms: [],
            patterns: [],
            matchedSources: [:]
        )
        #expect(result.pieces.pieces.count == 1)
        if case .text(let text, _) = result.pieces.pieces.first { #expect(text.isEmpty) }
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 29 (Edge) matchedTerms 빈 배열
    @Test
    func test29_handlesEmptyMatchedTerms() {
        let result = processor.buildSegmentPieces(
            segment: makeSegment("ウルトラマン太郎"),
            matchedTerms: [],
            patterns: [],
            matchedSources: [:]
        )
        #expect(result.pieces.pieces.count == 1)
        if case .text(let text, _) = result.pieces.pieces.first { #expect(text == "ウルトラマン太郎") }
        #expect(result.glossaryEntries.isEmpty)
    }

    // Test 30 (Edge) 모든 term이 deactivatedIn으로 필터링
    @Test
    func test30_allTermsFilteredByDeactivation() {
        let t1 = makeTerm(key: "t1", sources: [makeSource("A", prohibitStandalone: false)], deactivatedIn: ["CTX"])
        let t2 = makeTerm(key: "t2", sources: [makeSource("B", prohibitStandalone: false)], deactivatedIn: ["CTX"])
        let matchedSources = ["t1": Set(["A"]), "t2": Set(["B"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("CTXAB"),
            matchedTerms: [t1, t2],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.isEmpty)
        #expect(result.pieces.pieces.count == 1)
    }

    // Test 31 (Edge) Glossary.Util.renderSources 튜플(left/right/composed)
    @Test
    func test31_renderSourcesTakesLeftRight() {
        let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
        let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
        addComponent(family, pattern: "person", role: "family")
        addComponent(given, pattern: "person", role: "given")
        let matchedSources = ["hong": Set(["홍"]), "gildong": Set(["길동"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("홍길동"),
            matchedTerms: [family, given],
            patterns: [makePersonPattern()],
            matchedSources: matchedSources
        )
        let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true } else { return false } }
        #expect(composer?.componentTerms.map(\.source) == ["홍", "길동"])
    }

    // Test 32 (Import) Sheets/JSON Import deactivated_in 파싱
    @Test
    func test32_importParsesDeactivatedIn() throws {
        var used: Set<String> = []
        var refIndex = RefIndex()
        let row = TermRow(
            key: "alpha",
            sourcesOK: "A",
            sourcesProhibit: "",
            target: "타겟",
            variants: "",
            tags: "",
            components: "",
            isAppellation: false,
            preMask: false,
            activatedBy: "",
            deactivatedIn: "宇宙人"
        )
        let term = parseTermRow(sheetName: "Sheet", row: row, used: &used, refIndex: &refIndex)
        #expect(term.deactivatedIn == ["宇宙人"])

        let json = #"{"key":"beta","sources":[{"source":"B","prohibitStandalone":false}],"target":"타겟","variants":[],"tags":[],"components":[],"isAppellation":false,"preMask":false,"deactivated_in":["宇宙人","外星人"]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(JSTerm.self, from: Data(json.utf8))
        #expect(decoded.deactivatedIn == ["宇宙人", "外星人"])
    }

    // Test 33 (Edge) 특수문자/이모지 세그먼트
    @Test
    func test33_handlesEmojiSources() {
        let term = makeTerm(key: "smile", sources: [makeSource("😊", prohibitStandalone: false)])
        let matchedSources = ["smile": Set(["😊"])]
        let result = processor.buildSegmentPieces(
            segment: makeSegment("今日は😊いい天気です."),
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        let termPiece = result.pieces.pieces.first { piece in
            if case .term(let entry, _) = piece { return entry.source == "😊" }
            return false
        }
        #expect(termPiece != nil)
    }

    // Test 34 (Edge) Unicode normalization 현행 동작
    @Test
    func test34_unicodeNormalizationCurrentBehavior() {
        let term = makeTerm(key: "ga", sources: [makeSource("が", prohibitStandalone: false)])
        let matchedSources = ["ga": Set(["が"])]
        let segment = makeSegment("が登場")
        let result = processor.buildSegmentPieces(
            segment: segment,
            matchedTerms: [term],
            patterns: [],
            matchedSources: matchedSources
        )
        #expect(result.glossaryEntries.first?.source == "が")
    }
}

// MARK: - Test helpers

private func makeSegment(_ text: String, id: String = UUID().uuidString) -> Segment {
    Segment(
        id: id,
        url: URL(string: "https://example.com/\(id)")!,
        indexInPage: 0,
        originalText: text,
        normalizedText: text,
        domRange: nil
    )
}

private func makeSource(_ text: String, prohibitStandalone: Bool) -> Glossary.SDModel.SDSource {
    Glossary.SDModel.SDSource(text: text, prohibitStandalone: prohibitStandalone, term: Glossary.SDModel.SDTerm(key: "tmp", target: "tmp"))
}

private func makeTerm(
    key: String,
    target: String? = nil,
    sources: [Glossary.SDModel.SDSource],
    variants: [String] = [],
    deactivatedIn: [String] = [],
    activators: [Glossary.SDModel.SDTerm] = []
) -> Glossary.SDModel.SDTerm {
    let term = Glossary.SDModel.SDTerm(
        key: key,
        target: target ?? key,
        variants: variants,
        isAppellation: false,
        preMask: false
    )
    term.deactivatedIn = deactivatedIn
    term.activators.append(contentsOf: activators)
    term.sources = sources.map { src in Glossary.SDModel.SDSource(text: src.text, prohibitStandalone: src.prohibitStandalone, term: term) }
    return term
}

private func makePattern(
    name: String,
    leftRole: String? = nil,
    rightRole: String? = nil,
    sourceTemplates: [String] = ["{L}{R}"],
    targetTemplates: [String] = ["{L} {R}"],
    sourceJoiners: [String] = [""],
    skipPairsIfSameTerm: Bool = true,
    needPairCheck: Bool = false
) -> Glossary.SDModel.SDPattern {
    Glossary.SDModel.SDPattern(
        name: name,
        leftRole: leftRole,
        leftTagsAll: [],
        leftTagsAny: [],
        leftIncludeTerms: [],
        leftExcludeTerms: [],
        rightRole: rightRole,
        rightTagsAll: [],
        rightTagsAny: [],
        rightIncludeTerms: [],
        rightExcludeTerms: [],
        skipPairsIfSameTerm: skipPairsIfSameTerm,
        sourceTemplates: sourceTemplates,
        targetTemplates: targetTemplates,
        sourceJoiners: sourceJoiners,
        isAppellation: false,
        preMask: false,
        needPairCheck: needPairCheck
    )
}

private func makePersonPattern() -> Glossary.SDModel.SDPattern {
    makePattern(
        name: "person",
        leftRole: "family",
        rightRole: "given",
        sourceTemplates: ["{L}{R}"],
        targetTemplates: ["{L} {R}"],
        sourceJoiners: [""],
        skipPairsIfSameTerm: false
    )
}

private func addComponent(
    _ term: Glossary.SDModel.SDTerm,
    pattern: String,
    role: String?,
    groups: [Glossary.SDModel.SDGroup] = []
) {
    let component = Glossary.SDModel.SDComponent(pattern: pattern, role: role, term: term)
    groups.forEach { group in
        component.groupLinks.append(Glossary.SDModel.SDComponentGroup(component: component, group: group))
    }
    term.components.append(component)
}

private func makeGroup(pattern: String, name: String) -> Glossary.SDModel.SDGroup {
    Glossary.SDModel.SDGroup(pattern: pattern, name: name)
}

// MARK: - Masking context helper (router 대체)

private struct TestMaskingContext {
    let maskedSegments: [Segment]
    let segmentPieces: [SegmentPieces]
    let glossaryEntries: [[GlossaryEntry]]
}

private func prepareMaskingContextForTest(
    segments: [Segment],
    glossaryData: GlossaryData?
) async -> TestMaskingContext {
    let processor = TextEntityProcessor()
    let maskingEngine = MaskingEngine()
    let normalizationEngine = NormalizationEngine()

    var segmentPieces: [SegmentPieces] = []
    var maskedSegments: [Segment] = []
    var glossaryEntries: [[GlossaryEntry]] = []

    for segment in segments {
        let (pieces, entries) = processor.buildSegmentPieces(
            segment: segment,
            matchedTerms: glossaryData?.matchedTerms ?? [],
            patterns: glossaryData?.patterns ?? [],
            matchedSources: glossaryData?.matchedSourcesByKey ?? [:]
        )
        segmentPieces.append(pieces)
        glossaryEntries.append(entries)

        let pack = maskingEngine.maskFromPieces(pieces: pieces, segment: segment)
        maskedSegments.append(
            Segment(
                id: pack.seg.id,
                url: pack.seg.url,
                indexInPage: pack.seg.indexInPage,
                originalText: pack.masked,
                normalizedText: pack.seg.normalizedText,
                domRange: pack.seg.domRange
            )
        )
    }

    return TestMaskingContext(
        maskedSegments: maskedSegments,
        segmentPieces: segmentPieces,
        glossaryEntries: glossaryEntries
    )
}
