// File: DefaultTranslationRouter.swift
import Foundation

enum TranslationRouterError: Error {
    case noAvailableEngine
}

final class DefaultTranslationRouter: TranslationRouter {
    private let afm: TranslationEngine
    private let deepl: TranslationEngine
    private let google: TranslationEngine
    private let cache: CacheStore
    private let glossaryStore: GlossaryStore
    private let postEditor: PostEditor // 유지(호출 제거)
    private let comparer: ResultComparer? // 유지(호출 제거)
    private let reranker: Reranker? // 유지(호출 제거)

    // private lazy var fm: FMOrchestrator = .init(...)

    init(
        afm: TranslationEngine,
        deepl: TranslationEngine,
        google: TranslationEngine,
        cache: CacheStore,
        glossaryStore: GlossaryStore,
        postEditor: PostEditor,
        comparer: ResultComparer?,
        reranker: Reranker?
    ) {
        self.afm = afm
        self.deepl = deepl
        self.google = google
        self.cache = cache
        self.glossaryStore = glossaryStore
        self.postEditor = postEditor
        self.comparer = comparer
        self.reranker = reranker
    }

    public func translateStream(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary {
        let glossaryEntries: [GlossaryEntry]
        if options.applyGlossary {
            glossaryEntries = await MainActor.run { (try? glossaryStore.snapshot()) ?? [] }
        } else {
            glossaryEntries = []
        }

        let engineTag = preferredEngine.flatMap(EngineTag.init(rawValue:)) ?? .afm
        let engine = engine(for: engineTag)
        var succeededIDs: [String] = []
        var failedIDs: Set<String> = []
        var pendingSegments: [Segment] = []
        var cachedCount = 0
        var sequence = 0

        for segment in segments {
            try Task.checkCancellation()
            let key = cacheKey(for: segment, options: options, engine: engine.tag)
            if let hit = cache.lookup(key: key) {
                let payload = TranslationStreamPayload(
                    segmentID: segment.id,
                    originalText: segment.originalText,
                    translatedText: hit.text,
                    engineID: hit.engine.rawValue,
                    sequence: sequence
                )
                sequence += 1
                progress(.init(kind: .cachedHit, timestamp: Date()))
                progress(.init(kind: .final(segment: payload), timestamp: Date()))
                succeededIDs.append(segment.id)
                cachedCount += 1
            } else {
                pendingSegments.append(segment)
            }
        }

        if pendingSegments.isEmpty == false {
            progress(.init(kind: .requestScheduled, timestamp: Date()))

            let termMasker = TermMasker()
            let maskedResults = pendingSegments.map { segment in
                termMasker.maskWithLocks(segment: segment, glossary: glossaryEntries)
            }
            let maskedPacks = maskedResults.map { $0.pack }
            let maskedSegments = maskedPacks.map { item in
                Segment(
                    id: item.seg.id,
                    url: item.seg.url,
                    indexInPage: item.seg.indexInPage,
                    originalText: item.masked,
                    normalizedText: item.seg.normalizedText
                )
            }

            do {
                let engineResults = try await engine.translate(maskedSegments, options: options)
                for (index, result) in engineResults.enumerated() {
                    try Task.checkCancellation()
                    let pack = maskedPacks[index]
                    let personQueues = maskedResults[index].personQueues
                    let raw = result.text
                    let corrected = termMasker.fixParticlesAroundLocks(raw, locks: pack.locks)
                    let unmasked = termMasker.unlockTermsSafely(
                        corrected,
                        locks: pack.locks,
                        personQueues: personQueues
                    )
                    let hanCount = unmasked.unicodeScalars.filter { $0.properties.isIdeographic }.count
                    let residual = Double(hanCount) / Double(max(unmasked.count, 1))
                    let finalResult = TranslationResult(
                        id: result.id,
                        segmentID: result.segmentID,
                        engine: result.engine,
                        text: unmasked,
                        residualSourceRatio: residual,
                        createdAt: result.createdAt
                    )

                    let originalSegment = pendingSegments[index]
                    let payload = TranslationStreamPayload(
                        segmentID: originalSegment.id,
                        originalText: originalSegment.originalText,
                        translatedText: finalResult.text,
                        engineID: finalResult.engine.rawValue,
                        sequence: sequence
                    )
                    sequence += 1
                    progress(.init(kind: .partial(segment: payload), timestamp: Date()))
                    progress(.init(kind: .final(segment: payload), timestamp: Date()))
                    succeededIDs.append(originalSegment.id)

                    let cacheKey = cacheKey(for: pack.seg, options: options, engine: engine.tag)
                    cache.save(result: finalResult, forKey: cacheKey)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for segment in pendingSegments where failedIDs.contains(segment.id) == false {
                    failedIDs.insert(segment.id)
                    progress(.init(kind: .failed(segmentID: segment.id, error: .engineFailure(code: nil)), timestamp: Date()))
                }
                let summary = TranslationStreamSummary(
                    totalCount: segments.count,
                    succeededCount: succeededIDs.count,
                    failedCount: failedIDs.count,
                    cachedCount: cachedCount
                )
                progress(.init(kind: .completed, timestamp: Date()))
                return summary
            }
        }

        let summary = TranslationStreamSummary(
            totalCount: segments.count,
            succeededCount: succeededIDs.count,
            failedCount: failedIDs.count,
            cachedCount: cachedCount
        )
        progress(.init(kind: .completed, timestamp: Date()))
        return summary
    }

    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult] {
        let engine = engine(for: preferredEngine)
        return try await engine.translate(segments, options: options)
    }

    private func engine(for tag: EngineTag) -> TranslationEngine {
        switch tag {
        case .afm: return afm
        case .google: return google
        case .deepl: return deepl
        case .afmMask, .unknown: return afm
        }
    }

    func cacheKey(for segment: Segment, options: TranslationOptions, engine: EngineTag) -> String {
        "\(segment.id)|\(engine.rawValue)|pf=\(options.preserveFormatting)|style=\(options.style)|g=\(options.applyGlossary)"
    }
}
