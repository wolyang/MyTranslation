import Foundation
import WebKit

@MainActor
extension BrowserViewModel {
    /// 페이지 로딩이 끝났을 때 주소 표시줄과 번역 상태를 초기화한다.
    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        normalizePageScale(webView)

        let urlString = url.absoluteString
        let isNewPage = currentPageURLString != urlString

        request = nil
        pendingURLAfterEditing = urlString
        if isEditingURL == false {
            self.urlString = urlString
            pendingURLAfterEditing = nil
        }

        if currentPageTranslation?.url != url {
            currentPageTranslation = nil
        }

        if isNewPage {
            // 주소창 이동이나 히스토리 내비게이션처럼 onNavigate 콜백이 생략된 경우에도
            // 새 페이지로 판별되면 자동 번역 시도 여부를 초기화한다.
            hasAttemptedTranslationForCurrentPage = false
            noBodyTextRetryCount = 0
            pendingAutoTranslateID = nil
        }

        currentPageURLString = urlString

        if hasAttemptedTranslationForCurrentPage == false {
            scheduleAutoTranslate()
        }
    }

    /// 현재 페이지 전체를 번역하도록 비동기 작업을 예약한다.
    func requestTranslation(on webView: WKWebView) {
        translationTask?.cancel()
        translationTask = nil
        pendingAutoTranslateID = nil
        let requestID = UUID()
        activeTranslationID = requestID
        hasAttemptedTranslationForCurrentPage = true
        translationTask = Task.detached(priority: .userInitiated) { [weak self, weak webView] in
            guard let webView else {
                await MainActor.run {
                    self?.handleFailedTranslationStart(
                        reason: "webView released before translation",
                        requestID: requestID
                    )
                }
                return
            }
            guard let strongSelf = await MainActor.run(body: { self }) else { return }
            await strongSelf.startTranslate(on: webView, requestID: requestID)
        }
    }

    /// 지정된 세그먼트들만 재번역하도록 부분 번역 작업을 예약한다.
    func requestTranslation(
        for segmentIDs: [String],
        engine: EngineTag,
        on webView: WKWebView
    ) {
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

        translationTask?.cancel()
        translationTask = nil
        pendingAutoTranslateID = nil
        let requestID = UUID()
        activeTranslationID = requestID
        hasAttemptedTranslationForCurrentPage = true
        translationTask = Task.detached(priority: .userInitiated) { [weak self, weak webView] in
            guard let webView else {
                await MainActor.run {
                    self?.handleFailedTranslationStart(
                        reason: "webView released before partial translation",
                        requestID: requestID
                    )
                }
                return
            }
            guard let strongSelf = await MainActor.run(body: { self }) else { return }
            await strongSelf.startPartialTranslation(
                segments: segments,
                engine: engine,
                on: webView,
                requestID: requestID
            )
        }
    }

    /// 원문 보기 토글에 맞춰 번역 적용 또는 취소 흐름을 제어한다.
    func onShowOriginalChanged(_ showOriginal: Bool) {
        guard let webView = attachedWebView else { return }
        let executor = WKWebViewScriptAdapter(webView: webView)
        if showOriginal {
            cancelActiveTranslation()
            replacer.restore(using: executor)
            closeOverlay()
        } else {
            let engine = settings.preferredEngine
            let cacheResult = applyCachedTranslationIfAvailable(for: engine, on: webView)
            if cacheResult.applied == false {
                requestTranslation(on: webView)
            } else if cacheResult.remainingSegmentIDs.isEmpty == false {
                requestTranslation(for: cacheResult.remainingSegmentIDs, engine: engine, on: webView)
            }
        }
    }

    /// 페이지 이동 직전에 번역 상태와 하이라이트를 정리한다.
    func willNavigate() {
        guard let webView = attachedWebView else { return }
        cancelActiveTranslation()
        let executor = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: executor)
        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
        }
        request = nil
        hasAttemptedTranslationForCurrentPage = false
        autoTranslateTask?.cancel()
        autoTranslateTask = nil
        pendingAutoTranslateID = nil
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

@MainActor
private extension BrowserViewModel {
    /// 진행 중인 번역 Task 를 중단하고 관련 상태를 초기화한다.
    func cancelActiveTranslation() {
        translationTask?.cancel()
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
        if let webView = attachedWebView {
            normalizePageScale(webView)
        }
    }

    func clearAutoTranslateRequest(for token: UUID) {
        if pendingAutoTranslateID == token {
            pendingAutoTranslateID = nil
            if autoTranslateTask?.isCancelled ?? true {
                autoTranslateTask = nil
            }
        }
    }

    func runAutoTranslateIfNeeded(targetURL: String, token: UUID) async {
        guard pendingAutoTranslateID == token else {
            if pendingAutoTranslateID == nil {
                autoTranslateTask = nil
            }
            return
        }
        defer {
            if pendingAutoTranslateID == token {
                pendingAutoTranslateID = nil
            }
            if pendingAutoTranslateID == nil {
                autoTranslateTask = nil
            }
        }
        guard currentPageURLString == targetURL else { return }
        guard hasAttemptedTranslationForCurrentPage == false else { return }
        guard isTranslating == false else { return }
        guard showOriginal == false else { return }
        guard attachedWebView != nil else { return }
        onShowOriginalChanged(false)
    }

    /// 번역 Task 생성이 실패했을 때 상태를 정리하고 원인을 로깅한다.
    func handleFailedTranslationStart(reason: String, requestID: UUID) {
        if activeTranslationID == requestID {
            activeTranslationID = nil
        }
        translationTask = nil
        isTranslating = false
        hasAttemptedTranslationForCurrentPage = false
        print("[BrowserViewModel] Failed to start translation: \(reason)")
    }

    func scheduleAutoTranslateRetry(after delay: UInt64 = 300_000_000) {
        scheduleAutoTranslate(after: delay)
    }

    func scheduleAutoTranslate(after delay: UInt64 = 0) {
        autoTranslateTask?.cancel()
        let targetURL = currentPageURLString
        let token = UUID()
        pendingAutoTranslateID = token
        autoTranslateTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    await self?.clearAutoTranslateRequest(for: token)
                    return
                }
            }
            guard Task.isCancelled == false else {
                await self?.clearAutoTranslateRequest(for: token)
                return
            }
            guard let self else { return }
            await self.runAutoTranslateIfNeeded(targetURL: targetURL, token: token)
        }
    }

    /// 전체 페이지 번역 스트림을 시작하고 스트림 이벤트를 처리한다.
    func startTranslate(on webView: WKWebView, requestID: UUID) async {
        guard let url = webView.url else { return }
        guard activeTranslationID == requestID else { return }
        translateRunID = requestID.uuidString

        closeOverlay()
        hasAttemptedTranslationForCurrentPage = true

        isTranslating = true
        defer {
            if self.activeTranslationID == requestID {
                self.normalizePageScale(webView)
                self.isTranslating = false
                self.translationTask = nil
                self.activeTranslationID = nil
            }
        }

        do {
            let executor = WKWebViewScriptAdapter(webView: webView)
            let engineTag = settings.preferredEngine
            let engineID = engineTag.rawValue
            let segments: [Segment]
            if let state = currentPageTranslation, state.url == url, state.segments.isEmpty == false {
                segments = state.segments
            } else {
                segments = try await extractor.extract(using: executor, url: url)
            }
            noBodyTextRetryCount = 0

            try Task.checkCancellation()
            guard activeTranslationID == requestID else { return }

            var state = currentPageTranslation ?? PageTranslationState(url: url, segments: [])
            state.url = url
            state.segments = segments
            state.totalSegments = segments.count
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

            replacer.restore(using: executor)
            replacer.setPairs([], using: executor, observer: .restart)

            if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
                coordinator.resetMarks()
                await coordinator.markSegments(segments)
            }

            let options = TranslationOptions()
            let summary = try await router.translateStream(
                segments: segments,
                options: options,
                preferredEngine: engineID
            ) { [weak self, weak webView] event in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let webView = webView else { return }
                    if Task.isCancelled { return }
                    await self.handleStreamEvent(
                        event,
                        url: url,
                        executor: executor,
                        requestID: requestID
                    )
                }
            }

            if var updatedState = currentPageTranslation, updatedState.url == url {
                updatedState.summary = summary
                currentPageTranslation = updatedState
                failedSegmentIDs = updatedState.failedSegmentIDs
                updateProgress(for: engineID)
            }
        } catch {
            if error is CancellationError { return }
            print("translate error: \(error)")
            let executor = WKWebViewScriptAdapter(webView: webView)
            replacer.restore(using: executor)
            _ = try? await executor.runJS("window.MT && MT.CLEAR && MT.CLEAR();")

            if let extractorError = error as? ExtractorError, extractorError == .noBodyText {
                noBodyTextRetryCount += 1
                if noBodyTextRetryCount <= 1 {
                    hasAttemptedTranslationForCurrentPage = false
                    scheduleAutoTranslateRetry()
                }
            }
        }
    }

    /// 선택된 세그먼트만 번역하는 부분 번역 스트림을 실행한다.
    func startPartialTranslation(
        segments: [Segment],
        engine: EngineTag,
        on webView: WKWebView,
        requestID: UUID
    ) async {
        guard let url = webView.url else { return }
        guard activeTranslationID == requestID else { return }
        translateRunID = requestID.uuidString

        closeOverlay()
        isTranslating = true
        hasAttemptedTranslationForCurrentPage = true
        defer {
            if self.activeTranslationID == requestID {
                self.normalizePageScale(webView)
                self.isTranslating = false
                self.translationTask = nil
                self.activeTranslationID = nil
            }
        }

        do {
            let executor = WKWebViewScriptAdapter(webView: webView)
            try Task.checkCancellation()
            guard activeTranslationID == requestID else { return }

            guard var state = currentPageTranslation, state.url == url else { return }
            state.buffersByEngine[engine.rawValue] = state.buffersByEngine[engine.rawValue] ?? .init()
            state.lastEngineID = engine.rawValue
            state.failedSegmentIDs.removeAll()
            state.scheduledSegmentIDs.removeAll()
            currentPageTranslation = state
            failedSegmentIDs = state.failedSegmentIDs
            updateProgress(for: engine.rawValue)

            let options = TranslationOptions()
            let summary = try await router.translateStream(
                segments: segments,
                options: options,
                preferredEngine: engine.rawValue
            ) { [weak self, weak webView] event in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let webView = webView else { return }
                    if Task.isCancelled { return }
                    await self.handleStreamEvent(
                        event,
                        url: url,
                        executor: executor,
                        requestID: requestID
                    )
                }
            }

            if var updatedState = currentPageTranslation, updatedState.url == url {
                updatedState.summary = summary
                currentPageTranslation = updatedState
                failedSegmentIDs = updatedState.failedSegmentIDs
                updateProgress(for: engine.rawValue)
            }
        } catch {
            if error is CancellationError { return }
            print("partial translate error: \(error)")
        }
    }

    /// 번역 스트림 이벤트를 분기 처리해 상태와 UI를 최신으로 유지한다.
    func handleStreamEvent(
        _ event: TranslationStreamEvent,
        url: URL,
        executor: WebViewScriptExecutor,
        requestID: UUID
    ) async {
        if Task.isCancelled { return }
        guard activeTranslationID == requestID else { return }

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

    /// 스트림으로 전달된 번역 결과를 캐시에 반영하고 웹뷰에 적용한다.
    func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engineID: TranslationEngineID,
        isFinal: Bool,
        executor: WebViewScriptExecutor,
        highlight: Bool,
        url: URL
    ) async {
        guard var state = currentPageTranslation, state.url == url else { return }
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
            engineID: payload.engineID,
            sequence: payload.sequence
        )
        replacer.upsert(
            payload: enrichedPayload,
            using: executor,
            applyImmediately: true,
            highlight: highlight
        )
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
        hasAttemptedTranslationForCurrentPage = true

        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
            Task { @MainActor in
                await coordinator.markSegments(state.segments)
            }
        }

        return CacheApplyResult(applied: true, remainingSegmentIDs: remainingSegmentIDs)
    }
}
