// File: DefaultTranslationRouter.swift
import Foundation

/// 오류 내비게이션을 위한 라우터 공용 에러 정의.
enum TranslationRouterError: Error {
    case noAvailableEngine
}

/// 스트리밍 중 수신 데이터와 관련된 에러 정의.
private enum EngineStreamError: Error {
    case unexpectedID(String)
    case missingIDs(Set<String>)
}

/// 기본 번역 라우터 구현체. 각 엔진의 번역 결과를 모으고 후처리한다.
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

    /// 지정된 엔진과 스토어 구성 요소로 라우터를 초기화한다.
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

    /// 번역 스트림을 실행하고 이벤트를 순차적으로 방출한다.
    public func translateStream(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary {
        print("[Router] Start translateStream")

        let glossaryEntries = await fetchGlossaryEntries(shouldApply: options.applyGlossary)

        let engineTag = preferredEngine.flatMap(EngineTag.init(rawValue:)) ?? .afm
        let engine = engine(for: engineTag)
        var succeededIDs: [String] = []
        var failedIDs: Set<String> = []
        var pendingSegments: [Segment] = []
        var cachedCount = 0
        var sequence = 0

        for segment in segments {
            try Task.checkCancellation()
            if let cacheHit = cacheHitPayload(
                for: segment,
                options: options,
                engine: engine.tag,
                sequence: &sequence
            ) {
                progress(.init(kind: .cachedHit, timestamp: Date()))
                await Task.yield()
                progress(.init(kind: .final(segment: cacheHit), timestamp: Date()))
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
            let maskingContext = prepareMaskingContext(
                from: pendingSegments,
                glossaryEntries: glossaryEntries,
                engine: engine,
                termMasker: termMasker
            )

            for index in maskingContext.maskedPacks.indices {
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
            }

            let indexByID = Dictionary(uniqueKeysWithValues: pendingSegments.enumerated().map { ($1.id, $0) })
            var streamState = StreamProcessingState(
                remainingIDs: Set(pendingSegments.map { $0.id }),
                unexpectedIDs: [],
                succeededIDs: []
            )

            do {
                try await processStream(
                    engine: engine,
                    maskedSegments: maskingContext.maskedSegments,
                    pendingSegments: pendingSegments,
                    indexByID: indexByID,
                    termMasker: termMasker,
                    maskingContext: maskingContext,
                    options: options,
                    sequence: &sequence,
                    state: &streamState,
                    progress: progress
                )
                succeededIDs.append(contentsOf: streamState.succeededIDs)
            } catch is CancellationError {
                throw CancellationError()
            } catch let streamError as EngineStreamError {
                let failingIDs: Set<String>
                switch streamError {
                case .unexpectedID(let id):
                    print("[Router][ERR] unexpected result id=\(id)")
                    failingIDs = streamState.remainingIDs
                case .missingIDs(let ids):
                    print("[Router][ERR] missing ids=\(ids)")
                    failingIDs = ids
                }

                failedIDs = await markFailedSegments(
                    failingIDs,
                    existingFailed: failedIDs,
                    progress: progress
                )
                progress(.init(kind: .completed, timestamp: Date()))
                await Task.yield()
                throw TranslationRouterError.noAvailableEngine
            } catch {
                failedIDs = await markFailedSegments(
                    streamState.remainingIDs,
                    existingFailed: failedIDs,
                    progress: progress
                )
                progress(.init(kind: .completed, timestamp: Date()))
                await Task.yield()
                throw TranslationRouterError.noAvailableEngine
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

    /// 단건 번역 요청을 스트리밍 없이 수행한다.
    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult] {
        let engine = engine(for: preferredEngine)
        let stream = try await engine.translate(segments, options: options)
        var results: [TranslationResult] = []
        for try await batch in stream {
            results.append(contentsOf: batch)
        }
        return results
    }

    /// 엔진 태그에 해당하는 실제 엔진 인스턴스를 반환한다.
    private func engine(for tag: EngineTag) -> TranslationEngine {
        switch tag {
        case .afm: return afm
        case .google: return google
        case .deepl: return deepl
        case .afmMask, .unknown: return afm
        }
    }

    /// 캐시 식별을 위한 키를 생성한다.
    func cacheKey(for segment: Segment, options: TranslationOptions, engine: EngineTag) -> String {
        "\(segment.id)|\(engine.rawValue)|pf=\(options.preserveFormatting)|style=\(options.style)|g=\(options.applyGlossary)"
    }

    /// 용어집 사용 여부에 따라 최신 용어집 스냅샷을 가져온다.
    private func fetchGlossaryEntries(shouldApply: Bool) async -> [GlossaryEntry] {
        guard shouldApply else { return [] }
        return await MainActor.run { (try? glossaryStore.snapshot()) ?? [] }
    }

    /// 캐시 적중 시 최종 페이로드를 만들고, 적중하지 않으면 nil을 반환한다.
    private func cacheHitPayload(
        for segment: Segment,
        options: TranslationOptions,
        engine: EngineTag,
        sequence: inout Int
    ) -> TranslationStreamPayload? {
        let key = cacheKey(for: segment, options: options, engine: engine)
        guard let hit = cache.lookup(key: key) else { return nil }

        let payload = TranslationStreamPayload(
            segmentID: segment.id,
            originalText: segment.originalText,
            translatedText: hit.text,
            engineID: hit.engine.rawValue,
            sequence: sequence
        )
        sequence += 1
        return payload
    }

    /// 스트리밍 처리를 위해 마스킹된 세그먼트와 보조 정보를 구성한다.
    private func prepareMaskingContext(
        from segments: [Segment],
        glossaryEntries: [GlossaryEntry],
        engine: TranslationEngine,
        termMasker: TermMasker
    ) -> MaskingContext {
        let maskedPacks: [MaskedPack] = segments.map { segment in
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

        return MaskingContext(
            maskedSegments: maskedSegments,
            maskedPacks: maskedPacks,
            nameGlossariesPerSegment: nameGlossariesPerSegment,
            engineTag: engine.tag
        )
    }

    /// 엔진 스트림을 소비하며 최종 이벤트를 생성한다.
    private func processStream(
        engine: TranslationEngine,
        maskedSegments: [Segment],
        pendingSegments: [Segment],
        indexByID: [String: Int],
        termMasker: TermMasker,
        maskingContext: MaskingContext,
        options: TranslationOptions,
        sequence: inout Int,
        state: inout StreamProcessingState,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws {
        let stream = try await engine.translate(maskedSegments, options: options)

        for try await batch in stream {
            for result in batch {
                guard let index = indexByID[result.segmentID] else {
                    state.unexpectedIDs.insert(result.segmentID)
                    continue
                }
                guard state.remainingIDs.remove(result.segmentID) != nil else {
                    state.unexpectedIDs.insert(result.segmentID)
                    continue
                }

                let pack = maskingContext.maskedPacks[index]
                let originalSegment = pendingSegments[index]
                let output = restoreOutput(
                    from: result.text,
                    pack: pack,
                    termMasker: termMasker,
                    nameGlossaries: maskingContext.nameGlossariesPerSegment[index],
                    shouldNormalizeNames: !engine.maskPerson
                )

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
                state.succeededIDs.append(originalSegment.id)

                let cacheKey = cacheKey(for: pack.seg, options: options, engine: maskingContext.engineTag)
                cache.save(result: finalResult, forKey: cacheKey)
            }
        }

        if let unexpected = state.unexpectedIDs.first {
            throw EngineStreamError.unexpectedID(unexpected)
        }
        if state.remainingIDs.isEmpty == false {
            throw EngineStreamError.missingIDs(state.remainingIDs)
        }
    }

    /// 실패한 세그먼트에 대한 이벤트를 발행하고 실패 목록을 갱신한다.
    private func markFailedSegments(
        _ ids: Set<String>,
        existingFailed: Set<String>,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async -> Set<String> {
        var updated = existingFailed
        for segmentID in ids where updated.contains(segmentID) == false {
            updated.insert(segmentID)
            progress(.init(kind: .failed(segmentID: segmentID, error: .engineFailure(code: nil)), timestamp: Date()))
            await Task.yield()
        }
        return updated
    }

    /// 마스킹 해제 및 정규화를 수행해 최종 출력 문자열을 만든다.
    private func restoreOutput(
        from text: String,
        pack: MaskedPack,
        termMasker: TermMasker,
        nameGlossaries: [TermMasker.NameGlossary],
        shouldNormalizeNames: Bool
    ) -> String {
        var output = termMasker.normalizeEntitiesAndParticles(
            in: text,
            locksByToken: pack.locks,
            names: [],
            mode: .tokensOnly
        )
        output = termMasker.unlockTermsSafely(
            output,
            locks: pack.locks
        )

        if shouldNormalizeNames, nameGlossaries.isEmpty == false {
            // 인물명에 마스킹을 하지 않았으므로 표기 정규화 필요
            output = termMasker.normalizeEntitiesAndParticles(
                in: output,
                locksByToken: [:],
                names: nameGlossaries,
                mode: .namesOnly
            )
        }

        if pack.locks.values.count == 1,
           let target = pack.locks.values.first?.target
        {
            output = termMasker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(output, target: target)
        }

        return output
    }

    /// 마스킹 연산에 필요한 컨텍스트를 표현한다.
    private struct MaskingContext {
        let maskedSegments: [Segment]
        let maskedPacks: [MaskedPack]
        let nameGlossariesPerSegment: [[TermMasker.NameGlossary]]
        let engineTag: EngineTag
    }

    /// 스트림 진행 상황을 추적하기 위한 상태 값.
    private struct StreamProcessingState {
        var remainingIDs: Set<String>
        var unexpectedIDs: Set<String>
        var succeededIDs: [String]
    }
}
