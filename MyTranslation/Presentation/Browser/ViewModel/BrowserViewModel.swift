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
    /// NOTE: TranslationStreamPayload 계약은 InlineReplacer와 동일하게 유지해야 합니다.
    private(set) var lastPayloads: [String: TranslationStreamPayload] = [:]
    private var pendingURLAfterEditing: String?
    private var currentPageTranslation: PageTranslationState?

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
        guard let seg = selectedSegment,
              let improved = pendingImproved,
              let web = attachedWebView else { return }
        let exec = WKWebViewScriptAdapter(webView: web)
        let engineID = settings.preferredEngine.rawValue
        let nextSequence = (lastPayloads[seg.id]?.sequence ?? 0) + 1
        let payload = TranslationStreamPayload(
            segmentID: seg.id,
            originalText: seg.originalText,
            translatedText: improved,
            engineID: engineID,
            sequence: nextSequence
        )
        replacer.upsert(payload: payload, using: exec, applyImmediately: true, highlight: true)
        lastPayloads[seg.id] = payload
        if var state = currentPageTranslation,
           (web.url == nil || state.url == web.url) {
            var enginePayloads = state.payloadsByEngine[engineID] ?? [:]
            enginePayloads[seg.id] = payload
            state.payloadsByEngine[engineID] = enginePayloads
            var failed = state.failedSegmentsByEngine[engineID] ?? Set<String>()
            failed.remove(seg.id)
            state.failedSegmentsByEngine[engineID] = failed
            currentPageTranslation = state
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

    func startTranslate(on webView: WKWebView) async {
        guard let url = webView.url else { return }
        translateRunID = UUID().uuidString

        closeOverlay()
        hasAttemptedTranslationForCurrentPage = true

        let engineID = settings.preferredEngine.rawValue

        isTranslating = true
        defer {
            Task { @MainActor in
                self.normalizePageScale(webView)
                self.isTranslating = false
            }
        }

        var streamFailures = Set<String>()
        do {
            let exec = WKWebViewScriptAdapter(webView: webView)
            let segs: [Segment]
            if let state = currentPageTranslation, state.url == url {
                segs = state.segments
            } else {
                segs = try await extractor.extract(using: exec, url: url)
                currentPageTranslation = PageTranslationState(
                    url: url,
                    segments: segs,
                    payloadsByEngine: [:],
                    failedSegmentsByEngine: [:]
                )
            }

            if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
                let pairs = segs.map { (id: $0.id, text: $0.originalText) }
                await coord.markSegments(pairs)
            }

            let opts = TranslationOptions()
            lastSegments = segs
            lastPayloads = [:]
            streamFailures.removeAll()

            if var state = currentPageTranslation, state.url == url {
                state.failedSegmentsByEngine[engineID] = Set<String>()
                currentPageTranslation = state
            }

            let currentRunID = translateRunID
            _ = try await router.translateStream(
                segments: segs,
                options: opts,
                preferredEngine: engineID,
                progress: { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.translateRunID == currentRunID,
                              let attached = self.attachedWebView,
                              attached === webView else { return }
                        switch event.kind {
                        case .cachedHit, .requestScheduled:
                            break
                        case let .partial(payload):
                            self.replacer.upsert(payload: payload, using: exec, applyImmediately: true, highlight: false)
                        case let .final(payload):
                            streamFailures.remove(payload.segmentID)
                            self.replacer.upsert(payload: payload, using: exec, applyImmediately: true, highlight: true)
                            let hasTranslation = (payload.translatedText?.isEmpty ?? true) == false
                            if hasTranslation {
                                self.lastPayloads[payload.segmentID] = payload
                            } else {
                                self.lastPayloads.removeValue(forKey: payload.segmentID)
                            }
                            if var state = self.currentPageTranslation, state.url == url {
                                var enginePayloads = state.payloadsByEngine[engineID] ?? [:]
                                if hasTranslation {
                                    enginePayloads[payload.segmentID] = payload
                                } else {
                                    enginePayloads.removeValue(forKey: payload.segmentID)
                                }
                                state.payloadsByEngine[engineID] = enginePayloads
                                var failed = state.failedSegmentsByEngine[engineID] ?? Set<String>()
                                failed.remove(payload.segmentID)
                                state.failedSegmentsByEngine[engineID] = failed
                                self.currentPageTranslation = state
                            }
                        case let .failed(segmentID, _):
                            streamFailures.insert(segmentID)
                            if var state = self.currentPageTranslation, state.url == url {
                                var failed = state.failedSegmentsByEngine[engineID] ?? Set<String>()
                                failed.insert(segmentID)
                                state.failedSegmentsByEngine[engineID] = failed
                                self.currentPageTranslation = state
                            }
                        case .completed:
                            break
                        }
                    }
                }
            )

            replacer.apply(using: exec, observe: true)

            if var state = currentPageTranslation, state.url == url {
                state.segments = segs
                state.payloadsByEngine[engineID] = lastPayloads
                state.failedSegmentsByEngine[engineID] = streamFailures
                currentPageTranslation = state
            } else {
                currentPageTranslation = PageTranslationState(
                    url: url,
                    segments: segs,
                    payloadsByEngine: [engineID: lastPayloads],
                    failedSegmentsByEngine: [engineID: streamFailures]
                )
            }
        } catch {
            print("translate error: \(error)")
            if var state = currentPageTranslation, state.url == url {
                state.failedSegmentsByEngine[engineID] = streamFailures
                currentPageTranslation = state
            }
            let exec = WKWebViewScriptAdapter(webView: webView)
            replacer.restore(using: exec)
            _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();")
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
            closeOverlay()
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
        request = nil
        hasAttemptedTranslationForCurrentPage = false
        closeOverlay()
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
              state.url == url else { return false }

        let engineID = engine.rawValue
        guard let cachedPayloads = state.payloadsByEngine[engineID],
              cachedPayloads.isEmpty == false else { return false }

        let payloads = cachedPayloads.values
            .filter { ($0.translatedText?.isEmpty ?? true) == false }
            .sorted { $0.sequence < $1.sequence }
        guard payloads.isEmpty == false else { return false }

        let exec = WKWebViewScriptAdapter(webView: webView)
        replacer.setPairs(payloads, using: exec, observer: .restart)
        replacer.apply(using: exec, observe: true)
        lastSegments = state.segments
        lastPayloads = cachedPayloads
        hasAttemptedTranslationForCurrentPage = true

        let highlightPairs = state.segments.map { (id: $0.id, text: $0.originalText) }
        Task { await (webView.navigationDelegate as? WebContainerView.Coordinator)?.markSegments(highlightPairs) }

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
        var payloadsByEngine: [TranslationEngineID: [String: TranslationStreamPayload]]
        var failedSegmentsByEngine: [TranslationEngineID: Set<String>]
    }

    struct OverlayState: Equatable {
        var segmentID: String
        var selectedText: String
        var improvedText: String?
        var anchor: CGRect
    }
}
