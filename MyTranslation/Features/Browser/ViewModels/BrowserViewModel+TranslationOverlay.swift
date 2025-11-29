import Foundation
import WebKit

@MainActor
extension BrowserViewModel {
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

        if var updatedState = currentPageTranslation, updatedState.url == webView.url {
            updatedState.summary = summary
            currentPageTranslation = updatedState
            failedSegmentIDs = updatedState.failedSegmentIDs
            updateProgress(for: engineID)
        }
        return summary
    }

    func handleStreamEvent(
        _ event: TranslationStreamEvent,
        url: URL,
        executor: WebViewScriptExecutor,
        requestID: UUID
    ) async {
        if activeTranslationID != requestID {
            print("[T] handleStreamEvent DROP reason=activeID-mismatch req=\(requestID.uuidString) act=\(_id(activeTranslationID))")
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

    func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engineID: TranslationEngineID,
        isFinal: Bool,
        executor: WebViewScriptExecutor,
        highlight: Bool,
        url: URL
    ) async {
        guard var state = currentPageTranslation, state.url == url else {
            print("[T] applyStreamPayload DROP reason=url-mismatch seg=\(payload.segmentID) act=\(_id(activeTranslationID)) webUrl=\(_url(attachedWebView?.url)) snapUrl=\(_url(url)) state.url=\(_url(currentPageTranslation?.url))")
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

    func clearMT(on webView: WKWebView) async {
        let ex = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: ex)
        _ = try? await ex.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
    }
}
