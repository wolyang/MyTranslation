import Foundation
import WebKit

@MainActor
extension BrowserViewModel {
    /// 페이지 로딩이 끝났을 때 주소 표시줄과 번역 상태를 초기화한다.
    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        normalizePageScale(webView)

        let prevEffectiveURL = currentPageURLString
        let curURLString = url.absoluteString
        settings.lastVisitedURL = curURLString
        let isNewPage = (prevEffectiveURL != curURLString)
        historyStore.recordVisit(url: url, title: webView.title)

        print("[T] didFinish url=\(curURLString) isNew=\(isNewPage) curPage(before)=\(prevEffectiveURL) act=\(_id(activeTranslationID))")

        request = nil
        if isEditingURL == false {
            urlString = curURLString
        } else {
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

    /// 캐시된 번역 적용, 필요시 전체/일부 번역 시작
    func ensureTranslatedIfVisible(on webView: WKWebView) {
        guard showOriginal == false else { return }

        if let act = activeTranslationID, isTranslating {
            print("[T] ensureTranslatedIfVisible skip: in-flight act=\(act)")
            return
        }

        let engine = settings.preferredEngine
        let cache = applyCachedTranslationIfAvailable(for: engine, on: webView)
        print("[T] ensureTranslatedIfVisible path=\(cache.applied ? "applyCache" : "requestTranslation") remaining=\(cache.remainingSegmentIDs.count)")

        if cache.applied == false {
            requestTranslation(on: webView)
        } else if cache.remainingSegmentIDs.isEmpty == false {
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

        cancelActiveTranslation()

        let requestID = UUID()
        print("[T] requestTranslation(on:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)")
        activeTranslationID = requestID

        let bag = RouterCancellationCenter.shared.bag(for: requestID.uuidString)
        var task: Task<Void, Never>? = nil
        bag.insert { task?.cancel() }

        task = Task { [weak self, weak webView] in
            guard let self, let webView else {
                self?.handleFailedTranslationStart(
                    reason: "webView released before translation",
                    requestID: requestID
                )
                return
            }

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
                ) else { throw TranslationSessionError.prepareFailed }

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
        print("[T] requestTranslation(on:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID))")
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

        cancelActiveTranslation()

        let requestID = UUID()
        print("[T] requestTranslation(for:) assign activeTranslationID old=\(_id(activeTranslationID)) new=\(requestID.uuidString)")
        activeTranslationID = requestID

        let bag = RouterCancellationCenter.shared.bag(for: requestID.uuidString)
        var task: Task<Void, Never>? = nil
        bag.insert { task?.cancel() }

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
                ) else { throw TranslationSessionError.prepareFailed }
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
        print("[T] requestTranslation(for:) SPAWN translationTask req=\(requestID.uuidString) act=\(_id(activeTranslationID))")
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

        ensureTranslatedIfVisible(on: webView)
    }

    /// 페이지 이동 전에 번역 상태와 하이라이트를 정리한다.
    func willNavigate() {
        guard let webView = attachedWebView else { return }
        print("[T] willNavigate url=\(_url(webView.url)) act=\(_id(activeTranslationID))")
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

@MainActor
internal extension BrowserViewModel {
    func cancelActiveTranslation() {
        print("[T] cancelActiveTranslation act(before)=\(_id(activeTranslationID))")
        if let activeTranslationID {
            RouterCancellationCenter.shared.cancel(runID: activeTranslationID.uuidString)
            RouterCancellationCenter.shared.remove(runID: activeTranslationID.uuidString)
        }
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
    }

    func handleFailedTranslationStart(reason: String, requestID: UUID) {
        print("[T] handleFailedTranslationStart reason=\(reason) req=\(requestID.uuidString) act=\(_id(activeTranslationID)) ")
        if activeTranslationID == requestID {
            cancelActiveTranslation()
        }
        print("[BrowserViewModel] Failed to start translation: \(reason)")
    }

    func finalizeTranslationSessionIfCurrent(_ requestID: UUID, webView: WKWebView) async {
        print("[T] finalizeTranslationSessionIfCurrent reqID: \(requestID.uuidString)")
        guard activeTranslationID == requestID else { return }
        normalizePageScale(webView)
        isTranslating = false
        translationTask = nil
        activeTranslationID = nil
    }

    func normalizePageScale(_ webView: WKWebView) {
        if webView.responds(to: #selector(getter: WKWebView.pageZoom)) {
            webView.pageZoom = 1.0
        }
        webView.scrollView.setZoomScale(1.0, animated: false)
    }

    func makeTranslationOptions(using preference: PageLanguagePreference) -> TranslationOptions {
        TranslationOptions(
            preserveFormatting: true,
            style: .neutralDictionaryTone,
            applyGlossary: true,
            sourceLanguage: preference.source,
            targetLanguage: preference.target,
            tokenSpacingBehavior: spacingBehavior(for: preference)
        )
    }

    func spacingBehavior(for preference: PageLanguagePreference) -> TokenSpacingBehavior {
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
}
