// File: DefaultTranslationRouter.swift
import Combine
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
    private let glossaryService: Glossary.Service
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
        glossaryService: Glossary.Service,
        postEditor: PostEditor,
        comparer: ResultComparer?,
        reranker: Reranker?
    ) {
        self.afm = afm
        self.deepl = deepl
        self.google = google
        self.cache = cache
        self.glossaryService = glossaryService
        self.postEditor = postEditor
        self.comparer = comparer
        self.reranker = reranker
    }

    /// 번역 스트림을 실행하고 이벤트를 순차적으로 방출한다.
    public func translateStream(
        runID: String,
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary {
        print("[Router] Start translateStream")
        let cancelBag = RouterCancellationCenter.shared.bag(for: runID)

        let glossaryEntries = await fetchGlossaryEntries(fullText: segments.map({ $0.originalText
        }).joined(), shouldApply: options.applyGlossary)

        let engineTag = preferredEngine.flatMap(EngineTag.init(rawValue:)) ?? .afm
        let engine = engine(for: engineTag)
        print("[T] router.translateStream ENTER total=\(segments.count) engine=\(engine.tag.rawValue)")
        var succeededIDs: [String] = []
        var failedIDs: Set<String> = []
        var pendingSegments: [Segment] = []
        var cachedCount = 0
        var sequence = 0

        for segment in segments {
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

        let summary: TranslationStreamSummary = try await {
            // 아무 것도 번역할 것이 없으면 바로 요약 리턴
            guard !pendingSegments.isEmpty else {
                let s = TranslationStreamSummary(
                    totalCount: segments.count,
                    succeededCount: succeededIDs.count,
                    failedCount: failedIDs.count,
                    cachedCount: cachedCount
                )
                progress(.init(kind: .completed, timestamp: Date()))
                await Task.yield()
                print("[T] router.translateStream EXIT succeeded=\(succeededIDs.count) failed=\(failedIDs.count) cached=\(cachedCount) engine=\(engine.tag.rawValue)")
                return s
            }
            
            print(
                "[T] router.translateStream pending=\(pendingSegments.count) cached=\(cachedCount) engine=\(engine.tag.rawValue)"
            )
            progress(.init(kind: .requestScheduled, timestamp: Date()))
            await Task.yield()
            
            let termMasker = TermMasker()
            // 페이지 언어에 맞춰 토큰 주변 공백 삽입 정책을 적용한다.
            termMasker.tokenSpacingBehavior = options.tokenSpacingBehavior
            let maskingContext = prepareMaskingContext(
                from: pendingSegments,
                glossaryEntries: glossaryEntries,
                engine: engine,
                termMasker: termMasker
            )
            
            for index in maskingContext.maskedPacks.indices {
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
            
            try Task.checkCancellation()
            
            let indexByID = Dictionary(uniqueKeysWithValues: pendingSegments.enumerated().map { ($1.id, $0) })
            var streamState = StreamProcessingState(
                remainingIDs: Set(pendingSegments.map { $0.id }),
                unexpectedIDs: [],
                succeededIDs: []
            )
            
            let reader = Task { [engine] in
                do {
                    try Task.checkCancellation()
                    (sequence, streamState) = try await processStream(
                        runID: runID,
                        engine: engine,
                        maskedSegments: maskingContext.maskedSegments,
                        pendingSegments: pendingSegments,
                        indexByID: indexByID,
                        termMasker: termMasker,
                        maskingContext: maskingContext,
                        options: options,
                        sequence: sequence,
                        state: streamState,
                        progress: progress
                    )
                } catch {
                    throw error
                }
            }
            
            // 취소센터에 등록: router.cancel(runID:) -> reader.cancel()
            cancelBag.insert { reader.cancel() }
            
            do {
                try await reader.value
                succeededIDs.append(contentsOf: streamState.succeededIDs)
            } catch is CancellationError {
                // 취소는 상위로 그대로 던져서 뷰모델 defer에서 정리되도록
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
            }
            
            let s = TranslationStreamSummary(
                totalCount: segments.count,
                succeededCount: succeededIDs.count,
                failedCount: failedIDs.count,
                cachedCount: cachedCount
            )
            progress(.init(kind: .completed, timestamp: Date()))
            await Task.yield()
            print(
                "[T] router.translateStream EXIT succeeded=\(succeededIDs.count) failed=\(failedIDs.count) cached=\(cachedCount) engine=\(engine.tag.rawValue)"
            )
            return s
        }()
        
        RouterCancellationCenter.shared.remove(runID: runID)
        return summary
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
        let sourceComponent = options.sourceLanguage.resolved?.normalizedForCacheKey ?? "auto"
        let targetComponent = options.targetLanguage.normalizedForCacheKey
        return "\(segment.id)|\(engine.rawValue)|pf=\(options.preserveFormatting)|style=\(options.style)|g=\(options.applyGlossary)|src=\(sourceComponent)|tgt=\(targetComponent)"
    }

    /// 용어집 사용 여부에 따라 최신 용어집 스냅샷을 가져온다.
    private func fetchGlossaryEntries(fullText: String, shouldApply: Bool) async -> [GlossaryEntry] {
        guard shouldApply else { return [] }
        return await MainActor.run { (try? glossaryService.buildEntries(for: fullText)) ?? [] }
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
        var allSegmentPieces: [SegmentPieces] = []
        var maskedPacks: [MaskedPack] = []
        var nameGlossariesPerSegment: [[TermMasker.NameGlossary]] = []

        for segment in segments {
            let (pieces, _) = termMasker.buildSegmentPieces(
                segment: segment,
                glossary: glossaryEntries
            )
            allSegmentPieces.append(pieces)

            let pack = termMasker.maskFromPieces(
                pieces: pieces,
                segment: segment
            )
            maskedPacks.append(pack)

            let nameGlossaries = termMasker.makeNameGlossariesFromPieces(
                pieces: pieces,
                allEntries: glossaryEntries
            )
            nameGlossariesPerSegment.append(nameGlossaries)
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

        return MaskingContext(
            maskedSegments: maskedSegments,
            maskedPacks: maskedPacks,
            nameGlossariesPerSegment: nameGlossariesPerSegment,
            segmentPieces: allSegmentPieces,
            engineTag: engine.tag
        )
    }

    /// 엔진 스트림을 소비하며 최종 이벤트를 생성한다.
    private func processStream(
        runID: String,
        engine: TranslationEngine,
        maskedSegments: [Segment],
        pendingSegments: [Segment],
        indexByID: [String: Int],
        termMasker: TermMasker,
        maskingContext: MaskingContext,
        options: TranslationOptions,
        sequence: Int,
        state: StreamProcessingState,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> (newSequence: Int, newState: StreamProcessingState) {
        print(
            "[T] router.processStream ENTER masked=\(maskedSegments.count) engine=\(engine.tag.rawValue)"
        )
        
        var didLogFirstEmit = false
        
        var seq = sequence
        var st = state
        
        defer {
            print(
                "[T] router.processStream EXIT masked=\(maskedSegments.count) engine=\(engine.tag.rawValue) remaining=\(st.remainingIDs.count)"
            )
        }
        
        // 마스킹/원본 ID 일치 여부 체크 로그
        if maskedSegments.count == pendingSegments.count {
            for i in 0..<min(maskedSegments.count, 5) {
                if maskedSegments[i].id != pendingSegments[i].id {
                    print("[Router][WARN] masked vs pending ID mismatch at \(i): \(maskedSegments[i].id) vs \(pendingSegments[i].id)")
                }
            }
        } else {
            print("[Router][WARN] masked.count(\(maskedSegments.count)) != pending.count(\(pendingSegments.count))")
        }
            
        // 스트림 생성도 Task 안에서 수행 → 취소 신속 반응
        let stream = try await engine.translate(runID: runID, maskedSegments, options: options)
            
        var sawAnyBatch = false
        for try await batch in stream {
            if sawAnyBatch == false {
                    print("[T] router.processStream GOT-BATCH count=\(batch.count) engine=\(engine.tag.rawValue)")
                    sawAnyBatch = true
                }
            try Task.checkCancellation()
            for result in batch {
                try Task.checkCancellation()
                guard let index = indexByID[result.segmentID] else {
                    st.unexpectedIDs.insert(result.segmentID)
                    continue
                }
                guard st.remainingIDs.remove(result.segmentID) != nil else {
                    st.unexpectedIDs.insert(result.segmentID)
                    continue
                }
                    
                let pack = maskingContext.maskedPacks[index]
                let originalSegment = pendingSegments[index]
//                print("[T] router.processStream [\(result.segmentID)] ORIGINAL TEXT: \(originalSegment.originalText)")
                print("[T] router.processStream [\(result.segmentID)] MASKED TEXT: \(maskedSegments[index].originalText)")
                let output = restoreOutput(
                    from: result.text,
                    pack: pack,
                    termMasker: termMasker,
                    nameGlossaries: maskingContext.nameGlossariesPerSegment[index],
                    shouldNormalizeNames: true
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
                print("[T] router.processStream [\(result.segmentID)] FINAL RESULT: \(output)")
                    
                let payload = TranslationStreamPayload(
                    segmentID: originalSegment.id,
                    originalText: originalSegment.originalText,
                    translatedText: finalResult.text,
                    preNormalizedText: result.text,
                    engineID: finalResult.engine.rawValue,
                    sequence: seq
                )
                if didLogFirstEmit == false {
                    print("[T] router.processStream FIRST-EMIT seq=\(seq) seg=\(originalSegment.id) engine=\(engine.tag.rawValue)")

                    didLogFirstEmit = true
                }
                seq += 1
                progress(.init(kind: .final(segment: payload), timestamp: Date()))
                await Task.yield()
                    
                st.succeededIDs.append(originalSegment.id)
                    
                let cacheKey = cacheKey(for: pack.seg, options: options, engine: maskingContext.engineTag)
                cache.save(result: finalResult, forKey: cacheKey)
            }
        }
        if sawAnyBatch == false {
            print("[T][WARN] processStream: stream completed with 0 batches (no results)")
        }
        
        // 종료 검증
        if Task.isCancelled {
            throw CancellationError()
        }
        if let unexpected = st.unexpectedIDs.first {
            throw EngineStreamError.unexpectedID(unexpected)
        }
        if st.remainingIDs.isEmpty == false {
            throw EngineStreamError.missingIDs(st.remainingIDs)
        }
        
        return (seq, st)
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
        print("[T] router.processStream [\(pack.seg.id)] TRANSLATED ORITINAL RESULT: \(text)")
        var output = termMasker.normalizeDamagedETokens(text, locks: pack.locks)
//        print("[T] router.processStream [\(pack.seg.id)] NORMALIZED DAMAGED TOKENS RESULT: \(output)")
        
        output = termMasker.normalizeVariantsAndParticles(in: output, entries: nameGlossaries)
        output = termMasker.normalizeTokensAndParticles(in: output, locksByToken: pack.locks)
        
//        // 마스킹된 토큰을 언마스킹하고 조사를 보정한다.
//        output = termMasker.normalizeEntitiesAndParticles(
//            in: output,
//            locksByToken: pack.locks,
//            names: [],
//            mode: .tokensOnly
//        )
////        print("[T] router.processStream [\(pack.seg.id)] NORMALIZED ENTITIES AND PARTICLES RESULT: \(output)")
//        
//        output = termMasker.unlockTermsSafely(
//            output,
//            locks: pack.locks
//        )
////        print("[T] router.processStream [\(pack.seg.id)] UNLOCKED TERMS RESULT: \(output)")
//
//        if shouldNormalizeNames, nameGlossaries.isEmpty == false {
//            // 인물명에 마스킹을 하지 않았으므로 표기 정규화 필요
//            output = termMasker.normalizeEntitiesAndParticles(
//                in: output,
//                locksByToken: [:],
//                names: nameGlossaries,
//                mode: .namesOnly
//            )
////            print("[T] router.processStream [\(pack.seg.id)] NORMALIZED ENTITIES AND PARTICLES 2 RESULT: \(output)")
//        }

        if pack.locks.values.count == 1,
           let target = pack.locks.values.first?.target
        {
            output = termMasker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(output, target: target)
//            print("[T] router.processStream [\(pack.seg.id)] COLLAPSE SPACES RESULT: \(output)")
        }

        return output
    }

    /// 마스킹 연산에 필요한 컨텍스트를 표현한다.
    private struct MaskingContext {
        let maskedSegments: [Segment]
        let maskedPacks: [MaskedPack]
        let nameGlossariesPerSegment: [[TermMasker.NameGlossary]]
        let segmentPieces: [SegmentPieces]
        let engineTag: EngineTag
    }

    /// 스트림 진행 상황을 추적하기 위한 상태 값.
    private struct StreamProcessingState {
        var remainingIDs: Set<String>
        var unexpectedIDs: Set<String>
        var succeededIDs: [String]
    }
    
    // MARK: - 취소
    
    public func cancel(runID: String) {
        RouterCancellationCenter.shared.cancel(runID: runID)
    }
}
