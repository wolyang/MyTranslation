import Foundation
import WebKit

@MainActor
extension BrowserViewModel {
    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        normalizePageScale(webView)

        request = nil
        pendingURLAfterEditing = url.absoluteString
        if isEditingURL == false {
            urlString = url.absoluteString
            pendingURLAfterEditing = nil
        }

        if currentPageTranslation?.url != url {
            currentPageTranslation = nil
        }
        currentPageURLString = url.absoluteString

        if hasAttemptedTranslationForCurrentPage == false {
            pendingAutoTranslateID = UUID()
        }
    }

    func requestTranslation(on webView: WKWebView) {
        translationTask?.cancel()
        let requestID = UUID()
        activeTranslationID = requestID
        translationTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.startTranslate(on: webView, requestID: requestID)
        }
    }

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
        let requestID = UUID()
        activeTranslationID = requestID
        translationTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.startPartialTranslation(
                segments: segments,
                engine: engine,
                on: webView,
                requestID: requestID
            )
        }
    }

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
        closeOverlay()
        pendingURLAfterEditing = nil
        currentPageTranslation = nil
        lastSegments = []
        lastStreamPayloads = []
        failedSegmentIDs = []
        translationProgress = 0
    }

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
}

@MainActor
private extension BrowserViewModel {
    func cancelActiveTranslation() {
        translationTask?.cancel()
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
        if let webView = attachedWebView {
            normalizePageScale(webView)
        }
    }

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
        }
    }

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

    func normalizePageScale(_ webView: WKWebView) {
        if webView.responds(to: #selector(getter: WKWebView.pageZoom)) {
            webView.pageZoom = 1.0
        }
        webView.scrollView.setZoomScale(1.0, animated: false)
    }

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
