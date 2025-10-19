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
        preferredEngine: EngineTag
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let glossaryEntries: [GlossaryEntry]
                    if options.applyGlossary {
                        glossaryEntries = await MainActor.run { (try? glossaryStore.snapshot()) ?? [] }
                    } else {
                        glossaryEntries = []
                    }

                    let engine = engine(for: preferredEngine)
                    continuation.yield(.segments(segments))

                    var pendingSegments: [Segment] = []
                    for segment in segments {
                        try Task.checkCancellation()
                        let key = cacheKey(for: segment, options: options, engine: engine.tag)
                        if let hit = cache.lookup(key: key) {
                            continuation.yield(.result(segment: segment, result: hit))
                        } else {
                            pendingSegments.append(segment)
                        }
                    }

                    if pendingSegments.isEmpty == false {
                        try Task.checkCancellation()
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

                        let engineResults = try await engine.translate(maskedSegments, options: options)
                        let finals: [TranslationResult] = engineResults.enumerated().map { index, result in
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
                            return TranslationResult(
                                id: result.id,
                                segmentID: result.segmentID,
                                engine: result.engine,
                                text: unmasked,
                                residualSourceRatio: residual,
                                createdAt: result.createdAt
                            )
                        }

                        for (index, result) in finals.enumerated() {
                            try Task.checkCancellation()
                            let originalSegment = pendingSegments[index]
                            continuation.yield(.result(segment: originalSegment, result: result))
                            let key = cacheKey(for: maskedPacks[index].seg, options: options, engine: engine.tag)
                            cache.save(result: result, forKey: key)
                        }
                    }

                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
