import Foundation
import WebKit

private func _id(_ id: UUID?) -> String { id?.uuidString ?? "nil" }
private func _url(_ url: URL?) -> String { url?.absoluteString ?? "nil" }

@MainActor
extension BrowserViewModel {
    /// 페이지 로딩이 끝났을 때 주소 표시줄과 번역 상태를 초기화한다.
    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        normalizePageScale(webView)

        let urlString = url.absoluteString
        let isNewPage = currentPageURLString != urlString

        print(
            "[T] didFinish url=\(urlString) isNew=\(isNewPage) curPage(before)=\(currentPageURLString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )

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
        print(
            "[T] requestTranslation(on:) ENTER isTranslating=\(isTranslating) url=\(_url(webView.url)) curPage=\(currentPageURLString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) eng=\(settings.preferredEngine.rawValue)"
        )
        guard isStartingTranslation == false else { return }
        isStartingTranslation = true
        defer { isStartingTranslation = false }

        translationTask?.cancel()
        translationTask = nil
        pendingAutoTranslateID = nil
        let requestID = UUID()
        print(
            "[T] requestTranslation(on:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)"
        )
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
        print(
            "[T] requestTranslation(on:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
    }

    /// 지정된 세그먼트들만 재번역하도록 부분 번역 작업을 예약한다.
    func requestTranslation(
        for segmentIDs: [String],
        engine: EngineTag,
        on webView: WKWebView
    ) {
        print(
            "[T] requestTranslation(for:) ENTER segCount=\(segmentIDs.count) url=\(_url(webView.url)) curPage=\(currentPageURLString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) eng=\(engine.rawValue)"
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

        guard isStartingTranslation == false else { return }
        isStartingTranslation = true
        defer { isStartingTranslation = false }

        translationTask?.cancel()
        translationTask = nil
        pendingAutoTranslateID = nil
        let requestID = UUID()
        print(
            "[T] requestTranslation(for:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)"
        )
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
        print(
            "[T] requestTranslation(for:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
    }

    /// 원문 보기 토글에 맞춰 번역 적용 또는 취소 흐름을 제어한다.
    func onShowOriginalChanged(_ showOriginal: Bool) {
        guard let webView = attachedWebView else { return }
        print(
            "[T] onShowOriginalChanged showOriginal=\(showOriginal) url=\(_url(webView.url)) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
        let executor = WKWebViewScriptAdapter(webView: webView)
        if showOriginal {
            cancelActiveTranslation()
            replacer.restore(using: executor)
            closeOverlay()
        } else {
            let engine = settings.preferredEngine
            let cacheResult = applyCachedTranslationIfAvailable(for: engine, on: webView)
            print(
                "[T] onShowOriginalChanged path=\(cacheResult.applied ? \"applyCache\" : \"requestTranslation\") remaining=\(cacheResult.remainingSegmentIDs.count) url=\(_url(webView.url)) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) eng=\(engine.rawValue)"
            )
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
        print(
            "[T] willNavigate url=\(_url(webView.url)) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
        cancelActiveTranslation()
        let executor = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: executor)
        if let coordinator = webView.navigationDelegate as? WebContainerView.Coordinator {
            coordinator.resetMarks()
        }
        request = nil
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
            "[T] cancelActiveTranslation act(before)=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
        translationTask?.cancel()
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
        if let webView = attachedWebView {
            normalizePageScale(webView)
        }
    }

    func clearAutoTranslateRequest(for token: UUID) {
        print(
            "[T] clearAutoTranslateRequest token=\(token.uuidString) pendAuto(before)=\(_id(pendingAutoTranslateID))"
        )
        if pendingAutoTranslateID == token {
            pendingAutoTranslateID = nil
            if autoTranslateTask?.isCancelled ?? true {
                autoTranslateTask = nil
            }
        }
    }

    func runAutoTranslateIfNeeded(targetURL: String, token: UUID) async {
        print(
            "[T] runAutoTranslateIfNeeded token=\(token.uuidString) target=\(targetURL) curPage=\(currentPageURLString) isTranslating=\(isTranslating) hasAttempted=\(hasAttemptedTranslationForCurrentPage) pendAuto=\(_id(pendingAutoTranslateID))"
        )
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
        print(
            "[T] handleFailedTranslationStart reason=\(reason) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
        )
        print("[BrowserViewModel] Failed to start translation: \(reason)")
    }

    func scheduleAutoTranslateRetry(after delay: UInt64 = 300_000_000) {
        scheduleAutoTranslate(after: delay)
    }

    func scheduleAutoTranslate(after delay: UInt64 = 0) {
        print(
            "[T] scheduleAutoTranslate delay=\(delay) target=\(currentPageURLString) pendAuto(old)=\(_id(pendingAutoTranslateID))"
        )
        autoTranslateTask?.cancel()
        let targetURL = currentPageURLString
        let token = UUID()
        pendingAutoTranslateID = token
        print("[T] scheduleAutoTranslate set pendAuto(new)=\(token.uuidString)")
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

        print(
            "[T] startTranslate BEGIN req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) url=\(_url(webView.url)) state.url=\(_url(currentPageTranslation?.url)) eng=\(settings.preferredEngine.rawValue)"
        )

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
            print(
                "[T] startTranslate END req=\(requestID.uuidString) act=\(_id(self.activeTranslationID)) pendAuto=\(_id(self.pendingAutoTranslateID)) url=\(_url(webView.url)) state.url=\(_url(self.currentPageTranslation?.url))"
            )
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

            print(
                "[T] startTranslate EXTRACTED segs=\(segments.count) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
            )

            try Task.checkCancellation()
            print(
                "[T] startTranslate post-cancel-check OK req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
            )
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
            print(
                "[T] router.translateStream CALL segs=\(segments.count) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) eng=\(engineID)"
            )
            let summary = try await router.translateStream(
                segments: segments,
                options: options,
                preferredEngine: engineID
            ) { [weak self, weak webView] event in
                guard let self else { return }
                let segmentID: String
                switch event.kind {
                case let .partial(segment):
                    segmentID = segment.segmentID
                case let .final(segment):
                    segmentID = segment.segmentID
                case let .failed(segmentIDValue, _):
                    segmentID = segmentIDValue
                default:
                    segmentID = "nil"
                }
                print(
                    "[T] progress event=\(event.kind.name) req=\(requestID.uuidString) act=\(_id(self.activeTranslationID)) pendAuto=\(_id(self.pendingAutoTranslateID)) webUrl=\(_url(webView?.url)) snapUrl=\(_url(url)) state.url=\(_url(self.currentPageTranslation?.url)) eng=\(engineID) seg=\(segmentID)"
                )
                Task.detached(priority: .userInitiated) { @MainActor [weak self] in
                    guard let self, let webView = webView else { return }
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

        print(
            "[T] startPartialTranslation BEGIN segCount=\(segments.count) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) url=\(_url(webView.url)) state.url=\(_url(currentPageTranslation?.url)) eng=\(engine.rawValue)"
        )

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
            print(
                "[T] startPartialTranslation END req=\(requestID.uuidString) act=\(_id(self.activeTranslationID)) pendAuto=\(_id(self.pendingAutoTranslateID)) url=\(_url(webView.url)) state.url=\(_url(self.currentPageTranslation?.url))"
            )
        }

        do {
            let executor = WKWebViewScriptAdapter(webView: webView)
            try Task.checkCancellation()
            print(
                "[T] startPartialTranslation post-cancel-check OK req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
            )
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
            print(
                "[T] router.translateStream CALL segs=\(segments.count) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) eng=\(engine.rawValue)"
            )
            let summary = try await router.translateStream(
                segments: segments,
                options: options,
                preferredEngine: engine.rawValue
            ) { [weak self, weak webView] event in
                guard let self else { return }
                let segmentID: String
                switch event.kind {
                case let .partial(segment):
                    segmentID = segment.segmentID
                case let .final(segment):
                    segmentID = segment.segmentID
                case let .failed(segmentIDValue, _):
                    segmentID = segmentIDValue
                default:
                    segmentID = "nil"
                }
                print(
                    "[T] progress event=\(event.kind.name) req=\(requestID.uuidString) act=\(_id(self.activeTranslationID)) pendAuto=\(_id(self.pendingAutoTranslateID)) webUrl=\(_url(webView?.url)) snapUrl=\(_url(url)) state.url=\(_url(self.currentPageTranslation?.url)) eng=\(engine.rawValue) seg=\(segmentID)"
                )
                Task.detached(priority: .userInitiated) { @MainActor [weak self] in
                    guard let self, let webView = webView else { return }
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
        print(
            "[T] handleStreamEvent ENTER event=\(event.kind.name) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) webUrl=\(_url(attachedWebView?.url)) snapUrl=\(_url(url)) state.url=\(_url(currentPageTranslation?.url))"
        )
        if activeTranslationID != requestID {
            print(
                "[T] handleStreamEvent DROP reason=activeID-mismatch req=\(requestID.uuidString) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
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

    /// 스트림으로 전달된 번역 결과를 캐시에 반영하고 웹뷰에 적용한다.
    func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engineID: TranslationEngineID,
        isFinal: Bool,
        executor: WebViewScriptExecutor,
        highlight: Bool,
        url: URL
    ) async {
        print(
            "[T] applyStreamPayload ENTER seg=\(payload.segmentID) final=\(isFinal) req-NA act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) webUrl=\(_url(attachedWebView?.url)) snapUrl=\(_url(url)) state.url=\(_url(currentPageTranslation?.url)) eng=\(engineID)"
        )
        guard var state = currentPageTranslation, state.url == url else {
            print(
                "[T] applyStreamPayload DROP reason=url-mismatch seg=\(payload.segmentID) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID)) webUrl=\(_url(attachedWebView?.url)) snapUrl=\(_url(url)) state.url=\(_url(currentPageTranslation?.url))"
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
            engineID: payload.engineID,
            sequence: payload.sequence
        )
        print(
            "[T] applyStreamPayload UPSERT seg=\(payload.segmentID) final=\(isFinal) eng=\(engineID) act=\(_id(activeTranslationID)) pendAuto=\(_id(pendingAutoTranslateID))"
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
