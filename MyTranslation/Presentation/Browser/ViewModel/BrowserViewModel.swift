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
    /// NOTE: Docs/streaming-translation-contract.md 참고. InlineReplacer 와 동일한 payload 구조를 유지해야 한다.
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
        let engineID = lastStreamPayloads.first(where: { $0.segmentID == seg.id })?.engineID
            ?? settings.preferredEngine.rawValue
        let sequence = lastStreamPayloads.first(where: { $0.segmentID == seg.id })?.sequence
            ?? (lastStreamPayloads.count + 1)
        let payload = TranslationStreamPayload(
            segmentID: seg.id,
            originalText: seg.originalText,
            translatedText: improved,
            engineID: engineID,
            sequence: sequence
        )

        replacer.upsert(payload: payload, using: exec, applyImmediately: true, highlight: false)

        if var state = currentPageTranslation,
           let currentURL = web.url,
           currentURL == state.url {
            var buffer = state.buffersByEngine[engineID] ?? .init()
            buffer.upsert(payload)
            state.buffersByEngine[engineID] = buffer
            state.lastEngineID = engineID
            state.finalizedSegmentIDs.insert(seg.id)
            state.failedSegmentIDs.remove(seg.id)
            state.scheduledSegmentIDs.remove(seg.id)
            currentPageTranslation = state
            lastStreamPayloads = buffer.ordered
            failedSegmentIDs = state.failedSegmentIDs
            updateProgress(for: engineID)
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
            let engineTag = settings.preferredEngine
            let engineID = engineTag.rawValue
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
            state.buffersByEngine[engineID] = state.buffersByEngine[engineID] ?? .init()
            state.lastEngineID = engineID
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
            replacer.setPairs([], using: exec, observer: .restart)

            if let coord = webView.navigationDelegate as? WebContainerView.Coordinator {
                coord.resetMarks()
                for segment in segs {
                    await coord.markSegments([(id: segment.id, text: segment.originalText)])
                }
            }

            let opts = TranslationOptions()
            let summary = try await router.translateStream(
                segments: segs,
                options: opts,
                preferredEngine: engineID
            ) { [weak self, weak webView] event in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let webView = webView else { return }
                    if Task.isCancelled { return }
                    await self.handleStreamEvent(
                        event,
                        url: url,
                        exec: exec,
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
            let exec = WKWebViewScriptAdapter(webView: webView)
            replacer.restore(using: exec)
            _ = try? await exec.runJS("window.MT && MT.CLEAR && MT.CLEAR();") // 선택 강조 초기화
        }
    }
    
    /// Docs/streaming-translation-contract.md 의 이벤트 순서를 따른다.
    private func handleStreamEvent(
        _ event: TranslationStreamEvent,
        url: URL,
        exec: WebViewScriptExecutor,
        requestID: UUID
    ) async {
        if Task.isCancelled { return }
        guard activeTranslationID == requestID else { return }

        switch event.kind {
        case .cachedHit:
            // 캐시 히트는 summary 단계에서 누적 통계로 확인한다.
            break
        case .requestScheduled:
            break
        case let .partial(segment):
            await applyStreamPayload(
                segment,
                engineID: segment.engineID,
                isFinal: false,
                exec: exec,
                highlight: false,
                url: url
            )
        case let .final(segment):
            await applyStreamPayload(
                segment,
                engineID: segment.engineID,
                isFinal: true,
                exec: exec,
                highlight: true,
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

    private func applyStreamPayload(
        _ payload: TranslationStreamPayload,
        engineID: TranslationEngineID,
        isFinal: Bool,
        exec: WebViewScriptExecutor,
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
            using: exec,
            applyImmediately: true,
            highlight: highlight
        )
    }

    private func updateProgress(for engineID: TranslationEngineID) {
        _ = engineID
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
              let buffer = state.buffersByEngine[engine.rawValue],
              buffer.ordered.isEmpty == false else { return false }

        let exec = WKWebViewScriptAdapter(webView: webView)
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
        replacer.setPairs(payloads, using: exec, observer: .restart)
        replacer.apply(using: exec, observe: true)
        lastSegments = state.segments
        lastStreamPayloads = buffer.ordered
        var updatedState = state
        updatedState.finalizedSegmentIDs.formUnion(buffer.segmentIDs)
        updatedState.scheduledSegmentIDs.subtract(buffer.segmentIDs)
        updatedState.lastEngineID = engine.rawValue
        currentPageTranslation = updatedState
        failedSegmentIDs = updatedState.failedSegmentIDs
        updateProgress(for: engine.rawValue)
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
        var buffersByEngine: [TranslationEngineID: StreamBuffer]
        var failedSegmentIDs: Set<String>
        var finalizedSegmentIDs: Set<String>
        var scheduledSegmentIDs: Set<String>
        var summary: TranslationStreamSummary?
        var lastEngineID: TranslationEngineID?

        init(url: URL, segments: [Segment]) {
            self.url = url
            self.segments = segments
            self.totalSegments = segments.count
            self.buffersByEngine = [:]
            self.failedSegmentIDs = []
            self.finalizedSegmentIDs = []
            self.scheduledSegmentIDs = []
            self.summary = nil
            self.lastEngineID = nil
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
