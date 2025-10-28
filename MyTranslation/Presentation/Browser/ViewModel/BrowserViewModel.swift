import Foundation
import CoreGraphics
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {
    // 주소바에 표시되는 URL
    @Published var urlString: String
    
    // ProgressView 노출 여부
    @Published var isTranslating: Bool = false
    
    // 원문 보기 중인지 저장
    @Published var showOriginal: Bool = false
    
    // 사용자가 주소바의 URL을 편집중인지 여부
    @Published var isEditingURL: Bool = false {
        didSet {
            // 편집 종료 시,만약 편집중에 새 웹페이지가 로딩되어 편집 종료 후 기존의 url이 아닌 새 url을 보여줘야 할 경우
            if isEditingURL == false, let pendingURLAfterEditing {
                urlString = pendingURLAfterEditing
                self.pendingURLAfterEditing = nil
            }
        }
    }

    @Published var request: URLRequest? = nil
    var currentPageURLString: String {
        currentPageTranslation?.url.absoluteString ?? attachedWebView?.url?.absoluteString ?? urlString
    }
    @Published var overlayState: OverlayState?
    @Published var translateRunID: String = ""
    @Published var translationProgress: Double = 0
    @Published var failedSegmentIDs: Set<String> = []

    weak var attachedWebView: WKWebView?
    var currentURL: URL? { URL(string: urlString) }

    var lastSegments: [Segment] = []
    var lastStreamPayloads: [TranslationStreamPayload] = []
    
    // 주소바 편집 중 새 페이지가 로딩된 경우, 이동 없이 편집 종료 시에 주소바에 노출되는 주소를 새 페이지의 url로 복구하기 위한 값
    var pendingURLAfterEditing: String?
    
    // 현재 페이지의 세그먼트 추출/번역 상태 저장 객체
    var currentPageTranslation: PageTranslationState?
    
    //
    var translationTask: Task<Void, Never>? = nil
    var activeTranslationID: UUID?
    var noBodyTextRetryCount = 0
    var selectedSegment: Segment?
    var overlayTranslationTasks: [String: Task<Void, Never>] = [:]

    let presetLinks: [PresetLink]

    let extractor: ContentExtractor
    let router: TranslationRouter
    let replacer: InlineReplacer
    let settings: UserSettings
//    let overlay: OverlayRenderer
//    let fmQuery: FMQueryService

    init(
        extractor: ContentExtractor = WKContentExtractor(),
        router: TranslationRouter,
        replacer: InlineReplacer,
//        fmQuery: FMQueryService,
        settings: UserSettings,
        presetLinks: [PresetLink]? = nil
    ) {
        let resolvedPresetLinks = presetLinks ?? Self.defaultPresetLinks
        self.presetLinks = resolvedPresetLinks
        self._urlString = Published(initialValue: resolvedPresetLinks.first?.url ?? "")
        self.extractor = extractor
        self.router = router
        self.replacer = replacer
//        self.fmQuery = fmQuery
        self.settings = settings
    }

    func normalizedURL(from string: String) -> URL? {
        guard string.isEmpty == false else { return nil }
        if let url = URL(string: string), url.scheme != nil { return url }
        return URL(string: "https://" + string)
    }

    func load(urlString: String) {
        self.urlString = urlString
        guard var url = normalizedURL(from: urlString) else { return }

        if let current = attachedWebView?.url, current == url {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let existing = comps?.fragment ?? ""
            let token = existing.isEmpty ? "reload=\(timestamp)" : existing + "&reload=\(timestamp)"
            comps?.fragment = token
            url = comps?.url ?? url
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        self.request = request
        pendingURLAfterEditing = nil
    }

    func attachWebView(_ webView: WKWebView) {
        attachedWebView = webView
    }
}

extension BrowserViewModel {
    struct PresetLink: Identifiable, Equatable {
        let title: String
        let url: String

        var id: String { url }
    }

    static let defaultPresetLinks: [PresetLink] = [
        .init(
            title: "AO3 - 너무 긴 세그먼트",
            url: "https://archiveofourown.org/works/68882536"
        ),
        .init(
            title: "AO3 – 특정 작품",
            url: "https://archiveofourown.org/works/71109986?view_adult=true"
        ),
        .init(
            title: "AO3 – 가이쟈그 태그",
            url: "https://archiveofourown.org/tags/Jugglus%20Juggler%20%7C%20Hebikura%20Shota*s*Kurenai%20Gai/works"
        ),
        .init(
            title: "나카자키 Lofter",
            url: "https://nakazaki.lofter.com/post/1ea19791_2bfbab779?incantation=rzRAnYWzp157"
        )
    ]
}
