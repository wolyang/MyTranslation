import Foundation
import SwiftData
import Testing
@testable import MyTranslation

struct TranslationRouterTests {
    private func makeGlossaryService() throws -> Glossary.Service {
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
        return Glossary.Service(context: context)
    }

    private func makeRouter(
        afm: MockTranslationEngine? = nil,
        deepl: MockTranslationEngine? = nil,
        google: MockTranslationEngine? = nil,
        cache: MockCacheStore
    ) throws -> DefaultTranslationRouter {
        let glossary = try makeGlossaryService()
        let postEditor = StubPostEditor()
        return DefaultTranslationRouter(
            afm: afm ?? MockTranslationEngine(tag: .afm),
            deepl: deepl ?? MockTranslationEngine(tag: .deepl),
            google: google ?? MockTranslationEngine(tag: .google),
            cache: cache,
            glossaryService: glossary,
            postEditor: postEditor,
            comparer: nil,
            reranker: nil
        )
    }

    @Test
    func cacheHitReturnsCachedPayloadWithoutEngineCall() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)

        let segment = TestFixtures.sampleSegments[0]
        let cachedResult = TestFixtures.sampleTranslationResults[0]
        let key = router.cacheKey(for: segment, options: TestFixtures.defaultOptions, engine: .afm)
        cache.preload([key: cachedResult])

        var events: [TranslationStreamEvent.Kind] = []
        let summary = try await router.translateStream(
            runID: "run-cache-hit",
            segments: [segment],
            options: TestFixtures.defaultOptions,
            preferredEngine: nil
        ) { event in
            events.append(event.kind)
        }

        #expect(engine.translateCallCount == 0)
        #expect(cache.lookupCallCount == 1)
        #expect(summary.cachedCount == 1)
        #expect(summary.succeededCount == 1)
        #expect(events.contains { if case .cachedHit = $0 { return true } else { return false } })
        #expect(events.contains { if case .final = $0 { return true } else { return false } })
    }

    @Test
    func cacheMissCallsEngineAndSavesResult() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)

        let segment = TestFixtures.sampleSegments[0]
        let result = TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .afm, text: "translated")
        engine.streamedResults = [[result]]

        var events: [TranslationStreamEvent.Kind] = []
        let summary = try await router.translateStream(
            runID: "run-cache-miss",
            segments: [segment],
            options: TestFixtures.defaultOptions,
            preferredEngine: nil
        ) { event in
            events.append(event.kind)
        }

        #expect(engine.translateCallCount == 1)
        #expect(cache.saveCallCount == 1)
        #expect(summary.cachedCount == 0)
        #expect(summary.succeededCount == 1)
        #expect(events.contains { if case .requestScheduled = $0 { return true } else { return false } })
        #expect(events.contains { if case .final = $0 { return true } else { return false } })
    }

    @Test
    func preferredEngineSelectsGoogle() async throws {
        let afm = MockTranslationEngine(tag: .afm)
        let google = MockTranslationEngine(tag: .google)
        let cache = MockCacheStore()
        let glossary = try makeGlossaryService()
        let router = DefaultTranslationRouter(
            afm: afm,
            deepl: MockTranslationEngine(tag: .deepl),
            google: google,
            cache: cache,
            glossaryService: glossary,
            postEditor: StubPostEditor(),
            comparer: nil,
            reranker: nil
        )

        let segment = TestFixtures.sampleSegments[0]
        let result = TestFixtures.makeTranslationResult(segmentID: segment.id, engine: .google, text: "g-translated")
        google.streamedResults = [[result]]
        cache.shouldReturnNil = true

        _ = try await router.translateStream(
            runID: "run-google",
            segments: [segment],
            options: TestFixtures.defaultOptions,
            preferredEngine: EngineTag.google.rawValue
        ) { _ in }

        #expect(google.translateCallCount == 1)
        #expect(afm.translateCallCount == 0)
    }

    @Test
    func streamingEmitsPartialFinalAndCompletedInOrder() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)
        cache.shouldReturnNil = true

        let segments = Array(TestFixtures.sampleSegments.prefix(2))
        engine.streamedResults = [
            [TestFixtures.makeTranslationResult(segmentID: segments[0].id, engine: .afm, text: "t1")],
            [TestFixtures.makeTranslationResult(segmentID: segments[1].id, engine: .afm, text: "t2")]
        ]

        var events: [TranslationStreamEvent.Kind] = []
        let summary = try await router.translateStream(
            runID: "run-order",
            segments: segments,
            options: TestFixtures.defaultOptions,
            preferredEngine: nil
        ) { event in
            events.append(event.kind)
        }

        let partials = events.compactMap { if case let .partial(segment) = $0 { return segment } else { return nil } }
        let finals = events.compactMap { if case let .final(segment) = $0 { return segment } else { return nil } }

        #expect(summary.succeededCount == 2)
        #expect(events.contains { if case .requestScheduled = $0 { true } else { false } })
        #expect(events.contains { if case .completed = $0 { true } else { false } })
        #expect(partials.count == 2)
        #expect(finals.count == 2)
        #expect(partials.map { $0.segmentID } == segments.map { $0.id })
        #expect(finals.map { $0.segmentID } == segments.map { $0.id })
        if let lastPartial = partials.last, let firstFinal = finals.first {
            #expect(lastPartial.sequence < firstFinal.sequence)
        }
        if finals.count == 2 {
            #expect(finals[0].sequence < finals[1].sequence)
        }
    }

    @Test
    func engineErrorIsPropagatedWithoutSavingToCache() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        engine.configureTo(throwError: TranslationEngineError.emptySegments)
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)
        cache.shouldReturnNil = true

        var events: [TranslationStreamEvent.Kind] = []
        do {
            _ = try await router.translateStream(
                runID: "run-engine-error",
                segments: [TestFixtures.sampleSegments[0]],
                options: TestFixtures.defaultOptions,
                preferredEngine: nil
            ) { event in
                events.append(event.kind)
            }
            #expect(false, "엔진 오류가 전달되어야 합니다.")
        } catch {
            #expect(error is TranslationEngineError)
        }

        #expect(cache.saveCallCount == 0)
        #expect(events.contains { if case .final = $0 { true } else { false } } == false)
    }

    @Test
    func translateStreamPropagatesCancellation() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        engine.translationDelay = 1.0
        engine.resultsToReturn = [
            TestFixtures.makeTranslationResult(segmentID: TestFixtures.sampleSegments[0].id, engine: .afm, text: "slow")
        ]
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)
        cache.shouldReturnNil = true
        let runID = UUID().uuidString

        let task = Task {
            try await router.translateStream(
                runID: runID,
                segments: [TestFixtures.sampleSegments[0]],
                options: TestFixtures.defaultOptions,
                preferredEngine: nil
            ) { _ in }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        router.cancel(runID: runID)

        do {
            _ = try await task.value
            #expect(false == true, "취소 에러가 전달되어야 합니다.")
        } catch is CancellationError {
            #expect(true == true)
        } catch {
            #expect(false == true, "CancellationError가 전달되어야 합니다.")
        }
    }

    @Test
    func differentOptionsProduceDifferentCacheKeys() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        engine.resultsToReturn = [
            TestFixtures.makeTranslationResult(segmentID: TestFixtures.sampleSegments[0].id, engine: .afm, text: "v1")
        ]
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)

        let segment = TestFixtures.sampleSegments[0]
        let optionsA = TestFixtures.makeTranslationOptions(style: .neutralDictionaryTone, applyGlossary: true)
        let optionsB = TestFixtures.makeTranslationOptions(style: .colloquialKo, applyGlossary: false)

        _ = try await router.translateStream(
            runID: "run-opt-a",
            segments: [segment],
            options: optionsA,
            preferredEngine: nil
        ) { _ in }

        _ = try await router.translateStream(
            runID: "run-opt-b",
            segments: [segment],
            options: optionsB,
            preferredEngine: nil
        ) { _ in }

        let keyA = router.cacheKey(for: segment, options: optionsA, engine: engine.tag)
        let keyB = router.cacheKey(for: segment, options: optionsB, engine: engine.tag)

        #expect(keyA != keyB)
        #expect(engine.translateCallCount == 2)
        #expect(cache.saveCallCount == 2)
    }

    @Test
    func unexpectedSegmentIDMarksFailureAndThrowsRouterError() async throws {
        let engine = MockTranslationEngine(tag: .afm)
        engine.streamedResults = [
            [TestFixtures.makeTranslationResult(segmentID: "ghost", engine: .afm, text: "???")]
        ]
        let cache = MockCacheStore()
        let router = try makeRouter(afm: engine, cache: cache)
        cache.shouldReturnNil = true

        let segment = TestFixtures.sampleSegments[0]
        var events: [TranslationStreamEvent.Kind] = []
        do {
            _ = try await router.translateStream(
                runID: "run-unexpected",
                segments: [segment],
                options: TestFixtures.defaultOptions,
                preferredEngine: nil
            ) { event in
                events.append(event.kind)
            }
            #expect(false, "예상치 못한 세그먼트 ID에 대해 오류가 발생해야 합니다.")
        } catch {
            if case TranslationRouterError.noAvailableEngine = error {
                #expect(true)
            } else {
                #expect(false, "TranslationRouterError.noAvailableEngine가 전달되어야 합니다.")
            }
        }

        let failedIDs = events.compactMap { if case let .failed(segmentID, _) = $0 { return segmentID } else { return nil } }
        #expect(failedIDs == [segment.id])
        #expect(events.contains { if case .completed = $0 { true } else { false } })
        #expect(cache.saveCallCount == 0)
    }

    // MARK: - Stubs

    private struct StubPostEditor: PostEditor {
        func postEditBatch(texts: [String], style: TranslationStyle) async throws -> [String] { texts }
    }
}
