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
                await Task.yield()
                progress(.init(kind: .final(segment: payload), timestamp: Date()))
                await Task.yield()
                succeededIDs.append(segment.id)
                cachedCount += 1
            } else {
                pendingSegments.append(segment)
            }
        }

        if pendingSegments.isEmpty == false {
            progress(.init(kind: .requestScheduled, timestamp: Date()))
            await Task.yield()

            let termMasker = TermMasker()
            let maskedPacks = pendingSegments.map { segment in
                termMasker.maskWithLocks(segment: segment, glossary: glossaryEntries, maskPerson: engine.maskPerson)
            }
            let maskedSegments: [Segment] = maskedPacks.map { pack in
                Segment(
                    id: pack.seg.id,
                    url: pack.seg.url,
                    indexInPage: pack.seg.indexInPage,
                    originalText: pack.masked,
                    normalizedText: pack.seg.normalizedText,
                    domRange: pack.seg.domRange
                )
            }

            let nameGlossariesPerSegment: [[TermMasker.NameGlossary]] = {
                guard engine.maskPerson == false else {
                    return Array(repeating: [], count: maskedPacks.count)
                }
                return maskedPacks.map { pack in
                    termMasker.makeNameGlossaries(forOriginalText: pack.seg.originalText, entries: glossaryEntries)
                }
            }()

            let batchSize = 8
            var batchIndices: [Int] = []
            batchIndices.reserveCapacity(batchSize)

            func flushBatch() async throws -> TranslationStreamSummary? {
                guard batchIndices.isEmpty == false else { return nil }
                let requestSegments = batchIndices.map { maskedSegments[$0] }

                do {
                    let engineResults = try await engine.translate(requestSegments, options: options)
                    guard engineResults.count == batchIndices.count else {
                        struct EngineCountMismatch: Error {}
                        throw EngineCountMismatch()
                    }

                    for (resultIndex, result) in engineResults.enumerated() {
                        let globalIndex = batchIndices[resultIndex]
                        let pack = maskedPacks[globalIndex]
                        let originalSegment = pendingSegments[globalIndex]

                        var output = result.text
                        output = termMasker.normalizeEntitiesAndParticles(in: output, locksByToken: pack.locks, names: [], mode: .tokensOnly)
                        output = termMasker.unlockTermsSafely(
                            output,
                            locks: pack.locks
                        )
                        
                        if !engine.maskPerson {
                            let names = nameGlossariesPerSegment[globalIndex]
                            if names.isEmpty == false {
                                // 인물명에 마스킹을 하지 않았으므로 표기 정규화 필요
                                output = termMasker.normalizeEntitiesAndParticles(
                                    in: output,
                                    locksByToken: [:],
                                    names: names,
                                    mode: .namesOnly
                                )
                            }
                        }

                        if pack.locks.values.count == 1,
                           let target = pack.locks.values.first?.target
                        {
                            output = termMasker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(output, target: target)
                        }

                        let hanCount = output.unicodeScalars.filter { $0.properties.isIdeographic }.count
                        let residual = Double(hanCount) / Double(max(output.count, 1))
                        let finalResult = TranslationResult(
                            id: result.id,
                            segmentID: result.segmentID,
                            engine: result.engine,
                            text: output,
                            residualSourceRatio: residual,
                            createdAt: result.createdAt
                        )

                        let payload = TranslationStreamPayload(
                            segmentID: originalSegment.id,
                            originalText: originalSegment.originalText,
                            translatedText: finalResult.text,
                            engineID: finalResult.engine.rawValue,
                            sequence: sequence
                        )
                        sequence += 1
                        progress(.init(kind: .final(segment: payload), timestamp: Date()))
                        await Task.yield()
                        succeededIDs.append(originalSegment.id)

                        let cacheKey = cacheKey(for: pack.seg, options: options, engine: engine.tag)
                        cache.save(result: finalResult, forKey: cacheKey)
                    }

                    batchIndices.removeAll(keepingCapacity: true)
                    return nil
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let start = batchIndices.first ?? pendingSegments.count
                    for segment in pendingSegments[start...] where failedIDs.contains(segment.id) == false {
                        failedIDs.insert(segment.id)
                        progress(.init(kind: .failed(segmentID: segment.id, error: .engineFailure(code: nil)), timestamp: Date()))
                        await Task.yield()
                    }
                    let summary = TranslationStreamSummary(
                        totalCount: segments.count,
                        succeededCount: succeededIDs.count,
                        failedCount: failedIDs.count,
                        cachedCount: cachedCount
                    )
                    progress(.init(kind: .completed, timestamp: Date()))
                    await Task.yield()
                    return summary
                }
            }

            for index in maskedPacks.indices {
                try Task.checkCancellation()
                let originalSegment = pendingSegments[index]

                let scheduledPayload = TranslationStreamPayload(
                    segmentID: originalSegment.id,
                    originalText: originalSegment.originalText,
                    translatedText: nil,
                    engineID: engine.tag.rawValue,
                    sequence: sequence
                )
                sequence += 1
                progress(.init(kind: .partial(segment: scheduledPayload), timestamp: Date()))
                await Task.yield()

                batchIndices.append(index)
                if batchIndices.count == batchSize {
                    if let summary = try await flushBatch() {
                        return summary
                    }
                }
            }

            if let summary = try await flushBatch() {
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
        await Task.yield()
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
