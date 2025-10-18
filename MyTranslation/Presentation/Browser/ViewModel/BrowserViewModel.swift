// File: BrowserViewModel.swift
import Foundation
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var urlString: String = /*"https://nakazaki.lofter.com/post/1ea19791_2bfbab779?incantation=rzRAnYWzp157"*/"https://archiveofourown.org/tags/Jugglus%20Juggler%20%7C%20Hebikura%20Shota*s*Kurenai%20Gai/works" // 개발 중 편의를 위한 임시 url 입력

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

    private let container: AppContainer
    let extractor: ContentExtractor
    private let router: TranslationRouter
//    let overlay: OverlayRenderer
    let replacer: InlineReplacer
    
    @Published var fmPanel: FMAnswer?
    
    let fmQuery: FMQueryService
    let settings: UserSettings
    
    private var selectedSegment: Segment?
    private var pendingImproved: String?
    
    @Published var translateRunID: String = ""

    init(
        container: AppContainer,
        extractor: ContentExtractor = WKContentExtractor(),
        router: TranslationRouter,
        replacer: InlineReplacer,
        fmQuery: FMQueryService,
        settings: UserSettings
    ) {
        self.container = container
        self.extractor = extractor
        self.router = router
        self.replacer = replacer
        self.fmQuery = fmQuery
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
    
    // WebContainerView.onSelectSegmentID 에 연결
    func onSegmentTapped(id: String) async {
        print("[onSegmentTapped] id: \(id)")
        guard let webView = attachedWebView, let seg = lastSegments.first(where: { $0.id == id }) else { return }
        self.selectedSegment = seg
        self.pendingImproved = nil

        // 하이라이트 표시
        let exec = WKWebViewScriptAdapter(webView: webView)
        _ = try? await exec.runJS(#"window.MT && MT.HILITE && MT.HILITE(\#(String(reflecting: id)));"#)
    }
    
    func askAIForSelected() async {
        guard settings.useFM else { return }
        guard let seg = selectedSegment else { return }
        let current = lastResults.first(where: { $0.segmentID == seg.id })?.text
        // 간단 문맥: ±1
        let para = lastSegments.filter { $0.url == seg.url }.sorted { $0.indexInPage < $1.indexInPage }
        let idx = para.firstIndex(where: { $0.id == seg.id }) ?? 0
        let prev = idx > 0 ? [para[idx - 1].originalText] : []
        let next = idx + 1 < para.count ? [para[idx + 1].originalText] : []
        do {
            let ans = try await fmQuery.ask(for: seg, currentTranslation: current, context: .init(previous: prev, next: next))
            self.pendingImproved = ans.improvedText
            if let web = attachedWebView,
               let coord = web.navigationDelegate as? WebContainerView.Coordinator
            {
                coord.showOverlay(selectedText: seg.originalText, improved: ans.improvedText)
            }
        } catch {
            print("FM ask failed: \(error)")
        }
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
            if var state = currentPageTranslation,
               var cached = state.resultsByEngine[previous.engine],
               let cachedIndex = cached.firstIndex(where: { $0.segmentID == seg.id }) {
                cached[cachedIndex] = updated
                state.resultsByEngine[previous.engine] = cached
                currentPageTranslation = state
            }
        }
        if let coord = web.navigationDelegate as? WebContainerView.Coordinator {
            coord.updateOverlay(improved: improved, anchor: nil)
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

    func startTranslate(on webView: WKWebView) async {
        guard let url = webView.url else { return }
        translateRunID = UUID().uuidString

        hasAttemptedTranslationForCurrentPage = true

        isTranslating = true
        defer {
            Task { @MainActor in
                self.normalizePageScale(webView)
                self.isTranslating = false
            }
        }
        do {
            let exec = WKWebViewScriptAdapter(webView: webView)
            let engine = settings.preferredEngine
            let segs: [Segment]
            if let state = currentPageTranslation, state.url == url {
                segs = state.segments
            } else {
                segs = try await extractor.extract(using: exec, url: url)
                currentPageTranslation = PageTranslationState(url: url, segments: segs, resultsByEngine: [:])
            }

            if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
                    let pairs = segs.map { (id: $0.id, text: $0.originalText) }
                    await coord.markSegments(pairs)
                }
            
            let opts = TranslationOptions()
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
                replacer.setPairs(pairs, using: exec)
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
                }
            } catch {
                print("translate error: \(error)")
                replacer.restore(using: exec)
                _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();") // 선택 강조 초기화
            }
        } catch {
            // 본문 추출 자체가 실패한 케이스(희귀)
            print("Extract error: \(error)")
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
            replacer.restore(using: exec)
        } else {
            let engine = settings.preferredEngine
            if applyCachedTranslationIfAvailable(for: engine, on: webView) == false {
                Task { await startTranslate(on: webView) }
            }
        }
    }

    func willNavigate() {
        guard let webView = attachedWebView else { return }
        let exec = WKWebViewScriptAdapter(webView: webView)
        replacer.restore(using: exec)
        Task { _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();") }
        request = nil
        hasAttemptedTranslationForCurrentPage = false
        pendingURLAfterEditing = nil
        currentPageTranslation = nil
    }

    func onEngineSelected(_ engine: EngineTag, wasShowingOriginal: Bool) {
        settings.preferredEngine = engine
        guard let webView = attachedWebView else { return }
        if wasShowingOriginal { return }
        if applyCachedTranslationIfAvailable(for: engine, on: webView) == false {
            Task { await self.startTranslate(on: webView) }
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
        let pairs = zip(state.segments, cachedResults).compactMap { seg, res -> (String, String)? in
            guard !res.text.isEmpty else { return nil }
            return (seg.originalText, res.text)
        }
        replacer.setPairs(pairs, using: exec)
        replacer.apply(using: exec, observe: true)
        lastSegments = state.segments
        lastResults = cachedResults
        hasAttemptedTranslationForCurrentPage = true

        if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
            let highlightPairs = state.segments.map { (id: $0.id, text: $0.originalText) }
            Task { await coord.markSegments(highlightPairs) }
        }

        return true
    }
}

extension BrowserViewModel {
    private struct PageTranslationState {
        var url: URL
        var segments: [Segment]
        var resultsByEngine: [EngineTag: [TranslationResult]]
    }
}
