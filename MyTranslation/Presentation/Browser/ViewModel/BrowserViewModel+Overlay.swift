import CoreGraphics
import WebKit

@MainActor
extension BrowserViewModel {
    /// WebContainerView.onSelectSegment 에서 호출된다.
    func onSegmentSelected(id: String, anchor: CGRect) async {
        print("[onSegmentSelected] id: \(id)")
        guard let webView = attachedWebView,
              let segment = lastSegments.first(where: { $0.id == id }) else { return }

        cancelOverlayTranslationTasks()
        selectedSegment = segment
        pendingImproved = nil

        let targetEngines = overlayTargetEngines(for: showOriginal, selectedEngine: settings.preferredEngine)
        var translations: [OverlayState.Translation] = []
        var enginesToFetch: [EngineTag] = []

        for engine in targetEngines {
            let engineID = engine.rawValue
            let cached = cachedTranslation(for: segment.id, engineID: engineID)
            translations.append(
                .init(
                    engineID: engineID,
                    title: overlaySectionTitle(for: engine),
                    text: cached,
                    isLoading: cached == nil,
                    errorMessage: nil
                )
            )
            if cached == nil {
                enginesToFetch.append(engine)
            }
        }

        overlayState = .init(
            segmentID: segment.id,
            selectedText: segment.originalText,
            improvedText: nil,
            anchor: anchor,
            translations: translations,
            showsOriginalSection: showOriginal == false
        )

        let executor = WKWebViewScriptAdapter(webView: webView)
        _ = try? await executor.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
        _ = try? await executor.runJS(#"window.MT && MT.HILITE && MT.HILITE(\#(String(reflecting: id)));"#)

        for engine in enginesToFetch {
            startOverlayTranslation(for: engine, segment: segment)
        }
    }

    func askAIForSelected() async {
//        guard settings.useFM else { return }
//        guard let seg = selectedSegment else { return }
//        let current = lastStreamPayloads.first(where: { $0.segmentID == seg.id })?.translatedText
//        // 간단 문맥: ±1
//        let para = lastSegments.filter { $0.url == seg.url }.sorted { $0.indexInPage < $1.indexInPage }
//        let idx = para.firstIndex(where: { $0.id == seg.id }) ?? 0
//        let prev = idx > 0 ? [para[idx - 1].originalText] : []
//        let next = idx + 1 < para.count ? [para[idx + 1].originalText] : []
//        do {
//            let ans = try await fmQuery.ask(for: seg, currentTranslation: current, context: .init(previous: prev, next: next))
//            self.pendingImproved = ans.improvedText
//            if var state = overlayState, state.segmentID == seg.id {
//                state.improvedText = ans.improvedText
//                overlayState = state
//            }
//        } catch {
//            print("FM ask failed: \(error)")
//        }
    }

    func applyAIImproved() {
        guard let segment = selectedSegment,
              let improved = pendingImproved,
              let webView = attachedWebView else { return }

        let executor = WKWebViewScriptAdapter(webView: webView)
        let engineID = lastStreamPayloads.first(where: { $0.segmentID == segment.id })?.engineID
            ?? settings.preferredEngine.rawValue
        let sequence = lastStreamPayloads.first(where: { $0.segmentID == segment.id })?.sequence
            ?? (lastStreamPayloads.count + 1)
        let payload = TranslationStreamPayload(
            segmentID: segment.id,
            originalText: segment.originalText,
            translatedText: improved,
            engineID: engineID,
            sequence: sequence
        )

        replacer.upsert(payload: payload, using: executor, applyImmediately: true, highlight: false)

        if var state = currentPageTranslation,
           let currentURL = webView.url,
           currentURL == state.url {
            var buffer = state.buffersByEngine[engineID] ?? .init()
            buffer.upsert(payload)
            state.buffersByEngine[engineID] = buffer
            state.lastEngineID = engineID
            state.finalizedSegmentIDs.insert(segment.id)
            state.failedSegmentIDs.remove(segment.id)
            state.scheduledSegmentIDs.remove(segment.id)
            currentPageTranslation = state
            lastStreamPayloads = buffer.ordered
            failedSegmentIDs = state.failedSegmentIDs
            updateProgress(for: engineID)
        }

        if var state = overlayState, state.segmentID == segment.id {
            state.improvedText = improved
            overlayState = state
        }
    }

    func closeOverlay() {
        cancelOverlayTranslationTasks()
        overlayState = nil
        selectedSegment = nil
        pendingImproved = nil
        clearSelectionHighlight()
    }

    func clearSelectionHighlight() {
        guard let webView = attachedWebView else { return }
        Task { @MainActor in
            let executor = WKWebViewScriptAdapter(webView: webView)
            _ = try? await executor.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
        }
    }
}

@MainActor
private extension BrowserViewModel {
    func overlayTargetEngines(for showOriginal: Bool, selectedEngine: EngineTag) -> [EngineTag] {
        if showOriginal {
            return [.afm, .google]
        }
        guard let alternate = overlayAlternateEngine(for: selectedEngine) else { return [] }
        return [alternate]
    }

    func overlayAlternateEngine(for engine: EngineTag) -> EngineTag? {
        switch engine {
        case .afm, .afmMask:
            return .google
        case .google:
            return .afm
        case .deepl, .unknown:
            return .google
        }
    }

    func overlaySectionTitle(for engine: EngineTag) -> String {
        switch engine {
        case .afm, .afmMask:
            return "AFM 번역"
        case .google:
            return "Google 번역"
        case .deepl:
            return "DeepL 번역"
        case .unknown:
            return "번역"
        }
    }

    func cachedTranslation(for segmentID: String, engineID: TranslationEngineID) -> String? {
        guard let state = currentPageTranslation,
              let buffer = state.buffersByEngine[engineID] else { return nil }
        return buffer.ordered.first(where: { $0.segmentID == segmentID })?.translatedText
    }

    func overlayTaskKey(segmentID: String, engineID: TranslationEngineID) -> String {
        "\(segmentID)|\(engineID)"
    }

    func cancelOverlayTranslationTasks() {
        for task in overlayTranslationTasks.values {
            task.cancel()
        }
        overlayTranslationTasks.removeAll()
    }

    func startOverlayTranslation(for engine: EngineTag, segment: Segment) {
        let key = overlayTaskKey(segmentID: segment.id, engineID: engine.rawValue)
        overlayTranslationTasks[key]?.cancel()

        let options = TranslationOptions()
        overlayTranslationTasks[key] = Task(priority: .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await router.translateStream(
                    segments: [segment],
                    options: options,
                    preferredEngine: engine.rawValue
                ) { event in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if Task.isCancelled { return }
                        self.handleOverlayTranslationEvent(
                            event,
                            segmentID: segment.id,
                            engineID: engine.rawValue
                        )
                    }
                }
            } catch is CancellationError {
                // 취소 시 별도 처리 없음
            } catch {
                updateOverlayTranslation(
                    segmentID: segment.id,
                    engineID: engine.rawValue,
                    text: nil,
                    errorMessage: "번역을 가져오는 중 오류가 발생했습니다."
                )
            }

            overlayTranslationTasks.removeValue(forKey: key)
        }
    }

    func handleOverlayTranslationEvent(
        _ event: TranslationStreamEvent,
        segmentID: String,
        engineID: TranslationEngineID
    ) {
        guard let currentOverlay = overlayState, currentOverlay.segmentID == segmentID else { return }

        switch event.kind {
        case let .final(segment):
            guard segment.segmentID == segmentID else { return }
            guard let text = segment.translatedText, text.isEmpty == false else {
                updateOverlayTranslation(
                    segmentID: segmentID,
                    engineID: engineID,
                    text: nil,
                    errorMessage: "번역 결과가 비어 있습니다."
                )
                return
            }
            storeOverlayTranslationPayload(segment)
            updateOverlayTranslation(
                segmentID: segmentID,
                engineID: engineID,
                text: text,
                errorMessage: nil
            )
        case let .failed(failedSegmentID, _):
            guard failedSegmentID == segmentID else { return }
            updateOverlayTranslation(
                segmentID: segmentID,
                engineID: engineID,
                text: nil,
                errorMessage: "번역에 실패했습니다."
            )
        default:
            break
        }
    }

    func updateOverlayTranslation(
        segmentID: String,
        engineID: TranslationEngineID,
        text: String?,
        errorMessage: String?
    ) {
        guard var state = overlayState, state.segmentID == segmentID else { return }
        guard let index = state.translations.firstIndex(where: { $0.engineID == engineID }) else { return }
        state.translations[index].text = text
        state.translations[index].isLoading = false
        state.translations[index].errorMessage = errorMessage
        overlayState = state
    }

    func storeOverlayTranslationPayload(_ payload: TranslationStreamPayload) {
        guard var state = currentPageTranslation,
              let webView = attachedWebView,
              let url = webView.url,
              state.url == url else { return }

        var buffer = state.buffersByEngine[payload.engineID] ?? .init()
        buffer.upsert(payload)
        state.buffersByEngine[payload.engineID] = buffer
        currentPageTranslation = state
    }
}
