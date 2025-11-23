import SwiftData
import Testing
@testable import MyTranslation

/// Glossary 데이터/조합 계층의 기본 동작을 검증한다.
struct GlossaryServiceTests {
    // MARK: - Helpers

    @MainActor
    private func makeComponents(importing bundle: JSBundle) throws -> (Glossary.DataProvider, GlossaryComposer) {
        let schema = Schema([
            Glossary.SDModel.SDTerm.self,
            Glossary.SDModel.SDSource.self,
            Glossary.SDModel.SDComponent.self,
            Glossary.SDModel.SDComponentGroup.self,
            Glossary.SDModel.SDGroup.self,
            Glossary.SDModel.SDTag.self,
            Glossary.SDModel.SDTermTagLink.self,
            Glossary.SDModel.SDPattern.self,
            Glossary.SDModel.SDPatternMeta.self,
            Glossary.SDModel.SDSourceIndex.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)

        let upserter = Glossary.SDModel.GlossaryUpserter(context: context, merge: .overwrite)
        _ = try upserter.apply(bundle: bundle)

        return (Glossary.DataProvider(context: context), GlossaryComposer())
    }

    private func buildEntries(
        bundle: JSBundle,
        text: String
    ) async throws -> [GlossaryEntry] {
        let (provider, composer) = try await MainActor.run { try makeComponents(importing: bundle) }
        let data = try await provider.fetchData(for: text)
        return composer.buildEntries(from: data, pageText: text)
    }

    private func makeTerm(
        key: String,
        source: String,
        target: String,
        variants: [String] = [],
        components: [JSComponent] = [],
        isAppellation: Bool = false,
        preMask: Bool = true,
        activatedByKeys: [String]? = nil
    ) -> JSTerm {
        JSTerm(
            key: key,
            sources: [JSSource(source: source, prohibitStandalone: false)],
            target: target,
            variants: variants,
            tags: [],
            components: components,
            isAppellation: isAppellation,
            preMask: preMask,
            activatedByKeys: activatedByKeys
        )
    }

    // MARK: - Tests

    @Test
    func buildEntries_withStandaloneTerms() async throws {
        let bundle = JSBundle(
            terms: [
                makeTerm(key: "hello", source: "hello", target: "안녕", variants: ["hi"]),
                makeTerm(key: "beta", source: "beta", target: "베타")
            ],
            patterns: []
        )

        let entries = try await buildEntries(bundle: bundle, text: "hello there beta")

        let sources = Set(entries.map { $0.source })
        let targets = Dictionary(uniqueKeysWithValues: entries.map { ($0.source, $0.target) })

        #expect(entries.count == 2)
        #expect(sources == ["hello", "beta"])
        #expect(targets["hello"] == "안녕")
        #expect(targets["beta"] == "베타")
    }

    @Test
    func buildEntries_composesPatternWithLeftAndRight() async throws {
        let leftComp = JSComponent(pattern: "pair", role: "L", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let rightComp = JSComponent(pattern: "pair", role: "R", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let pattern = JSPattern(
            name: "pair",
            left: JSTermSelector(role: "L", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            right: JSTermSelector(role: "R", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            skipPairsIfSameTerm: true,
            sourceJoiners: [" "],
            sourceTemplates: ["{L}{J}{R}"],
            targetTemplates: ["{L} {R}"],
            isAppellation: false,
            preMask: true,
            displayName: "pair",
            roles: ["L", "R"],
            grouping: .optional,
            groupLabel: "그룹",
            defaultProhibitStandalone: true,
            defaultIsAppellation: false,
            defaultPreMask: true,
            needPairCheck: false
        )
        let bundle = JSBundle(
            terms: [
                makeTerm(key: "alpha", source: "Alpha", target: "알파", components: [leftComp]),
                makeTerm(key: "beta", source: "Beta", target: "베타", components: [rightComp])
            ],
            patterns: [pattern]
        )

        let entries = try await buildEntries(bundle: bundle, text: "Alpha Beta appear together")

        let composed = entries.first(where: {
            if case let .composer(composerId, leftKey, rightKey, _) = $0.origin {
                return composerId == "pair" && leftKey == "alpha" && rightKey == "beta"
            }
            return false
        })

        let sources = entries.map { $0.source }
        #expect(entries.count == 3) // alpha, beta, Alpha Beta
        #expect(sources.contains("Alpha"))
        #expect(sources.contains("Beta"))
        #expect(sources.contains("Alpha Beta"))
        #expect(composed?.target == "알파 베타")
    }

    @Test
    func buildEntriesForSegment_onlyGeneratesNeededCompositions() async throws {
        let leftComp = JSComponent(pattern: "pair", role: "L", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let rightComp = JSComponent(pattern: "pair", role: "R", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let pattern = JSPattern(
            name: "pair",
            left: JSTermSelector(role: "L", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            right: JSTermSelector(role: "R", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            skipPairsIfSameTerm: true,
            sourceJoiners: [" "],
            sourceTemplates: ["{L}{J}{R}"],
            targetTemplates: ["{L} {R}"],
            isAppellation: false,
            preMask: true,
            displayName: "pair",
            roles: ["L", "R"],
            grouping: .optional,
            groupLabel: "그룹",
            defaultProhibitStandalone: true,
            defaultIsAppellation: false,
            defaultPreMask: true,
            needPairCheck: false
        )
        let bundle = JSBundle(
            terms: [
                makeTerm(key: "alpha", source: "Alpha", target: "알파", components: [leftComp]),
                makeTerm(key: "beta", source: "Beta", target: "베타", components: [rightComp]),
                makeTerm(key: "gamma", source: "Gamma", target: "감마", components: [leftComp]),
                makeTerm(key: "delta", source: "Delta", target: "델타", components: [rightComp])
            ],
            patterns: [pattern]
        )

        let fullText = "Alpha Beta appear here. Gamma Delta appear later."
        let (provider, composer) = try await MainActor.run { try makeComponents(importing: bundle) }
        let data = try await provider.fetchData(for: fullText)

        let firstSegmentEntries = composer.buildEntriesForSegment(from: data, segmentText: "Alpha Beta appear here.")
        let secondSegmentEntries = composer.buildEntriesForSegment(from: data, segmentText: "Gamma Delta appear later.")

        let firstComposed = firstSegmentEntries.filter { if case .composer = $0.origin { return true } else { return false } }.map { $0.source }
        let secondComposed = secondSegmentEntries.filter { if case .composer = $0.origin { return true } else { return false } }.map { $0.source }

        #expect(firstComposed == ["Alpha Beta"])
        #expect(secondComposed == ["Gamma Delta"])
    }

    @Test
    func buildEntriesForSegment_vsPageLevel_efficiency() async throws {
        let leftComp = JSComponent(pattern: "pair", role: "L", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let rightComp = JSComponent(pattern: "pair", role: "R", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let pattern = JSPattern(
            name: "pair",
            left: JSTermSelector(role: "L", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            right: JSTermSelector(role: "R", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            skipPairsIfSameTerm: true,
            sourceJoiners: [" "],
            sourceTemplates: ["{L}{J}{R}"],
            targetTemplates: ["{L} {R}"],
            isAppellation: false,
            preMask: true,
            displayName: "pair",
            roles: ["L", "R"],
            grouping: .optional,
            groupLabel: "그룹",
            defaultProhibitStandalone: true,
            defaultIsAppellation: false,
            defaultPreMask: true,
            needPairCheck: false
        )
        let bundle = JSBundle(
            terms: [
                makeTerm(key: "alpha", source: "Alpha", target: "알파", components: [leftComp]),
                makeTerm(key: "beta", source: "Beta", target: "베타", components: [rightComp]),
                makeTerm(key: "gamma", source: "Gamma", target: "감마", components: [leftComp]),
                makeTerm(key: "delta", source: "Delta", target: "델타", components: [rightComp])
            ],
            patterns: [pattern]
        )

        let fullText = "Alpha Beta appear here. Gamma Delta appear later."
        let (provider, composer) = try await MainActor.run { try makeComponents(importing: bundle) }
        let data = try await provider.fetchData(for: fullText)

        let pageEntries = composer.buildEntries(from: data, pageText: fullText)
        let pageComposedCount = pageEntries.filter { if case .composer = $0.origin { return true } else { return false } }.count

        let seg1 = composer.buildEntriesForSegment(from: data, segmentText: "Alpha Beta appear here.")
        let seg2 = composer.buildEntriesForSegment(from: data, segmentText: "Gamma Delta appear later.")
        let segmentComposedCount = seg1.filter { if case .composer = $0.origin { return true } else { return false } }.count
            + seg2.filter { if case .composer = $0.origin { return true } else { return false } }.count

        #expect(pageComposedCount == 2)  // 모든 조합 생성
        #expect(segmentComposedCount == 2) // 세그먼트별 조합 합계는 동일
        #expect(seg1.count < pageEntries.count) // 세그먼트 단위로는 더 적은 엔트리만 생성
        #expect(seg2.count < pageEntries.count)
    }

    @Test
    func buildEntries_emptyInputReturnsEmpty() async throws {
        let bundle = JSBundle(
            terms: [makeTerm(key: "hello", source: "hello", target: "안녕")],
            patterns: []
        )
        let entries = try await buildEntries(bundle: bundle, text: "")

        #expect(entries.isEmpty)
    }

    @Test
    func buildEntries_propagatesActivatorRelationships() async throws {
        // beta는 alpha에 의해 활성화되는 관계
        let alpha = makeTerm(key: "alpha", source: "Alpha", target: "알파")
        let beta = makeTerm(key: "beta", source: "Beta", target: "베타", activatedByKeys: ["alpha"])
        let bundle = JSBundle(terms: [alpha, beta], patterns: [])

        let entries = try await buildEntries(bundle: bundle, text: "Alpha Beta side by side")

        let alphaEntry = entries.first(where: { $0.source == "Alpha" })
        let betaEntry = entries.first(where: { $0.source == "Beta" })

        #expect(entries.count == 2)
        #expect(alphaEntry?.activatesKeys.contains("beta") == true)
        #expect(betaEntry?.activatorKeys.contains("alpha") == true)
    }

    @Test
    func buildEntries_composerKeepsNeedPairCheckFlag() async throws {
        let leftComp = JSComponent(pattern: "pair", role: "L", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let rightComp = JSComponent(pattern: "pair", role: "R", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)
        let pattern = JSPattern(
            name: "pair",
            left: JSTermSelector(role: "L", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            right: JSTermSelector(role: "R", tagsAll: nil, tagsAny: nil, includeTermKeys: nil, excludeTermKeys: nil),
            skipPairsIfSameTerm: true,
            sourceJoiners: [" "],
            sourceTemplates: ["{L}{J}{R}"],
            targetTemplates: ["{L} {R}"],
            isAppellation: false,
            preMask: true,
            displayName: "pair",
            roles: ["L", "R"],
            grouping: .optional,
            groupLabel: "그룹",
            defaultProhibitStandalone: true,
            defaultIsAppellation: false,
            defaultPreMask: true,
            needPairCheck: true
        )
        let bundle = JSBundle(
            terms: [
                makeTerm(key: "left", source: "Left", target: "왼쪽", components: [leftComp]),
                makeTerm(key: "right", source: "Right", target: "오른쪽", components: [rightComp])
            ],
            patterns: [pattern]
        )

        let entries = try await buildEntries(bundle: bundle, text: "Left Right should pair")

        let composed = entries.first(where: {
            if case let .composer(_, leftKey, rightKey, needPairCheck) = $0.origin {
                return leftKey == "left" && rightKey == "right" && needPairCheck
            }
            return false
        })

        #expect(composed != nil)
        #expect(composed?.target == "왼쪽 오른쪽")
    }

    @Test
    func buildEntries_scalesToLargeGlossary() async throws {
        let terms: [JSTerm] = (0..<200).map { i in
            makeTerm(key: "k\(i)", source: "t\(i)", target: "T\(i)")
        }
        let text = terms.map { $0.sources.first!.source }.joined(separator: " ")
        let bundle = JSBundle(terms: terms, patterns: [])

        let entries = try await buildEntries(bundle: bundle, text: text)

        #expect(entries.count == terms.count)
        let mapped = Dictionary(uniqueKeysWithValues: entries.map { ($0.source, $0.target) })
        #expect(mapped["t42"] == "T42")
        #expect(mapped["t199"] == "T199")
    }
}
