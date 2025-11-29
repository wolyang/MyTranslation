import Foundation
import SwiftData
import Testing
@testable import MyTranslation

@Suite
struct MaskingContextSharingTests {
    private func makeGlossaryDataProvider() throws -> Glossary.DataProvider {
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
        return Glossary.DataProvider(context: context)
    }

    private func makeRouter() throws -> (router: DefaultTranslationRouter, afm: MockTranslationEngine, google: MockTranslationEngine, deepl: MockTranslationEngine) {
        let dataProvider = try makeGlossaryDataProvider()
        let cache = MockCacheStore()
        let afm = MockTranslationEngine(tag: .afm)
        let google = MockTranslationEngine(tag: .google)
        let deepl = MockTranslationEngine(tag: .deepl)
        let router = DefaultTranslationRouter(
            afm: afm,
            deepl: deepl,
            google: google,
            cache: cache,
            glossaryRepository: dataProvider,
            postEditor: StubPostEditor(),
            comparer: nil,
            reranker: nil
        )
        return (router, afm, google, deepl)
    }

    @Test
    func prepareMaskingContext_isEngineIndependent() async throws {
        let (router, _, _, _) = try makeRouter()
        let segment = TestFixtures.sampleSegments[0]
        let options = TestFixtures.defaultOptions

        let context = await router.prepareMaskingContext(
            segments: [segment],
            options: options
        )

        #expect(context?.maskedSegments.first?.id == segment.id)
        #expect(context?.maskedPacks.count == 1)
        #expect(context?.nameGlossariesPerSegment.count == 1)
        #expect(context?.segmentPieces.count == 1)
    }

    @Test
    func translateStreamInternal_reusesPreparedContext() async throws {
        let (router, afm, google, deepl) = try makeRouter()
        let segment = TestFixtures.sampleSegments[0]
        let options = TestFixtures.defaultOptions

        // prepare context once
        let prepared = await router.prepareMaskingContext(
            segments: [segment],
            options: options
        )

        // configure engines to emit distinct markers
        afm.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .afm, text: "afm")]]
        google.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .google, text: "google")]]
        deepl.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .deepl, text: "deepl")]]

        let engines: [EngineTag] = [.afm, .google, .deepl]
        var succeeded: [EngineTag] = []

        for engine in engines {
            _ = try await router.translateStreamInternal(
                runID: "run-\(engine.rawValue)",
                segments: [segment],
                options: options,
                preferredEngine: engine.rawValue,
                preparedContext: prepared,
                progress: { _ in }
            )
            succeeded.append(engine)
        }

        #expect(succeeded == engines)
    }
}

private struct StubPostEditor: PostEditor {
    func postEditBatch(texts: [String], style: TranslationStyle) async throws -> [String] { texts }
}
