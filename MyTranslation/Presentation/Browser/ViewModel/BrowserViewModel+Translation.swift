import Foundation
import NaturalLanguage
import WebKit

private func _id(_ id: UUID?) -> String { id?.uuidString ?? "nil" }
private func _url(_ url: URL?) -> String { url?.absoluteString ?? "nil" }

// 전체/부분 번역 스코프
enum TranslationScop: Sendable {
    case full
    case partial([Segment])
}

@MainActor
extension BrowserViewModel {
    /// 페이지 로딩이 끝났을 때 주소 표시줄과 번역 상태를 초기화한다.
    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        // 줌레벨 초기화
        normalizePageScale(webView)

        // 로딩된 url의 주소
        let prevEffectiveURL = currentPageURLString
        let curURLString = url.absoluteString
        settings.lastVisitedURL = curURLString
        let isNewPage = (prevEffectiveURL != curURLString)

        print("[T] didFinish url=\(curURLString) isNew=\(isNewPage) curPage(before)=\(prevEffectiveURL) act=\(_id(activeTranslationID))")

        // 주소창 업데이트
        request = nil
        if isEditingURL == false {
            // 현재 주소바를 편집중이 아니라면 바로 주소바의 url을 업데이트
            self.urlString = curURLString
        } else {
            // 현재 주소바를 편집중이라면 이동 없이 편집 종료되었을 때 복구할 주소바의 url을 예약
            pendingURLAfterEditing = curURLString
        }

        if currentPageTranslation?.url != url {
            currentPageTranslation = nil
            lastSegments = []
            lastStreamPayloads = []
            failedSegmentIDs = []
            translationProgress = 0
        }

        if isNewPage {
            languagePreference = languagePreference(for: url)
        }

        if !showOriginal {
            ensureTranslatedIfVisible(on: webView)
        }
    }
    
    
    
    @MainActor
    /// 캐시된 번역 적용, 필요시 전체/일부 번역 시작
    private func ensureTranslatedIfVisible(on webView: WKWebView) {
        // 원문 보기면 아무것도 하지 않음
        guard showOriginal == false else { return }

        // 진행 중이면 (같은 페이지) 추가로 건드리지 않음
        if let act = activeTranslationID, isTranslating {
            print("[T] ensureTranslatedIfVisible skip: in-flight act=\(act)")
            return
        }

        let engine = settings.preferredEngine
        let cache = applyCachedTranslationIfAvailable(for: engine, on: webView)
        print("[T] ensureTranslatedIfVisible path=\(cache.applied ? "applyCache" : "requestTranslation") remaining=\(cache.remainingSegmentIDs.count)")

        if cache.applied == false {
            // 캐시가 없으면 전체 번역 시작
            requestTranslation(on: webView)
        } else if cache.remainingSegmentIDs.isEmpty == false {
            // 일부만 남았으면 부분 번역
            requestTranslation(for: cache.remainingSegmentIDs, engine: engine, on: webView)
        }
    }

    /// 새로고침 버튼 동작에 맞춰 기존 번역을 지우고 Glossary부터 다시 로드하도록 설정한다.
    func refreshAndReload(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let segmentIDs = lastSegments.map { $0.id }

        if let webView = attachedWebView {
            cancelActiveTranslation()
            clearTranslationArtifacts(on: webView)
            if segmentIDs.isEmpty == false {
                cache.clearBySegmentIDs(segmentIDs)
            }
        } else if segmentIDs.isEmpty == false {
            cache.clearBySegmentIDs(segmentIDs)
        }

        load(urlString: trimmed)
    }

    /// 현재 페이지 전체를 번역하도록 비동기 작업을 시작한다.
    func requestTranslation(on webView: WKWebView) {
        print(
            "[T] requestTranslation(on:) ENTER isTranslating=\(isTranslating) url=\(_url(webView.url)) curPage=\(currentPageURLString) act=\(_id(activeTranslationID)) eng=\(settings.preferredEngine.rawValue)"
            )

        // 기존 번역 태스크 취소
        cancelActiveTranslation()
        
        let requestID = UUID()
        print(
            "[T] requestTranslation(on:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)"
        )
        activeTranslationID = requestID
        
        let bag = RouterCancellationCenter.shared.bag(for: requestID.uuidString)
        var task: Task<Void, Never>? = nil
        bag.insert { task?.cancel() }
        
        // 번역 태스크 생성
        task = Task { [weak self, weak webView] in
            guard let self, let webView else {
                self?.handleFailedTranslationStart(
                    reason: "webView released before translation",
                    requestID: requestID
                )
                return
            }
            
            // 새 페이지 여부
            let shouldWipe: Bool = {
                guard let cur = webView.url else { return true }
                return self.currentPageTranslation?.url != cur
            }()
            
            do {
                guard let prep = try await self.prepareTranslationSession(
                    scope: .full,
                    on: webView,
                    requestID: requestID,
                    engine: self.settings.preferredEngine,
                    wipeExisting: shouldWipe
                ) else { throw TranslationStreamError.prepareFailed }
                
                _ = try await self.runTranslationStream(
                    runID: requestID.uuidString,
                    requestID: requestID,
                    segments: prep.segments,
                    engineID: prep.engineID,
                    webView: webView
                )
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            } catch is CancellationError {
                print("[T] requestTranslation(on:) CancellationError")
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            } catch {
                print("[T] requestTranslation(on:) Error: \(error)")
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            }
        }
        translationTask = task
        print(
            "[T] requestTranslation(on:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID))"
        )
    }

    /// 지정된 세그먼트들만 재번역하도록 부분 번역 작업을 시작한다.
    func requestTranslation(
        for segmentIDs: [String],
        engine: EngineTag,
        on webView: WKWebView
    ) {
        print(
            "[T] requestTranslation(for:) ENTER segCount=\(segmentIDs.count) url=\(_url(webView.url)) curPage=\(currentPageURLString) act=\(_id(activeTranslationID)) eng=\(engine.rawValue)"
        )
        guard segmentIDs.isEmpty == false else { return }
        guard let url = webView.url,
              let state = currentPageTranslation,
              state.url == url else {
            requestTranslation(on: webView)
            return
        }

        let identifierSet = Set(segmentIDs)
        let segments = state.segments.filter { identifierSet.contains($0.id) }
        guard segments.isEmpty == false else { return }

        // 기존 번역 태스크 취소
        cancelActiveTranslation()
        
        let requestID = UUID()
        print(
            "[T] requestTranslation(for:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)"
        )
        activeTranslationID = requestID
        
        // runID 취소 연결 준비
        let bag = RouterCancellationCenter.shared.bag(for: requestID.uuidString)
        var task: Task<Void, Never>? = nil
        bag.insert { task?.cancel() }
        
        // 번역 태스크 생성
        task = Task { [weak self, weak webView] in
            guard let self, let webView else {
                self?.handleFailedTranslationStart(
                    reason: "webView released before partial translation",
                    requestID: requestID
                )
                return
            }
            
            do {
                guard let prep = try await self.prepareTranslationSession(
                    scope: .partial(segments),
                    on: webView,
                    requestID: requestID,
                    engine: engine,
                    wipeExisting: false
                ) else { throw TranslationStreamError.prepareFailed }
                print("[T] prepareTranslationSession SUCCEED reqID: \(requestID.uuidString)")
                _ = try await self.runTranslationStream(
                    runID: requestID.uuidString,
                    requestID: requestID,
                    segments: prep.segments,
                    engineID: prep.engineID,
                    webView: webView
                )
                print("[T] runTranslationStream SUCCEED reqID: \(requestID.uuidString)")
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            } catch is CancellationError {
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            } catch {
                await self.clearMT(on: webView)
                await self.finalizeTranslationSessionIfCurrent(requestID, webView: webView)
            }
        }
        translationTask = task
        print(
            "[T] requestTranslation(for:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID))"
        )
    }

    /// 원문 보기 토글에 맞춰 번역 적용 또는 취소 흐름을 제어한다.
    func onShowOriginalChanged(_ showOriginal: Bool) {
        guard let webView = attachedWebView else { return }
        print("[T] onShowOriginalChanged showOriginal=\(showOriginal) url=\(_url(webView.url)) act=\(_id(activeTranslationID))")

        let executor = WKWebViewScriptAdapter(webView: webView)
        if showOriginal {
            cancelActiveTranslation()
            replacer.restore(using: executor)
            closeOverlay()
            return
        }

        // 번역 모드면 공통 헬퍼만 호출
        ensureTranslatedIfVisible(on: webView)
    }

    /// 페이지 이동 전에 번역 상태와 하이라이트를 정리한다.
    func willNavigate() {
        guard let webView = attachedWebView else { return }
        print(
            "[T] willNavigate url=\(_url(webView.url)) act=\(_id(activeTranslationID))"
        )
        if let url = currentPageTranslation?.url {
            persistLanguagePreference(for: url)
        }
        cancelActiveTranslation()
        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
        }
        request = nil
        noBodyTextRetryCount = 0
        closeOverlay()
        pendingURLAfterEditing = nil
        currentPageTranslation = nil
        lastSegments = []
        lastStreamPayloads = []
        failedSegmentIDs = []
        translationProgress = 0
    }

    /// 번역 엔진 변경 시 캐시 재적용 여부를 판단하고 필요한 번역을 재요청한다.
    func onEngineSelected(_ engine: EngineTag, wasShowingOriginal: Bool) {
        settings.preferredEngine = engine
        guard let webView = attachedWebView else { return }
        cancelActiveTranslation()
        if wasShowingOriginal { return }
        let cacheResult = applyCachedTranslationIfAvailable(for: engine, on: webView)
        if cacheResult.applied == false {
            requestTranslation(on: webView)
        } else if cacheResult.remainingSegmentIDs.isEmpty == false {
            requestTranslation(for: cacheResult.remainingSegmentIDs, engine: engine, on: webView)
        }
    }
    
    /// 번역 완료·실패 수치를 기반으로 진행률을 계산한다.
    func updateProgress(for engineID: TranslationEngineID) {
        guard let state = currentPageTranslation else {
            translationProgress = 0
            return
        }
        if state.totalSegments == 0 {
            translationProgress = 1.0
            return
        }
        let total = state.totalSegments
        let finalized = state.finalizedSegmentIDs.count
        let failed = state.failedSegmentIDs.count
        translationProgress = Double(min(finalized + failed, total)) / Double(total)
    }
}

private extension TranslationStreamEvent.Kind {
    var name: String {
        switch self {
        case .cachedHit: return "cachedHit"
        case .requestScheduled: return "requestScheduled"
        case .partial: return "partial"
        case .final: return "final"
        case .failed: return "failed"
        case .completed: return "completed"
        }
    }
}

@MainActor
private extension BrowserViewModel {
    /// 진행 중인 번역 Task 를 중단하고 관련 상태를 초기화한다.
    func cancelActiveTranslation() {
        print(
            "[T] cancelActiveTranslation act(before)=\(_id(activeTranslationID))"
        )
        if let activeTranslationID {
            RouterCancellationCenter.shared.cancel(runID: activeTranslationID.uuidString)
            RouterCancellationCenter.shared.remove(runID: activeTranslationID.uuidString)
        }
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
        
//        if let webView = attachedWebView {
//            normalizePageScale(webView)
//        }
    }

    /// 번역 Task 생성이 실패했을 때 상태를 정리하고 원인을 로깅한다.
    func handleFailedTranslationStart(reason: String, requestID: UUID) {
        print(
            "[T] handleFailedTranslationStart reason=\(reason) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) "
        )
        if activeTranslationID == requestID {
            cancelActiveTranslation()
        }
        print("[BrowserViewModel] Failed to start translation: \(reason)")
    }
    
    /// 세션 준비(세그먼트, 상태 세팅 / 표시 초기화)
    @MainActor
    private func prepareTranslationSession(
        scope: TranslationScop,
        on webView: WKWebView,
        requestID: UUID,
        engine: EngineTag,
        wipeExisting: Bool
    ) async throws -> PreparedState? {
        print("[T] prepareTranslationSession START reqID: \(requestID.uuidString)")
        guard let url = webView.url, activeTranslationID == requestID else {
            print("[T] prepareTranslationSession SYNC FAIL: url: \(webView.url), activeTranslationID: \(activeTranslationID?.uuidString)")
            return nil
        }
        
        closeOverlay()
        isTranslating = true
        
        let executor = WKWebViewScriptAdapter(webView: webView)
        let engineID = engine.rawValue
        
        switch scope {
        case .full:
            // URL 일치 + 세그먼트 보유 시 재사용, 아니면 추출
            let segments: [Segment]
            if let state = currentPageTranslation,
               state.url == url,
               !state.segments.isEmpty {
                segments = state.segments
            } else {
                segments = try await extractor.extract(using: executor, url: url)
            }
            noBodyTextRetryCount = 0
            
            // 상태 초기화
            if case .auto(let detected) = languagePreference.source, detected == nil {
                if let detectedLanguage = detectSourceLanguage(in: segments) {
                    updateSourceLanguage(.auto(detected: detectedLanguage), triggeredByUser: false)
                }
            }

            var state = currentPageTranslation ?? PageTranslationState(url: url, segments: [], languagePreference: languagePreference)
            state.url = url
            state.segments = segments
            state.totalSegments = segments.count
            state.languagePreference = languagePreference
            state.buffersByEngine[engineID] = state.buffersByEngine[engineID] ?? .init()
            state.lastEngineID = engineID
            state.failedSegmentIDs.removeAll()
            state.finalizedSegmentIDs.removeAll()
            state.scheduledSegmentIDs.removeAll()
            state.summary = nil
            currentPageTranslation = state

            lastSegments = segments
            lastStreamPayloads = []
            translationProgress = segments.isEmpty ? 1.0 : 0.0
            failedSegmentIDs = []
            
            if wipeExisting {
                replacer.restore(using: executor)
                replacer.setPairs([], using: executor, observer: .restart)
            }
            
            if let c = webView.navigationDelegate as? WebContainerView.Coordinator {
                c.resetMarks()
                await c.markSegments(segments)
            }
            
            return .init(url: url, engineID: engineID, segments: segments)
        case .partial(let presetSegments):
            // 부분 번역은 현재 페이지 상태가 같은 URL일 때만 진행. 아니면 중단.
            guard var state = currentPageTranslation, state.url == url else {
                return nil
            }
            state.buffersByEngine[engineID] = state.buffersByEngine[engineID] ?? .init()
            state.lastEngineID = engineID
            state.failedSegmentIDs.removeAll()
            state.scheduledSegmentIDs.removeAll()
            state.languagePreference = languagePreference
            currentPageTranslation = state
            failedSegmentIDs = state.failedSegmentIDs
            updateProgress(for: engineID)
            
            if wipeExisting {
                replacer.restore(using: executor)
                replacer.setPairs([], using: executor, observer: .restart)
            }
            
            if let c = webView.navigationDelegate as? WebContainerView.Coordinator {
                c.resetMarks()
                await c.markSegments(state.segments)
            }
            
            return .init(url: url, engineID: engineID, segments: presetSegments)
        }
    }
    
    // 번역 스트림 실행
    @MainActor
    func runTranslationStream(
        runID: String,
        requestID: UUID,
        segments: [Segment],
        engineID: TranslationEngineID,
        webView: WKWebView
    ) async throws -> TranslationStreamSummary {
        print("[T] runTranslationStream START reqID: \(requestID.uuidString)")
        let preference = currentPageTranslation?.languagePreference ?? languagePreference
        let options = makeTranslationOptions(using: preference)
        let summary = try await router.translateStream(
            runID: runID,
            segments: segments,
            options: options,
            preferredEngine: engineID
        ) { [weak self, weak webView] event in
            Task { @MainActor in
                guard let self, let webView, let url = webView.url else { return }
                if self.activeTranslationID != requestID { return }
                await self.handleStreamEvent(
                    event,
                    url: url,
                    executor: WKWebViewScriptAdapter(webView: webView),
                    requestID: requestID
                )
            }
        }
        
        // summary 반영
        if var updatedState = currentPageTranslation, updatedState.url == webView.url {
            updatedState.summary = summary
            currentPageTranslation = updatedState
            failedSegmentIDs = updatedState.failedSegmentIDs
            updateProgress(for: engineID)
        }
        return summary
    }

    /// 번역 스트림 이벤트를 분기 처리해 상태와 UI를 최신으로 유지한다.
    func handleStreamEvent(
        _ event: TranslationStreamEvent,
        url: URL,
        executor: WebViewScriptExecutor,
        requestID: UUID
    ) async {
        if activeTranslationID != requestID {
            print(
                "[T] handleStreamEvent DROP reason=activeID-mismatch req=\(requestID.uuidString) act=\(_id(activeTranslationID))"
            )
            return
        }

        switch event.kind {
        case .cachedHit:
            break
        case .requestScheduled:
            break
        case let .partial(segment):
            await applyStreamPayload(
                segment,
                engineID: segment.engineID,
                isFinal: false,
                executor: executor,
                highlight: false,
                url: url
            )
        case let .final(segment):
            await applyStreamPayload(
                segment,
                engineID: segment.engineID,
                isFinal: true,
                executor: executor,
                highlight: false,
                url: url
            )
        case let .failed(segmentID, _):
            if var state = currentPageTranslation, state.url == url {
                state.failedSegmentIDs.insert(segmentID)
                state.finalizedSegmentIDs.remove(segmentID)
                state.scheduledSegmentIDs.remove(segmentID)
                currentPageTranslation = state
                failedSegmentIDs = state.failedSegmentIDs
                let engineID = state.lastEngineID ?? settings.preferredEngine.rawValue
                updateProgress(for: engineID)
            }
        case .completed:
            break
        }
    }
    
    /// MT 하이라이트/치환 흔적 정리
    @MainActor
    private func clearMT(on webView: WKWebView) async {
        let ex = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: ex)
        _ = try? await ex.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
    }

    private func detectSourceLanguage(in segments: [Segment]) -> AppLanguage? {
        guard segments.isEmpty == false else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = []

        let samples = segments.prefix(40).map { $0.originalText }.filter { !$0.isEmpty }
        guard samples.isEmpty == false else { return nil }

        for text in samples {
            recognizer.processString(text)
        }

        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let confidence = hypotheses[dominant], confidence >= 0.2 else { return nil }
        return AppLanguage(code: dominant.rawValue)
    }

    /// 스트림으로 전달된 번역 결과를 캐시에 반영하고 웹뷰에 적용한다.
    func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engineID: TranslationEngineID,
        isFinal: Bool,
        executor: WebViewScriptExecutor,
        highlight: Bool,
        url: URL
    ) async {
        guard var state = currentPageTranslation, state.url == url else {
            print(
                "[T] applyStreamPayload DROP reason=url-mismatch seg=\(payload.segmentID) act=\(_id(activeTranslationID)) webUrl=\(_url(attachedWebView?.url)) snapUrl=\(_url(url)) state.url=\(_url(currentPageTranslation?.url))"
            )
            return
        }
        var buffer = state.buffersByEngine[engineID] ?? .init()
        buffer.upsert(payload)
        state.buffersByEngine[engineID] = buffer
        state.lastEngineID = engineID
        state.scheduledSegmentIDs.insert(payload.segmentID)
        if isFinal {
            state.finalizedSegmentIDs.insert(payload.segmentID)
            state.failedSegmentIDs.remove(payload.segmentID)
            state.scheduledSegmentIDs.remove(payload.segmentID)
        }
        currentPageTranslation = state

        lastStreamPayloads = buffer.ordered
        failedSegmentIDs = state.failedSegmentIDs
        updateProgress(for: engineID)

        guard let translated = payload.translatedText, translated.isEmpty == false else { return }
        let enrichedPayload = TranslationStreamPayload(
            segmentID: payload.segmentID,
            originalText: payload.originalText,
            translatedText: translated,
            preNormalizedText: payload.preNormalizedText,
            engineID: payload.engineID,
            sequence: payload.sequence,
            highlightMetadata: payload.highlightMetadata
        )
        replacer.upsert(
            payload: enrichedPayload,
            using: executor,
            applyImmediately: true,
            highlight: highlight
        )
    }
    
    /// 세션 종료 처리 - 현재 req에 대해 종료/정리(진행중 플래그 해제 등)
    @MainActor
    private func finalizeTranslationSessionIfCurrent(_ requestID: UUID, webView: WKWebView) async {
        print("[T] finalizeTranslationSessionIfCurrent reqID: \(requestID.uuidString)")
        guard activeTranslationID == requestID else { return }
        normalizePageScale(webView)
        isTranslating = false
        translationTask = nil
        activeTranslationID = nil
    }

    /// 번역 적용 여부와 상관없이 페이지 확대 비율을 초기화한다.
    func normalizePageScale(_ webView: WKWebView) {
        if webView.responds(to: #selector(getter: WKWebView.pageZoom)) {
            webView.pageZoom = 1.0
        }
        webView.scrollView.setZoomScale(1.0, animated: false)
    }

    /// 캐시에 저장된 번역을 재적용하고 남은 세그먼트 목록을 반환한다.
    @discardableResult
    func applyCachedTranslationIfAvailable(for engine: EngineTag, on webView: WKWebView) -> CacheApplyResult {
        guard let url = webView.url,
              let state = currentPageTranslation,
              state.url == url else {
            return CacheApplyResult(applied: false, remainingSegmentIDs: [])
        }

        let engineBuffer = state.buffersByEngine[engine.rawValue]
        let remainingSegmentIDs = state.segments
            .filter { segment in
                guard let buffer = engineBuffer else { return true }
                return buffer.segmentIDs.contains(segment.id) == false
            }
            .map { $0.id }

        guard let buffer = engineBuffer, buffer.ordered.isEmpty == false else {
            return CacheApplyResult(applied: false, remainingSegmentIDs: remainingSegmentIDs)
        }

        let executor = WKWebViewScriptAdapter(webView: webView)
        let payloads = buffer.ordered.compactMap { payload -> TranslationStreamPayload? in
            guard let text = payload.translatedText, text.isEmpty == false else { return nil }
            return TranslationStreamPayload(
                segmentID: payload.segmentID,
                originalText: payload.originalText,
                translatedText: text,
                preNormalizedText: payload.preNormalizedText,
                engineID: payload.engineID,
                sequence: payload.sequence
            )
        }
        replacer.setPairs(payloads, using: executor, observer: .restart)
        replacer.apply(using: executor, observe: true)
        lastSegments = state.segments
        lastStreamPayloads = buffer.ordered
        var updatedState = state
        updatedState.finalizedSegmentIDs = buffer.segmentIDs
        updatedState.failedSegmentIDs.removeAll()
        updatedState.scheduledSegmentIDs.removeAll()
        updatedState.lastEngineID = engine.rawValue
        currentPageTranslation = updatedState
        failedSegmentIDs = updatedState.failedSegmentIDs
        updateProgress(for: engine.rawValue)

        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
            Task { @MainActor in
                await coordinator.markSegments(state.segments)
            }
        }

        return CacheApplyResult(applied: true, remainingSegmentIDs: remainingSegmentIDs)
    }
}

extension BrowserViewModel {
    /// 페이지별 언어 선호를 기반으로 엔진 호출 옵션을 조립한다.
    func makeTranslationOptions(using preference: PageLanguagePreference) -> TranslationOptions {
        return TranslationOptions(
            preserveFormatting: true,
            style: .neutralDictionaryTone,
            applyGlossary: true,
            sourceLanguage: preference.source,
            targetLanguage: preference.target,
            tokenSpacingBehavior: spacingBehavior(for: preference)
        )
    }

    /// 대상 언어가 CJK인지에 따라 토큰 간 공백 삽입 여부를 결정한다.
    private func spacingBehavior(for preference: PageLanguagePreference) -> TokenSpacingBehavior {
        preference.target.isCJK ? .disabled : .isolatedSegments
    }

    func clearTranslationArtifacts(on webView: WKWebView) {
        let executor = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: executor)
        replacer.setPairs([], using: executor, observer: .restart)
        closeOverlay()

        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
        }

        currentPageTranslation = nil
        lastSegments = []
        lastStreamPayloads = []
        failedSegmentIDs = []
        translationProgress = 0
        noBodyTextRetryCount = 0
        isTranslating = false
    }

    private struct PreparedState: Sendable {
        let url: URL
        let engineID: TranslationEngineID
        let segments: [Segment]
    }
    
    enum TranslationStreamError: Error {
        case prepareFailed, missingRequired
    }
}
