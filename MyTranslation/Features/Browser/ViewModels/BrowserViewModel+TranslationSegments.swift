import Foundation
import NaturalLanguage
import WebKit

@MainActor
extension BrowserViewModel {
    /// 세션 준비(세그먼트, 상태 세팅 / 표시 초기화)
    func prepareTranslationSession(
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
            let segments: [Segment]
            if let state = currentPageTranslation,
               state.url == url,
               !state.segments.isEmpty {
                segments = state.segments
            } else {
                // 소스 언어에 맞는 추출 설정 사용
                let sourceLanguage = languagePreference.source.resolved ?? AppLanguage(code: "en")
                let config = sourceLanguage.extractConfig
                segments = try await extractor.extract(using: executor, url: url, config: config)
            }
            noBodyTextRetryCount = 0

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
