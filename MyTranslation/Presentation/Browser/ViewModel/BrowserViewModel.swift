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
    private(set) var lastResults: [TranslationResult] = []
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
//        let current = lastResults.first(where: { $0.segmentID == seg.id })?.text
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
        replacer.setPairs([(original: seg.originalText, translated: improved)], using: exec)
        replacer.apply(using: exec, observe: false)
        if let i = lastResults.firstIndex(where: { $0.segmentID == seg.id }) {
            let previous = lastResults[i]
            let updated = TranslationResult(
                id: previous.id, segmentID: seg.id,
                engine: previous.engine, text: improved,
                residualSourceRatio: previous.residualSourceRatio,
                createdAt: Date()
            )
            lastResults[i] = updated
            reorderLastResults()
            if var state = currentPageTranslation,
               var cached = state.resultsByEngine[previous.engine] {
                cached[seg.id] = updated
                state.resultsByEngine[previous.engine] = cached
                currentPageTranslation = state
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

            var state = currentPageTranslation ?? PageTranslationState(url: url, segments: [], resultsByEngine: [:])
            state.url = url
            state.segments = segs
            state.resultsByEngine[engine] = [:]
            currentPageTranslation = state

            lastSegments = []
            lastResults = []

            replacer.restore(using: exec)
            replacer.setPairs([], using: exec)

            if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
                coord.resetMarks()
            }

            let opts = TranslationOptions()
            let stream = router.translateStream(
                segments: segs,
                options: opts,
                preferredEngine: settings.preferredEngine
            )

            for try await event in stream {
                try Task.checkCancellation()
                guard activeTranslationID == requestID else { break }
                switch event {
                case .segments(let segments):
                    await handleSegmentsEvent(segments, engine: engine, url: url, webView: webView, requestID: requestID)
                case .result(let segment, let result):
                    handleResultEvent(segment: segment, result: result, engine: engine, exec: exec)
                case .finished:
                    break
                }
            }
        } catch {
            if error is CancellationError { return }
            print("translate error: \(error)")
            let exec = WKWebViewScriptAdapter(webView: webView)
            replacer.restore(using: exec)
            _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();") // 선택 강조 초기화
        }
    }
    
    private func handleSegmentsEvent(
        _ segments: [Segment],
        engine: EngineTag,
        url: URL,
        webView: WKWebView,
        requestID: UUID
    ) async {
        if Task.isCancelled { return }
        guard activeTranslationID == requestID else { return }
        lastSegments = segments

        if var state = currentPageTranslation, state.url == url {
            state.segments = segments
            if state.resultsByEngine[engine] == nil {
                state.resultsByEngine[engine] = [:]
            }
            currentPageTranslation = state
        } else {
            currentPageTranslation = PageTranslationState(url: url, segments: segments, resultsByEngine: [engine: [:]])
        }

        if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
            for segment in segments {
                if Task.isCancelled { return }
                guard activeTranslationID == requestID else { return }
                await coord.markSegments([(id: segment.id, text: segment.originalText)])
            }
        }
    }

    private func handleResultEvent(
        segment: Segment,
        result: TranslationResult,
        engine: EngineTag,
        exec: WebViewScriptExecutor
    ) {
        upsertResult(result, for: segment, engine: engine)
        guard result.text.isEmpty == false else { return }
        replacer.applyIncremental((segment.originalText, result.text), using: exec, observe: true)
    }

    private func upsertResult(_ result: TranslationResult, for segment: Segment, engine: EngineTag) {
        if let idx = lastResults.firstIndex(where: { $0.segmentID == result.segmentID }) {
            lastResults[idx] = result
        } else {
            lastResults.append(result)
        }
        reorderLastResults()

        if var state = currentPageTranslation {
            var engineCache = state.resultsByEngine[engine] ?? [:]
            engineCache[result.segmentID] = result
            state.resultsByEngine[engine] = engineCache
            currentPageTranslation = state
        }
    }

    private func reorderLastResults() {
        guard lastSegments.isEmpty == false else { return }
        let order = Dictionary(uniqueKeysWithValues: lastSegments.enumerated().map { ($1.id, $0) })
        lastResults.sort { lhs, rhs in
            let l = order[lhs.segmentID] ?? Int.max
            let r = order[rhs.segmentID] ?? Int.max
            if l == r { return lhs.segmentID < rhs.segmentID }
            return l < r
        }
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
        lastResults = []
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
              let cachedResults = state.resultsByEngine[engine],
              cachedResults.isEmpty == false else { return false }

        let exec = WKWebViewScriptAdapter(webView: webView)
        let pairs = state.segments.compactMap { seg -> (String, String)? in
            guard let res = cachedResults[seg.id], res.text.isEmpty == false else { return nil }
            return (seg.originalText, res.text)
        }
        replacer.setPairs(pairs, using: exec)
        replacer.apply(using: exec, observe: true)
        lastSegments = state.segments
        lastResults = state.segments.compactMap { cachedResults[$0.id] }
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
        var resultsByEngine: [EngineTag: [String: TranslationResult]]
    }

    struct OverlayState: Equatable {
        var segmentID: String
        var selectedText: String
        var improvedText: String?
        var anchor: CGRect
    }
}
