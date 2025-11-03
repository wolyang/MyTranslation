// File: BrowserRootView.swift
import SwiftUI
import SwiftData
import Translation

struct BrowserRootView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @StateObject private var vm: BrowserViewModel
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue

    /// 현재 웹뷰에 연결된 번역 세션을 유지·무효화하는 설정 객체입니다.
    @State private var trConfig: TranslationSession.Configuration? = nil

    /// iPhone 사이즈에서 더보기 메뉴를 시트로 띄울지 여부입니다.
    @State private var isMorePresented: Bool = false
    /// Glossary 시트 노출 여부입니다.
    @State private var isGlossaryPresented: Bool = false
    /// 설정 화면 노출 여부입니다.
    @State private var isSettingsPresented: Bool = false
    /// 즐겨찾기 관리 화면 노출 여부입니다.
    @State private var isFavoritesManagerPresented: Bool = false

    init(container: AppContainer) {
        _vm = StateObject(
            wrappedValue: BrowserViewModel(
                extractor: WKContentExtractor(),
                router: container.router,
                replacer: WebViewInlineReplacer(),
//                fmQuery: container.fmQuery,
                settings: container.settings
            )
        )
    }

    /// 브라우저를 루트 화면으로 구성하고 용어집/설정을 시트로 연결합니다.
    var body: some View {
        content
            .sheet(isPresented: $isGlossaryPresented) {
                GlossaryHost(modelContext: modelContext)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
            }
            .sheet(isPresented: $isFavoritesManagerPresented) {
                NavigationStack {
                    FavoritesManagerView(
                        favorites: vm.favoriteLinks,
                        onSelectFavorite: { link in
                            isFavoritesManagerPresented = false
                            handleFavorite(link)
                        },
                        onUpdateFavorite: { favorite, title, url in
                            vm.updateFavorite(favorite, title: title, url: url)
                        },
                        onDeleteFavorites: { offsets in
                            vm.removeFavorites(at: offsets)
                        },
                        onMoveFavorites: { offsets, destination in
                            vm.moveFavorites(from: offsets, to: destination)
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기") { isFavoritesManagerPresented = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .task {
                // 앱 시작 후 한 번 시드 시도
                GlossarySeeder.seedIfNeeded(modelContext)
            }
    }

    /// 화면 크기에 따라 iPad는 사이드바, iPhone은 시트를 구성하는 컨테이너 뷰입니다.
    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                MoreSidebarView(
                    favorites: vm.favoriteLinks,
                    onSelectFavorite: handleFavorite(_:),
                    onAddFavorite: { vm.addCurrentPageToFavorites() },
                    onManageFavorites: { isFavoritesManagerPresented = true },
                    onOpenGlossary: { isGlossaryPresented = true },
                    onOpenSettings: { isSettingsPresented = true }
                )
            } detail: {
                NavigationStack {
                    browserScene
                }
            }
        } else {
            NavigationStack {
                browserScene
            }
            .sheet(isPresented: $isMorePresented) {
                MoreMenuView(
                    favorites: vm.favoriteLinks,
                    onSelectFavorite: { link in
                        isMorePresented = false
                        handleFavorite(link)
                    },
                    onAddFavorite: {
                        let isNew = vm.addCurrentPageToFavorites()
                        return isNew
                    },
                    onUpdateFavorite: { favorite, title, url in
                        vm.updateFavorite(favorite, title: title, url: url)
                    },
                    onDeleteFavorites: { offsets in
                        vm.removeFavorites(at: offsets)
                    },
                    onMoveFavorites: { offsets, destination in
                        vm.moveFavorites(from: offsets, to: destination)
                    },
                    onOpenGlossary: {
                        isMorePresented = false
                        isGlossaryPresented = true
                    },
                    onOpenSettings: {
                        isMorePresented = false
                        isSettingsPresented = true
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var preferredEngineBinding: Binding<EngineTag> {
        /// URL 바에서 선택된 번역 엔진과 `AppStorage` 값을 동기화합니다.
        Binding(
            get: { EngineTag(rawValue: preferredEngineRawValue) ?? .afm },
            set: { preferredEngineRawValue = $0.rawValue }
        )
    }

    private var browserScene: some View {
        /// 브라우저 웹뷰와 각종 컨트롤을 묶은 본문 뷰입니다.
        VStack(spacing: 12) {
            URLBarView(
                urlString: $vm.urlString,
                selectedEngine: preferredEngineBinding,
                showOriginal: $vm.showOriginal,
                isEditing: $vm.isEditingURL,
                isTranslating: $vm.isTranslating,
                currentPageURLString: vm.currentPageURLString,
                onGo: { url in
                    vm.load(urlString: url)
                    triggerTranslationSession()
                },
                onSelectEngine: { engine, wasShowingOriginal in
                    vm.onEngineSelected(engine, wasShowingOriginal: wasShowingOriginal)
                },
                onTapMore: horizontalSizeClass == .regular ? nil : { isMorePresented = true }
            )
            .padding(.horizontal, 16)

            ZStack(alignment: .topLeading) {
                WebContainerView(
                    request: vm.request,
                    onAttach: { webView in vm.attachWebView(webView) },
                    onDidFinish: { webView, url in
                        vm.onWebViewDidFinishLoad(webView, url: url)
                    },
                    onSelectSegment: { sid, anchor in
                        Task {
                            await vm.onSegmentSelected(id: sid, anchor: anchor)
                        }
                    },
                    onNavigate: { vm.willNavigate() }
                )
                if let overlayState = vm.overlayState {
                    OverlayPanelContainer(
                        state: overlayState,
                        onAsk: { Task { await vm.askAIForSelected() } },
                        onClose: { vm.closeOverlay() }
                    )
                }
            }
        }
        .onAppear {
            ensureTranslationSession()
            if vm.urlString.isEmpty == false {
                vm.load(urlString: vm.urlString)
                triggerTranslationSession()
            }
        }
        .onChange(of: vm.showOriginal) { _, newValue in
            vm.onShowOriginalChanged(newValue)
        }
        .onChange(of: preferredEngineRawValue) { _, newValue in
            let engine = EngineTag(rawValue: newValue) ?? .afm
            vm.settings.preferredEngine = engine
        }
        // TranslationSession을 컨테이너 서비스에 연결
        .translationTask(trConfig) { session in
            // (선택) 사전 준비: 모델 다운로드/권한 UX 향상
            // try? await session.prepareTranslation()
            container.attachAFMSession(session)
        }
    }

    private func ensureTranslationSession() {
        /// 초기 진입 시 번역 세션 구성을 준비합니다.
        if trConfig == nil {
            trConfig = TranslationSession.Configuration(
                source: .init(identifier: "zh-Hans"),
                target: .init(identifier: "ko")
            )
        }
    }

    private func triggerTranslationSession() {
        /// 웹뷰 로드가 반복될 때마다 세션을 무효화하여 새 번역을 시작합니다.
        if trConfig == nil {
            ensureTranslationSession()
        } else {
            trConfig?.invalidate()
        }
    }

    private func handleFavorite(_ link: UserSettings.FavoriteLink) {
        /// 즐겨찾기에서 선택한 URL을 로드하고 번역 스트림을 이어갑니다.
        vm.load(urlString: link.url)
        triggerTranslationSession()
    }
}
