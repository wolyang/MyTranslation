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
            // 편집 종료 시,만약 편집중에 새 웹페이지가 로딩되어 편집 종료 후 기존의 url이 아닌 새 url을 보여줘야 할 경우 값
            if isEditingURL == false, let pendingURLAfterEditing {
                urlString = pendingURLAfterEditing
                self.pendingURLAfterEditing = nil
            }
        }
    }

    @Published var request: URLRequest? = nil
    @Published var requestID: UUID = UUID()
    var currentPageURLString: String {
        currentPageTranslation?.url.absoluteString ?? attachedWebView?.url?.absoluteString ?? urlString
    }
    @Published var overlayState: OverlayState?
    @Published var glossaryAddSheet: GlossaryAddSheetState?
    @Published var translateRunID: String = ""
    @Published var translationProgress: Double = 0
    @Published var failedSegmentIDs: Set<String> = []
    @Published private(set) var favoriteLinks: [UserSettings.FavoriteLink]
    /// 현재 페이지에 적용 중인 출발/도착 언어 설정.
    @Published var languagePreference: PageLanguagePreference

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
    /// 페이지 URL별로 사용자가 선택한 언어를 기억해 동일 페이지 재방문 시 재사용한다.
    private var languagePreferenceByURL: [URL: PageLanguagePreference] = [:]

    let extractor: ContentExtractor
    let router: TranslationRouter
    let cache: CacheStore
    let replacer: InlineReplacer
    let settings: UserSettings
//    let overlay: OverlayRenderer
//    let fmQuery: FMQueryService

    init(
        extractor: ContentExtractor = WKContentExtractor(),
        router: TranslationRouter,
        cache: CacheStore,
        replacer: InlineReplacer,
//        fmQuery: FMQueryService,
        settings: UserSettings,
        initialURL: String? = nil,
        favoriteLinks: [UserSettings.FavoriteLink]? = nil
    ) {
        self.extractor = extractor
        self.router = router
        self.cache = cache
        self.replacer = replacer
//        self.fmQuery = fmQuery
        self.settings = settings

        let restoredURL = initialURL ?? settings.lastVisitedURL
        // 개발 중 하드코딩된 URL을 사용하려면 위 restoredURL 대입을 주석 처리하고 직접 초기 URL을 입력하세요.
        // let restoredURL = "https://example.com"
        self._urlString = Published(initialValue: restoredURL)

        let resolvedFavorites = favoriteLinks ?? settings.favoriteLinks
        self._favoriteLinks = Published(initialValue: resolvedFavorites)

        let defaultPreference = PageLanguagePreference(
            source: LanguageCatalog.defaultSourceSelection(),
            target: LanguageCatalog.defaultTargetLanguage()
        )

        if let initialURLString = initialURL, let url = URL(string: initialURLString) {
            languagePreferenceByURL[url] = defaultPreference
            self._languagePreference = Published(initialValue: defaultPreference)
        } else {
            self._languagePreference = Published(initialValue: defaultPreference)
        }
    }

    func normalizedURL(from string: String) -> URL? {
        guard string.isEmpty == false else { return nil }
        if let url = URL(string: string), url.scheme != nil { return url }
        return URL(string: "https://" + string)
    }

    /// 전달된 URL에 저장된 언어 선호를 반환하고, 없으면 기본값을 생성해 저장한다.
    func languagePreference(for url: URL) -> PageLanguagePreference {
        if let stored = languagePreferenceByURL[url] {
            return stored
        }
        let defaultPreference = PageLanguagePreference(
            source: LanguageCatalog.defaultSourceSelection(),
            target: LanguageCatalog.defaultTargetLanguage()
        )
        languagePreferenceByURL[url] = defaultPreference
        return defaultPreference
    }

    /// 현재 languagePreference를 전달된 URL에 매핑해 뷰 재구성 후에도 유지한다.
    func persistLanguagePreference(for url: URL) {
        languagePreferenceByURL[url] = languagePreference
    }

    /// 사용자가 출발 언어를 변경했을 때 상태를 갱신하고 필요 시 재번역한다.
    func updateSourceLanguage(_ selection: SourceLanguageSelection, triggeredByUser: Bool) {
        languagePreference.source = selection
        if let url = currentPageTranslation?.url {
            languagePreferenceByURL[url] = languagePreference
            currentPageTranslation?.languagePreference = languagePreference
        } else if let currentURL = attachedWebView?.url {
            languagePreferenceByURL[currentURL] = languagePreference
        }
        if triggeredByUser {
            resetTranslationStateForLanguageChange()
            retranslateCurrentPage()
        }
    }

    /// 사용자가 도착 언어를 변경했을 때 상태를 갱신하고 필요 시 재번역한다.
    func updateTargetLanguage(_ language: AppLanguage, triggeredByUser: Bool) {
        languagePreference.target = language
        if let url = currentPageTranslation?.url {
            languagePreferenceByURL[url] = languagePreference
            currentPageTranslation?.languagePreference = languagePreference
        } else if let currentURL = attachedWebView?.url {
            languagePreferenceByURL[currentURL] = languagePreference
        }
        if triggeredByUser {
            resetTranslationStateForLanguageChange()
            retranslateCurrentPage()
        }
    }

    /// 언어 변경 시 기존 번역/스트림 상태를 초기화한다.
    private func resetTranslationStateForLanguageChange() {
        currentPageTranslation?.buffersByEngine.removeAll()
        currentPageTranslation?.failedSegmentIDs.removeAll()
        currentPageTranslation?.finalizedSegmentIDs.removeAll()
        currentPageTranslation?.scheduledSegmentIDs.removeAll()
        currentPageTranslation?.summary = nil
        currentPageTranslation?.lastEngineID = nil
        failedSegmentIDs.removeAll()
        translationProgress = 0
        lastStreamPayloads = []
    }

    /// 현재 페이지가 보이는 경우 새 언어 설정으로 즉시 번역을 재요청한다.
    private func retranslateCurrentPage() {
        guard showOriginal == false, let webView = attachedWebView else { return }
        requestTranslation(on: webView)
    }

    func load(urlString: String) {
        self.urlString = urlString
        guard var url = normalizedURL(from: urlString) else {
            settings.lastVisitedURL = urlString
            return
        }

        let newRequestID = UUID()
        print("[VM] load(urlString:) creating request for: \(url.absoluteString) id=\(newRequestID)")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        self.request = request
        self.requestID = newRequestID
        pendingURLAfterEditing = nil
        settings.lastVisitedURL = url.absoluteString
    }

    func attachWebView(_ webView: WKWebView) {
        attachedWebView = webView
    }
}

extension BrowserViewModel {
    func addFavorite(title: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.isEmpty == false else { return }

        var favorites = favoriteLinks
        favorites.removeAll { $0.url.caseInsensitiveCompare(trimmedURL) == .orderedSame }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? trimmedURL : title
        favorites.insert(.init(title: resolvedTitle, url: trimmedURL), at: 0)
        favoriteLinks = favorites
        persistFavorites()
    }

    @discardableResult
    func addCurrentPageToFavorites() -> Bool {
        let trimmedURL = currentPageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.isEmpty == false else { return false }
        let pageTitle = attachedWebView?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = pageTitle.isEmpty ? trimmedURL : pageTitle
        let alreadyExists = favoriteLinks.contains { $0.url.caseInsensitiveCompare(trimmedURL) == .orderedSame }
        addFavorite(title: resolvedTitle, url: trimmedURL)
        return alreadyExists == false
    }

    func updateFavorite(_ favorite: UserSettings.FavoriteLink, title: String, url: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.isEmpty == false else { return }
        var favorites = favoriteLinks
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index] = .init(
            id: favorite.id,
            title: trimmedTitle.isEmpty ? trimmedURL : trimmedTitle,
            url: trimmedURL
        )
        // 중복 URL 제거
        favorites = favorites.enumerated().reduce(into: [UserSettings.FavoriteLink]()) { result, element in
            let item = element.element
            if result.contains(where: { $0.id != item.id && $0.url.caseInsensitiveCompare(item.url) == .orderedSame }) {
                if let existingIndex = result.firstIndex(where: { $0.url.caseInsensitiveCompare(item.url) == .orderedSame }) {
                    result[existingIndex] = item
                }
            } else {
                result.append(item)
            }
        }
        favoriteLinks = favorites
        persistFavorites()
    }

    func removeFavorites(at offsets: IndexSet) {
        var favorites = favoriteLinks
        favorites.remove(atOffsets: offsets)
        favoriteLinks = favorites
        persistFavorites()
    }

    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        var favorites = favoriteLinks
        favorites.move(fromOffsets: offsets, toOffset: destination)
        favoriteLinks = favorites
        persistFavorites()
    }

    private func persistFavorites() {
        settings.favoriteLinks = favoriteLinks
    }
}
