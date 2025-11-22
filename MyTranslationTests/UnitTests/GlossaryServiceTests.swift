import SwiftData
import Testing
@testable import MyTranslation

/// Glossary.Service의 기본 동작을 검증한다.
struct GlossaryServiceTests {
    // MARK: - Helpers

    @MainActor
    private func makeService(importing bundle: JSBundle) throws -> Glossary.Service {
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

        return Glossary.Service(context: context)
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

        let service = try await makeService(importing: bundle)
        let entries = try await MainActor.run {
            try service.buildEntries(for: "hello there beta")
        }

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

        let service = try await makeService(importing: bundle)
        let entries = try await MainActor.run {
            try service.buildEntries(for: "Alpha Beta appear together")
        }

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
    func buildEntries_emptyInputReturnsEmpty() async throws {
        let bundle = JSBundle(
            terms: [makeTerm(key: "hello", source: "hello", target: "안녕")],
            patterns: []
        )
        let service = try await makeService(importing: bundle)

        let entries = try await MainActor.run {
            try service.buildEntries(for: "")
        }

        #expect(entries.isEmpty)
    }

    @Test
    func buildEntries_propagatesActivatorRelationships() async throws {
        // beta는 alpha에 의해 활성화되는 관계
        let alpha = makeTerm(key: "alpha", source: "Alpha", target: "알파")
        let beta = makeTerm(key: "beta", source: "Beta", target: "베타", activatedByKeys: ["alpha"])
        let bundle = JSBundle(terms: [alpha, beta], patterns: [])

        let service = try await makeService(importing: bundle)
        let entries = try await MainActor.run {
            try service.buildEntries(for: "Alpha Beta side by side")
        }

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

        let service = try await makeService(importing: bundle)
        let entries = try await MainActor.run {
            try service.buildEntries(for: "Left Right should pair")
        }

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

        let service = try await makeService(importing: bundle)
        let entries = try await MainActor.run {
            try service.buildEntries(for: text)
        }

        #expect(entries.count == terms.count)
        let mapped = Dictionary(uniqueKeysWithValues: entries.map { ($0.source, $0.target) })
        #expect(mapped["t42"] == "T42")
        #expect(mapped["t199"] == "T199")
    }
}
