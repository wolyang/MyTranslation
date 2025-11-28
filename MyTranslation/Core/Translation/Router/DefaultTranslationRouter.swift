import Foundation

/// 오류 내비게이션을 위한 라우터 공용 에러 정의.
enum TranslationRouterError: Error {
    case noAvailableEngine
}

/// 스트리밍 중 수신 데이터와 관련된 에러 정의.
internal enum EngineStreamError: Error {
    case unexpectedID(String)
    case missingIDs(Set<String>)
}

/// 기본 번역 라우터 구현체. 각 엔진의 번역 결과를 모으고 후처리한다.
final class DefaultTranslationRouter: TranslationRouter {
    private let afm: TranslationEngine
    private let deepl: TranslationEngine
    private let google: TranslationEngine
    let cache: CacheStore
    let glossaryRepository: Glossary.Repository
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
        glossaryRepository: Glossary.Repository,
        postEditor: PostEditor,
        comparer: ResultComparer?,
        reranker: Reranker?
    ) {
        self.afm = afm
        self.deepl = deepl
        self.google = google
        self.cache = cache
        self.glossaryRepository = glossaryRepository
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
        return try await translateStreamInternal(
            runID: runID,
            segments: segments,
            options: options,
            preferredEngine: preferredEngine,
            preparedContext: nil,
            progress: progress
        )
    }

    /// 미리 생성된 마스킹 컨텍스트를 재사용할 수 있는 내부용 스트리밍 번역 엔트리.
    internal func translateStreamInternal(
        runID: String,
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        preparedContext: MaskingContext?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary {
        print("[Router] Start translateStream")
        let cancelBag = RouterCancellationCenter.shared.bag(for: runID)

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

        let glossaryData: GlossaryData?
        if preparedContext == nil {
            // 주의: 세그먼트 텍스트를 공백 없이 결합한다. 경계에서 드물게 오탐/미탐이 생길 수 있어 필요 시 별도 구분자를 도입한다.
            glossaryData = await fetchGlossaryData(
                fullText: segments.map { $0.originalText }.joined(),
                shouldApply: options.applyGlossary
            )
        } else {
            glossaryData = nil
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
            let maskingEngine = MaskingEngine()
            let normalizationEngine = NormalizationEngine()
            // 페이지 언어에 맞춰 토큰 주변 공백 삽입 정책을 적용한다.
            maskingEngine.tokenSpacingBehavior = options.tokenSpacingBehavior

            let maskingContext: MaskingContext
            if let preparedContext {
                maskingContext = preparedContext
            } else {
                maskingContext = await prepareMaskingContextInternal(
                    from: pendingSegments,
                    glossaryData: glossaryData,
                    termMasker: termMasker,
                    maskingEngine: maskingEngine,
                    normalizationEngine: normalizationEngine
                )
            }

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
                        engineTag: engine.tag,
                        maskedSegments: maskingContext.maskedSegments,
                        pendingSegments: pendingSegments,
                        indexByID: indexByID,
                        termMasker: termMasker,
                        normalizationEngine: normalizationEngine,
                        maskingEngine: maskingEngine,
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

    // MARK: - 취소

    public func cancel(runID: String) {
        RouterCancellationCenter.shared.cancel(runID: runID)
    }
}
