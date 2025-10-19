// File: BrowserViewModel.swift
import Foundation
import CoreGraphics
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var urlString: String = /*"https://nakazaki.lofter.com/post/1ea19791_2bfbab779?incantation=rzRAnYWzp157"*/"https://archiveofourown.org/works/64915999/chapters/167219878#workskin"//"https://archiveofourown.org/tags/Jugglus%20Juggler%20%7C%20Hebikura%20Shota*s*Kurenai%20Gai/works" // 개발 중 편의를 위한 임시 url 입력

    @Published var isTranslating: Bool = false
    @Published var showOriginal: Bool = false
    @Published var isEditingURL: Bool = false {
        didSet {
            if isEditingURL == false, let pendingURLAfterEditing {
                urlString = pendingURLAfterEditing
                self.pendingURLAfterEditing = nil
            }
        }
    }

    // Web loading binding
    @Published var request: URLRequest? = nil
    @Published private(set) var currentPageURLString: String = ""

    // For optional auto-translate trigger
    @Published var pendingAutoTranslateID: UUID? = nil
    private var hasAttemptedTranslationForCurrentPage = false

    // Keep last attached webView (weak-like)
    weak var attachedWebView: WKWebView?

    var currentURL: URL? { URL(string: urlString) }

    private(set) var lastSegments: [Segment] = []
    private(set) var lastStreamPayloads: [TranslationStreamPayload] = []
    private var pendingURLAfterEditing: String?
    private var currentPageTranslation: PageTranslationState?
    private var translationTask: Task<Void, Never>? = nil
    private var activeTranslationID: UUID?

    private let container: AppContainer
    let extractor: ContentExtractor
    private let router: TranslationRouter
//    let overlay: OverlayRenderer
    let replacer: InlineReplacer
    
    @Published var fmPanel: FMAnswer?

//    let fmQuery: FMQueryService
    let settings: UserSettings

    private var selectedSegment: Segment?
    private var pendingImproved: String?

    @Published var overlayState: OverlayState?

    @Published var translateRunID: String = ""
    @Published var translationProgress: Double = 0
    @Published var failedSegmentIDs: Set<String> = []

    init(
        container: AppContainer,
        extractor: ContentExtractor = WKContentExtractor(),
        router: TranslationRouter,
        replacer: InlineReplacer,
//        fmQuery: FMQueryService,
        settings: UserSettings
    ) {
        self.container = container
        self.extractor = extractor
        self.router = router
        self.replacer = replacer
//        self.fmQuery = fmQuery
        self.settings = settings
    }

    func normalizedURL(from string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        if let url = URL(string: string), url.scheme != nil { return url }
        return URL(string: "https://" + string)
    }

    func load(urlString: String) {
        self.urlString = urlString
        guard var url = normalizedURL(from: urlString) else { return }

        // 같은 URL로 재로딩을 시도할 때도 실제로 다시 로드가 일어나도록 fragment로 bust
        if let current = attachedWebView?.url, current == url {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let ts = String(Int(Date().timeIntervalSince1970))
            // 기존 fragment 보존 + 'reload' 토큰 추가
            let existingFrag = (comps?.fragment ?? "")
            let token = existingFrag.isEmpty ? "reload=\(ts)" : existingFrag + "&reload=\(ts)"
            comps?.fragment = token
            url = comps?.url ?? url
        }

        // 캐시 무시로 강제 새 로드 성향을 높임
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        self.request = req

        // 수동 로드가 시작되므로 이번 페이지에 대해 1회 시도 가능하도록 리셋
        hasAttemptedTranslationForCurrentPage = false
        pendingURLAfterEditing = nil
    }
    
    func attachWebView(_ web: WKWebView) {
        self.attachedWebView = web
    }
    
    // WebContainerView.onSelectSegment 에 연결
    func onSegmentSelected(id: String, anchor: CGRect) async {
        print("[onSegmentSelected] id: \(id)")
        guard let webView = attachedWebView, let seg = lastSegments.first(where: { $0.id == id }) else { return }
        self.selectedSegment = seg
        self.pendingImproved = nil
        self.overlayState = OverlayState(
            segmentID: seg.id,
            selectedText: seg.originalText,
            improvedText: nil,
            anchor: anchor
        )

        let exec = WKWebViewScriptAdapter(webView: webView)
        _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
        _ = try? await exec.runJS(#"window.MT && MT.HILITE && MT.HILITE(\#(String(reflecting: id)));"#)
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
        guard let seg = selectedSegment, let improved = pendingImproved, let web = attachedWebView else { return }
        let exec = WKWebViewScriptAdapter(webView: web)
// <<<<<<< codex/refactor-starttranslate-for-new-streaming-api
// 
//         let engine = lastStreamPayloads.first(where: { $0.segmentID == seg.id })?.engineID ?? settings.preferredEngine
//         let sequence = lastStreamPayloads.first(where: { $0.segmentID == seg.id })?.sequence ?? (lastStreamPayloads.count + 1)
//         let payload = TranslationStreamPayload(
//             segmentID: seg.id,
//             originalText: seg.originalText,
//             translatedText: improved,
//             engineID: engine,
//             sequence: sequence
//         )

//         replacer.upsert(payload: payload, using: exec, applyImmediately: true, highlight: false)

//         if var state = currentPageTranslation {
//             if let currentURL = web.url, currentURL != state.url {
//                 // 다른 페이지의 상태일 경우에는 캐시만 갱신하지 않는다.
//             } else {
//                 var buffer = state.buffersByEngine[engine] ?? .init()
//                 buffer.upsert(payload)
//                 state.buffersByEngine[engine] = buffer
//                 state.finalizedSegmentIDs.insert(seg.id)
//                 state.failedSegmentIDs.remove(seg.id)
//                 state.scheduledSegmentIDs.remove(seg.id)
// =======
        replacer.upsertPair((original: seg.originalText, translated: improved), using: exec, immediateApply: true)
        if let i = lastResults.firstIndex(where: { $0.segmentID == seg.id }) {
            let previous = lastResults[i]
            let updated = TranslationResult(
                id: previous.id, segmentID: seg.id,
                engine: previous.engine, text: improved,
                residualSourceRatio: previous.residualSourceRatio,
                createdAt: Date()
            )
            lastResults[i] = updated
            if var state = currentPageTranslation,
               var cached = state.resultsByEngine[previous.engine],
               let cachedIndex = cached.firstIndex(where: { $0.segmentID == seg.id }) {
                cached[cachedIndex] = updated
                state.resultsByEngine[previous.engine] = cached
// >>>>>>> streaming-translation-base
                currentPageTranslation = state
                lastStreamPayloads = buffer.ordered
                failedSegmentIDs = state.failedSegmentIDs
                updateProgress(for: engine)
            }
        }

        if var state = overlayState, state.segmentID == seg.id {
            state.improvedText = improved
            overlayState = state
        }
    }

    func onWebViewDidFinishLoad(_ webView: WKWebView, url: URL) {
        normalizePageScale(webView)

        request = nil
        pendingURLAfterEditing = url.absoluteString
        if isEditingURL == false {
            self.urlString = url.absoluteString
            pendingURLAfterEditing = nil
        }

        if currentPageTranslation?.url != url {
            currentPageTranslation = nil
        }
        currentPageURLString = url.absoluteString

        // Auto-translate policy: translate after each load (can refine later)
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

    private func cancelActiveTranslation() {
        translationTask?.cancel()
        translationTask = nil
        activeTranslationID = nil
        isTranslating = false
        if let webView = attachedWebView {
            normalizePageScale(webView)
        }
    }

    private func startTranslate(on webView: WKWebView, requestID: UUID) async {
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
            let exec = WKWebViewScriptAdapter(webView: webView)
            let engine = settings.preferredEngine
            let segs: [Segment]
            if let state = currentPageTranslation, state.url == url, state.segments.isEmpty == false {
                segs = state.segments
            } else {
                segs = try await extractor.extract(using: exec, url: url)
            }

            try Task.checkCancellation()
            guard activeTranslationID == requestID else { return }

            var state = currentPageTranslation ?? PageTranslationState(url: url, segments: [])
            state.url = url
            state.segments = segs
            state.totalSegments = segs.count
            state.buffersByEngine[engine] = state.buffersByEngine[engine] ?? .init()
            state.failedSegmentIDs.removeAll()
            state.finalizedSegmentIDs.removeAll()
            state.scheduledSegmentIDs.removeAll()
            state.summary = nil
            currentPageTranslation = state

            lastSegments = segs
            lastStreamPayloads = []
            translationProgress = segs.isEmpty ? 1.0 : 0.0
            failedSegmentIDs = []

            replacer.restore(using: exec)
            replacer.setPairs([], using: exec)

            if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
                coord.resetMarks()
                for segment in segs {
                    await coord.markSegments([(id: segment.id, text: segment.originalText)])
                }
            }

            let opts = TranslationOptions()
// <<<<<<< codex/refactor-starttranslate-for-new-streaming-api
//             let summary = try await router.translateStream(
//                 segments: segs,
//                 options: opts,
//                 preferredEngine: engine
//             ) { [weak self, weak webView] event in
//                 guard let self else { return }
//                 Task { @MainActor [weak self] in
//                     guard let self, let webView = webView else { return }
//                     if Task.isCancelled { return }
//                     await self.handleStreamEvent(
//                         event,
//                         engine: engine,
//                         url: url,
//                         webView,
//                         exec: exec,
//                         requestID: requestID
//                     )
// =======
            do {
                let results = try await router.translate(
                    segments: segs,
                    options: opts,
                    preferredEngine: settings.preferredEngine
                )
                let pairs: [(original: String, translated: String)] =
                    zip(segs, results).compactMap { seg, res in
                        guard !res.text.isEmpty else { return nil }
                        return (seg.originalText, res.text)
                    }
                // 1) 페어 등록
                replacer.setPairs(pairs, using: exec, observer: .restart)
                // 2) 적용 + 옵저버 켜기(더 보기 등 동적 치환)
                replacer.apply(using: exec, observe: true)

                // 캐시
                self.lastSegments = segs
                self.lastResults = results
                if var state = self.currentPageTranslation, state.url == url {
                    state.segments = segs
                    state.resultsByEngine[engine] = results
                    self.currentPageTranslation = state
                } else {
                    self.currentPageTranslation = PageTranslationState(url: url, segments: segs, resultsByEngine: [engine: results])
// >>>>>>> streaming-translation-base
                }
            }

            if var updatedState = currentPageTranslation, updatedState.url == url, updatedState.summary == nil {
                updatedState.summary = summary
                updatedState.failedSegmentIDs.formUnion(summary.failedSegmentIDs)
                updatedState.finalizedSegmentIDs.formUnion(summary.succeededSegmentIDs)
                currentPageTranslation = updatedState
                failedSegmentIDs = updatedState.failedSegmentIDs
                updateProgress(for: engine)
            }
        } catch {
            if error is CancellationError { return }
            print("translate error: \(error)")
            let exec = WKWebViewScriptAdapter(webView: webView)
            replacer.restore(using: exec)
            _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();") // 선택 강조 초기화
        }
    }
    
    /// Docs/streaming-translation-contract.md 의 이벤트 순서를 따른다.
    private func handleStreamEvent(
        _ event: TranslationStreamEvent,
        engine: EngineTag,
        url: URL,
        _ webView: WKWebView,
        exec: WebViewScriptExecutor,
        requestID: UUID
    ) async {
        if Task.isCancelled { return }
        guard activeTranslationID == requestID else { return }

        switch event.kind {
        case .cachedHit:
            if let payload = event.payload {
                await applyStreamPayload(
                    payload,
                    engine: engine,
                    isFinal: true,
                    exec: exec,
                    highlight: true,
                    url: url
                )
            }
        case .requestScheduled:
            if let segmentID = event.segmentID,
               var state = currentPageTranslation,
               state.url == url {
                state.scheduledSegmentIDs.insert(segmentID)
                currentPageTranslation = state
                updateProgress(for: engine)
            }
        case .partial:
            if let payload = event.payload {
                await applyStreamPayload(
                    payload,
                    engine: engine,
                    isFinal: false,
                    exec: exec,
                    highlight: false,
                    url: url
                )
            }
        case .final:
            if let payload = event.payload {
                await applyStreamPayload(
                    payload,
                    engine: engine,
                    isFinal: true,
                    exec: exec,
                    highlight: true,
                    url: url
                )
            }
        case .failed:
            if let segmentID = event.segmentID,
               var state = currentPageTranslation,
               state.url == url {
                state.failedSegmentIDs.insert(segmentID)
                state.finalizedSegmentIDs.remove(segmentID)
                state.scheduledSegmentIDs.remove(segmentID)
                currentPageTranslation = state
                failedSegmentIDs = state.failedSegmentIDs
                // TODO: 실패 세그먼트용 오류 오버레이 연동
                updateProgress(for: engine)
            }
        case .completed:
            if let summary = event.summary,
               var state = currentPageTranslation,
               state.url == url {
                state.summary = summary
                state.failedSegmentIDs.formUnion(summary.failedSegmentIDs)
                state.finalizedSegmentIDs.formUnion(summary.succeededSegmentIDs)
                state.scheduledSegmentIDs.subtract(summary.failedSegmentIDs)
                state.scheduledSegmentIDs.subtract(summary.succeededSegmentIDs)
                currentPageTranslation = state
                failedSegmentIDs = state.failedSegmentIDs
                updateProgress(for: engine)
            }
        }
    }

    private func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engine: EngineTag,
        isFinal: Bool,
        exec: WebViewScriptExecutor,
        highlight: Bool,
        url: URL
    ) async {
        guard var state = currentPageTranslation, state.url == url else { return }
        var buffer = state.buffersByEngine[engine] ?? .init()
        buffer.upsert(payload)
        state.buffersByEngine[engine] = buffer
        if isFinal {
            state.finalizedSegmentIDs.insert(payload.segmentID)
            state.failedSegmentIDs.remove(payload.segmentID)
            state.scheduledSegmentIDs.remove(payload.segmentID)
        }
        currentPageTranslation = state

        lastStreamPayloads = buffer.ordered
        failedSegmentIDs = state.failedSegmentIDs
        updateProgress(for: engine)

        guard payload.translatedText.isEmpty == false else { return }
        replacer.upsert(
            payload: payload,
            using: exec,
            applyImmediately: true,
            highlight: highlight
        )
    }

    private func updateProgress(for engine: EngineTag) {
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

    private func normalizePageScale(_ webView: WKWebView) {
        // iOS 16+ WKWebView.pageZoom이 있으면 우선 적용
        if webView.responds(to: #selector(getter: WKWebView.pageZoom)) {
            webView.pageZoom = 1.0
        }
        // 방어적으로 ScrollView 배율도 초기화
        webView.scrollView.setZoomScale(1.0, animated: false)
    }
    
    /// UI의 showOriginal 변경을 이 함수로 처리
    @MainActor
    func onShowOriginalChanged(_ showOriginal: Bool) {
        guard let webView = attachedWebView else { return }
        let exec = WKWebViewScriptAdapter(webView: webView)
        if showOriginal {
            // 원문보기 ON → 치환 전부 복원
            cancelActiveTranslation()
            replacer.restore(using: exec)
            closeOverlay()
        } else {
            let engine = settings.preferredEngine
            if applyCachedTranslationIfAvailable(for: engine, on: webView) == false {
                requestTranslation(on: webView)
            }
        }
    }

    func willNavigate() {
        guard let webView = attachedWebView else { return }
        cancelActiveTranslation()
        let exec = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: exec)
        if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
            coord.resetMarks()
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
        if applyCachedTranslationIfAvailable(for: engine, on: webView) == false {
            requestTranslation(on: webView)
        }
    }

    @discardableResult
    private func applyCachedTranslationIfAvailable(for engine: EngineTag, on webView: WKWebView) -> Bool {
        guard let url = webView.url,
              let state = currentPageTranslation,
              state.url == url,
              let buffer = state.buffersByEngine[engine],
              buffer.ordered.isEmpty == false else { return false }

        let exec = WKWebViewScriptAdapter(webView: webView)
        let pairs = buffer.ordered.compactMap { payload -> (String, String)? in
            guard payload.translatedText.isEmpty == false else { return nil }
            return (payload.originalText, payload.translatedText)
        }
        replacer.setPairs(pairs, using: exec, observer: .restart)
        replacer.apply(using: exec, observe: true)
        lastSegments = state.segments
        lastStreamPayloads = buffer.ordered
        var updatedState = state
        updatedState.finalizedSegmentIDs.formUnion(buffer.segmentIDs)
        updatedState.scheduledSegmentIDs.subtract(buffer.segmentIDs)
        currentPageTranslation = updatedState
        failedSegmentIDs = updatedState.failedSegmentIDs
        updateProgress(for: engine)
        hasAttemptedTranslationForCurrentPage = true

        if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
            coord.resetMarks()
            Task { @MainActor in
                for segment in state.segments {
                    await coord.markSegments([(id: segment.id, text: segment.originalText)])
                }
            }
        }

        return true
    }

    func closeOverlay() {
        overlayState = nil
        selectedSegment = nil
        pendingImproved = nil
        clearSelectionHighlight()
    }

    func clearSelectionHighlight() {
        guard let webView = attachedWebView else { return }
        Task { @MainActor in
            let exec = WKWebViewScriptAdapter(webView: webView)
            _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
        }
    }
}

extension BrowserViewModel {
    private struct PageTranslationState {
        var url: URL
        var segments: [Segment]
        var totalSegments: Int
        var buffersByEngine: [EngineTag: StreamBuffer]
        var failedSegmentIDs: Set<String>
        var finalizedSegmentIDs: Set<String>
        var scheduledSegmentIDs: Set<String>
        var summary: TranslationStreamSummary?

        init(url: URL, segments: [Segment]) {
            self.url = url
            self.segments = segments
            self.totalSegments = segments.count
            self.buffersByEngine = [:]
            self.failedSegmentIDs = []
            self.finalizedSegmentIDs = []
            self.scheduledSegmentIDs = []
            self.summary = nil
        }
    }

    struct StreamBuffer {
        private(set) var ordered: [TranslationStreamPayload] = []

        mutating func upsert(_ payload: TranslationStreamPayload) {
            if let index = ordered.firstIndex(where: { $0.segmentID == payload.segmentID }) {
                ordered[index] = payload
            } else {
                ordered.append(payload)
            }
            ordered.sort { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.segmentID < rhs.segmentID
                }
                return lhs.sequence < rhs.sequence
            }
        }

        var segmentIDs: Set<String> { Set(ordered.map { $0.segmentID }) }
    }

    struct OverlayState: Equatable {
        var segmentID: String
        var selectedText: String
        var improvedText: String?
        var anchor: CGRect
    }
}
