import CoreGraphics
import WebKit

@MainActor
extension BrowserViewModel {
    /// 선택된 세그먼트에 대한 오버레이를 구성하고 필요한 번역 작업을 시작한다.
    func onSegmentSelected(id: String, anchor: CGRect) async {
        print("[onSegmentSelected] id: \(id)")
        guard let webView = attachedWebView else {
            print("[BrowserViewModel] attachedWebView is nil. Cannot present overlay for segment: \(id)")
            return
        }
        guard let segment = lastSegments.first(where: { $0.id == id }) else { return }

        cancelOverlayTranslationTasks()
        selectedSegment = segment

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

    /// AFM 기반 개선 번역을 재활용할 때 사용할 예정인 AI 요청 진입점이다.
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

    /// 오버레이와 관련된 모든 상태와 비동기 작업을 정리하고 화면을 닫는다.
    func closeOverlay() {
        cancelOverlayTranslationTasks()
        overlayState = nil
        selectedSegment = nil
        clearSelectionHighlight()
    }

    /// 하이라이트 스크립트를 호출해 웹뷰의 선택 영역 표시를 제거한다.
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
    /// 오버레이에서 비교용으로 사용할 번역 엔진 목록을 계산한다.
    func overlayTargetEngines(for showOriginal: Bool, selectedEngine: EngineTag) -> [EngineTag] {
        if showOriginal {
            return [.afm, .google]
        }
        guard let alternate = overlayAlternateEngine(for: selectedEngine) else { return [] }
        return [alternate]
    }

    /// 선택된 엔진과 비교할 대체 엔진을 결정한다.
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

    /// 오버레이 엔진 섹션에 표시할 제목을 반환한다.
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

    /// 현재 페이지 캐시에 저장된 세그먼트 번역을 조회한다.
    func cachedTranslation(for segmentID: String, engineID: TranslationEngineID) -> String? {
        guard let state = currentPageTranslation,
              let buffer = state.buffersByEngine[engineID] else { return nil }
        return buffer.ordered.first(where: { $0.segmentID == segmentID })?.translatedText
    }

    /// 오버레이 번역 Task 저장에 사용할 고유 키를 생성한다.
    func overlayTaskKey(segmentID: String, engineID: TranslationEngineID) -> String {
        "\(segmentID)|\(engineID)"
    }

    /// 진행 중인 모든 오버레이 번역 Task 를 취소하고 비운다.
    func cancelOverlayTranslationTasks() {
        for runID in overlayTranslationTasks.keys {
            RouterCancellationCenter.shared.cancel(runID: runID)
        }
        for task in overlayTranslationTasks.values {
            task.cancel()
        }
        overlayTranslationTasks.removeAll()
    }

    /// 지정된 엔진으로 오버레이 번역 스트림을 시작하고 결과를 상태에 반영한다.
    func startOverlayTranslation(for engine: EngineTag, segment: Segment) {
        let key = overlayTaskKey(segmentID: segment.id, engineID: engine.rawValue)
        overlayTranslationTasks[key]?.cancel()
        RouterCancellationCenter.shared.cancel(runID: key)

        let options = TranslationOptions()
        let bag = RouterCancellationCenter.shared.bag(for: key)
        
        let worker = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            do {
                _ = try await router.translateStream(
                    runID: key,
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
                await MainActor.run { [weak self] in
                    self?.updateOverlayTranslation(
                        segmentID: segment.id,
                        engineID: engine.rawValue,
                        text: nil,
                        errorMessage: "번역을 가져오는 중 오류가 발생했습니다."
                    )
                }
            }

            await MainActor.run { [weak self] in
                self?.overlayTranslationTasks.removeValue(forKey: key)
                RouterCancellationCenter.shared.remove(runID: key)
            }
        }
        bag.insert { worker.cancel() }
        overlayTranslationTasks[key] = worker
    }

    /// 오버레이 스트림 이벤트를 수신해 해당 엔진 섹션을 갱신한다.
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

    /// 오버레이 상태에서 특정 엔진 항목의 텍스트와 오류를 갱신한다.
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

    /// 오버레이 번역 결과를 페이지 단위 캐시에 반영해 재사용 가능하게 만든다.
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
