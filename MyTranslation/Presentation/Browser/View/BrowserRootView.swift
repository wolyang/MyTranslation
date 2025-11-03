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

    // TranslationSession 트리거
    @State private var trConfig: TranslationSession.Configuration? = nil

    @State private var isMorePresented: Bool = false
    @State private var isGlossaryPresented: Bool = false
    @State private var isSettingsPresented: Bool = false

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

    var body: some View {
        content
            .sheet(isPresented: $isGlossaryPresented) {
                GlossaryHost(modelContext: modelContext) // NEW
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView() // NEW
            }
            .task {
                // 앱 시작 후 한 번 시드 시도
                GlossarySeeder.seedIfNeeded(modelContext)
            }
    }

    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                MoreSidebarView( // NEW
                    favorites: vm.presetLinks,
                    onSelectFavorite: handleFavorite(_:),
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
                MoreMenuView( // NEW
                    favorites: vm.presetLinks,
                    onSelectFavorite: { link in
                        isMorePresented = false
                        handleFavorite(link)
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
        Binding(
            get: { EngineTag(rawValue: preferredEngineRawValue) ?? .afm },
            set: { preferredEngineRawValue = $0.rawValue }
        )
    }

    private var browserScene: some View {
        VStack(spacing: 12) {
            URLBarView(
                urlString: $vm.urlString,
                presetURLs: vm.presetLinks,
                selectedEngine: preferredEngineBinding,
                showOriginal: $vm.showOriginal,
                isEditing: $vm.isEditingURL,
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
                if vm.isTranslating {
                    ProgressView().padding(.top, 12)
                }
            }
        }
        .onAppear {
            ensureTranslationSession()
            // 아래 두 줄은 개발 중 편의를 위한 임시 코드
            vm.load(urlString: vm.urlString)
            triggerTranslationSession()
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
        if trConfig == nil {
            trConfig = TranslationSession.Configuration(
                source: .init(identifier: "zh-Hans"),
                target: .init(identifier: "ko")
            )
        }
    }

    private func triggerTranslationSession() {
        if trConfig == nil {
            ensureTranslationSession()
        } else {
            trConfig?.invalidate()
        }
    }

    private func handleFavorite(_ link: BrowserViewModel.PresetLink) {
        vm.load(urlString: link.url)
        triggerTranslationSession()
    }
}
