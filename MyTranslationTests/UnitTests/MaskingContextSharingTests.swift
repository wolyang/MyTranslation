import Foundation
import Testing
@testable import MyTranslation

@Suite
struct MaskingContextSharingTests {
    private func makeRouter() throws -> DefaultTranslationRouter {
        let dataProvider = try TranslationRouterTests().makeGlossaryDataProvider()
        let cache = MockCacheStore()
        return DefaultTranslationRouter(
            afm: MockTranslationEngine(tag: .afm),
            deepl: MockTranslationEngine(tag: .deepl),
            google: MockTranslationEngine(tag: .google),
            cache: cache,
            glossaryDataProvider: dataProvider,
            glossaryComposer: GlossaryComposer(),
            postEditor: StubPostEditor(),
            comparer: nil,
            reranker: nil
        )
    }

    @Test
    func prepareMaskingContext_isEngineIndependent() async throws {
        let router = try makeRouter()
        let segment = TestFixtures.sampleSegments[0]
        let options = TestFixtures.defaultOptions

        let context = await router.prepareMaskingContext(
            segments: [segment],
            options: options
        )

        #expect(context?.maskedSegments.first?.id == segment.id)
        #expect(context?.maskedPacks.count == 1)
        #expect(context?.nameGlossoriesPerSegment.count == 1)
        #expect(context?.segmentPieces.count == 1)
    }

    @Test
    func translateStreamInternal_reusesPreparedContext() async throws {
        let router = try makeRouter()
        let segment = TestFixtures.sampleSegments[0]
        let options = TestFixtures.defaultOptions

        // prepare context once
        let prepared = await router.prepareMaskingContext(
            segments: [segment],
            options: options
        )

        // configure engines to emit distinct markers
        if let afm = router.value(forKey: "afm") as? MockTranslationEngine {
            afm.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .afm, text: "afm")]]
        }
        if let google = router.value(forKey: "google") as? MockTranslationEngine {
            google.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .google, text: "google")]]
        }
        if let deepl = router.value(forKey: "deepl") as? MockTranslationEngine {
            deepl.streamedResults = [[TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .deepl, text: "deepl")]]
        }

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
