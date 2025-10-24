import Foundation
import CoreGraphics
import WebKit

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var urlString: String
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

    @Published var request: URLRequest? = nil
    @Published var currentPageURLString: String = ""
    @Published var pendingAutoTranslateID: UUID? = nil
    @Published var overlayState: OverlayState?
    @Published var fmPanel: FMAnswer?
    @Published var translateRunID: String = ""
    @Published var translationProgress: Double = 0
    @Published var failedSegmentIDs: Set<String> = []

    weak var attachedWebView: WKWebView?
    var currentURL: URL? { URL(string: urlString) }

    var lastSegments: [Segment] = []
    var lastStreamPayloads: [TranslationStreamPayload] = []

    var pendingURLAfterEditing: String?
    var currentPageTranslation: PageTranslationState?
    var translationTask: Task<Void, Never>? = nil
    var activeTranslationID: UUID?
    var hasAttemptedTranslationForCurrentPage = false
    var noBodyTextRetryCount = 0
    var autoTranslateTask: Task<Void, Never>? = nil
    var selectedSegment: Segment?
    var pendingImproved: String?
    var overlayTranslationTasks: [String: Task<Void, Never>] = [:]
    var isStartingTranslation = false

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
        pendingAutoTranslateID = nil
        autoTranslateTask?.cancel()
        autoTranslateTask = nil
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
            title: "AO3 – 특정 작품",
            url: "https://archiveofourown.org/works/71109986?view_adult=true"
        ),
        .init(
            title: "AO3 – Jugglus Juggler 태그",
            url: "https://archiveofourown.org/tags/Jugglus%20Juggler%20%7C%20Hebikura%20Shota*s*Kurenai%20Gai/works"
        ),
        .init(
            title: "나카자키 Lofter",
            url: "https://nakazaki.lofter.com/post/1ea19791_2bfbab779?incantation=rzRAnYWzp157"
        )
    ]
}
