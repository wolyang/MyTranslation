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
    /// 오버레이 패널의 화면 내 위치입니다.
    @State private var overlayPanelFrame: CGRect = .null
    /// 오버레이 → Glossary 추가 시트를 제어합니다.
    @State private var isTermPickerPresented: Bool = false
    /// TermPicker에서 표시할 전체 용어 목록입니다.
    @State private var termPickerItems: [TermPickerItem] = []
    /// 시트에서 선택한 텍스트(variants) 보관용입니다.
    @State private var pendingVariantText: String? = nil
    /// TermEditorView를 풀스크린으로 노출하기 위한 뷰모델입니다.
    @State private var activeTermEditorViewModel: TermEditorViewModel? = nil
    /// TermPicker가 닫힌 뒤 열릴 TermEditorViewModel 임시 저장소입니다.
    @State private var pendingTermEditorViewModel: TermEditorViewModel? = nil
    /// Glossary 추가 관련 오류 메시지입니다.
    @State private var glossaryErrorMessage: String? = nil

    init(container: AppContainer) {
        _vm = StateObject(
            wrappedValue: BrowserViewModel(
                extractor: WKContentExtractor(),
                router: container.router,
                cache: container.cache,
                replacer: WebViewInlineReplacer(),
//                fmQuery: container.fmQuery,
                settings: container.settings
            )
        )
    }

    /// 브라우저를 루트 화면으로 구성하고 용어집/설정을 시트로 연결합니다.
    var body: some View {
        content
            .fullScreenCover(isPresented: $isGlossaryPresented) {
                GlossaryHost(modelContext: modelContext)
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
            .sheet(item: $vm.glossaryAddSheet) { sheetState in
                GlossaryAddSheet(
                    state: sheetState,
                    onAddNew: { openTermEditor(from: sheetState) },
                    onAppendToExisting: { prepareTermPicker(for: sheetState) },
                    onAppendCandidate: { key in
                        openExistingTerm(key: key, variant: sheetState.selectedText)
                    },
                    onEditExisting: { key in openExistingTerm(key: key) },
                    onCancel: {
                        pendingVariantText = nil
                        vm.glossaryAddSheet = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(
                isPresented: $isTermPickerPresented,
                onDismiss: {
                    if let pending = pendingTermEditorViewModel {
                        pendingTermEditorViewModel = nil
                        activeTermEditorViewModel = pending
                    } else {
                    }
                },
                content: {
                    TermPickerSheet(terms: termPickerItems) { termKey in
                        appendVariant(to: termKey)
                    }
                    .presentationDetents([.medium, .large])
                }
            )
            .fullScreenCover(isPresented: Binding(get: { activeTermEditorViewModel != nil }, set: { if !$0 { activeTermEditorViewModel = nil } })) {
                if let editorVM = activeTermEditorViewModel {
                    TermEditorView(viewModel: editorVM)
                }
            }
            .alert("오류", isPresented: Binding(get: { glossaryErrorMessage != nil }, set: { if !$0 { glossaryErrorMessage = nil } })) {
                Button("확인", role: .cancel) { glossaryErrorMessage = nil }
            } message: {
                Text(glossaryErrorMessage ?? "")
            }
//            .task {
//                // 앱 시작 후 한 번 시드 시도
//                GlossarySeeder.seedIfNeeded(modelContext)
//            }
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
                sourceLanguage: .init(get: { vm.languagePreference.source }, set: { _ in }),
                targetLanguage: .init(get: { vm.languagePreference.target }, set: { _ in }),
                currentPageURLString: vm.currentPageURLString,
                onGo: { url in
                    vm.load(urlString: url)
                    triggerTranslationSession()
                },
                onRefresh: { url in
                    vm.refreshAndReload(urlString: url)
                    triggerTranslationSession()
                },
                onSelectEngine: { engine, wasShowingOriginal in
                    vm.onEngineSelected(engine, wasShowingOriginal: wasShowingOriginal)
                },
                onSelectSourceLanguage: { selection in
                    vm.updateSourceLanguage(selection, triggeredByUser: true)
                },
                onSelectTargetLanguage: { language in
                    vm.updateTargetLanguage(language, triggeredByUser: true)
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
                    onNavigate: { vm.willNavigate() },
                    onUserInteraction: {
                        if vm.overlayState != nil {
                            vm.closeOverlay()
                        }
                    }
                )
                if let overlayState = vm.overlayState {
                    OverlayPanelContainer(
                        state: overlayState,
                        onAsk: { Task { await vm.askAIForSelected() } },
                        onClose: { vm.closeOverlay() },
                        onAddToGlossary: { text, range, section in
                            vm.onGlossaryAddRequested(selectedText: text, selectedRange: range, section: section)
                        },
                        onFrameChange: { frame in overlayPanelFrame = frame }
                    )
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        handleOverlayDismissAttempt(at: value.startLocation)
                    },
                including: .all
            )
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
        .onChange(of: vm.languagePreference) { _, _ in
            updateTranslationSessionConfiguration()
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
            updateTranslationSessionConfiguration()
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

    private func updateTranslationSessionConfiguration() {
        trConfig?.invalidate()
        let sourceIdentifier = vm.languagePreference.source.effectiveLanguage.code
        let targetIdentifier = vm.languagePreference.target.code
        trConfig = TranslationSession.Configuration(
            source: .init(identifier: sourceIdentifier),
            target: .init(identifier: targetIdentifier)
        )
    }

    private func handleOverlayDismissAttempt(at location: CGPoint) {
        guard vm.overlayState != nil else { return }
        if overlayPanelFrame.isNull == false && overlayPanelFrame.isEmpty == false && overlayPanelFrame.contains(location) {
            return
        }
        vm.closeOverlay()
    }

    private func handleFavorite(_ link: UserSettings.FavoriteLink) {
        /// 즐겨찾기에서 선택한 URL을 로드하고 번역 스트림을 이어갑니다.
        vm.load(urlString: link.url)
        triggerTranslationSession()
    }

    private func openTermEditor(from state: GlossaryAddSheetState) {
        do {
            let editor = try TermEditorViewModel(context: modelContext, termID: nil, patternID: nil)
            let trimmed = state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch state.selectionKind {
            case .original:
                editor.generalDraft.sourcesOK = trimmed
            case .translated:
                editor.generalDraft.variants = trimmed
            }
            activeTermEditorViewModel = editor
            vm.glossaryAddSheet = nil
        } catch {
            glossaryErrorMessage = error.localizedDescription
        }
    }

    private func prepareTermPicker(for state: GlossaryAddSheetState) {
        pendingVariantText = state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let tempVM = try TermEditorViewModel(context: modelContext, termID: nil, patternID: nil)
            termPickerItems = try tempVM.fetchAllTermsForPicker()
            vm.glossaryAddSheet = nil
            isTermPickerPresented = true
        } catch {
            glossaryErrorMessage = error.localizedDescription
        }
    }

    private func appendVariant(to termKey: String) {
        guard let variant = pendingVariantText?.trimmingCharacters(in: .whitespacesAndNewlines),
              variant.isEmpty == false else {
            return
        }
        do {
            let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.key == termKey }
            var descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: predicate)
            descriptor.includePendingChanges = true
            if let term = try modelContext.fetch(descriptor).first {
                Log.info("term: \(term)")
                let editor = try TermEditorViewModel(context: modelContext, termID: term.persistentModelID, patternID: nil)
                var variants = term.variants
                if variants.contains(variant) == false {
                    variants.append(variant)
                }
                editor.generalDraft.variants = variants.joined(separator: ";")
                vm.glossaryAddSheet = nil
                pendingVariantText = nil
                pendingTermEditorViewModel = editor
                isTermPickerPresented = false
            }
        } catch {
            Log.error(error.localizedDescription)
            glossaryErrorMessage = error.localizedDescription
        }
    }

    private func openExistingTerm(key: String, variant: String? = nil) {
        do {
            let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.key == key }
            var descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: predicate)
            descriptor.includePendingChanges = true
            guard let term = try modelContext.fetch(descriptor).first else {
                glossaryErrorMessage = "선택한 용어를 찾을 수 없습니다."
                return
            }
            let editor = try TermEditorViewModel(context: modelContext, termID: term.persistentModelID, patternID: nil)
            if let variant = variant?.trimmingCharacters(in: .whitespacesAndNewlines), variant.isEmpty == false {
                var list = editor.generalDraft.variants.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if list.contains(variant) == false {
                    list.append(variant)
                }
                editor.generalDraft.variants = list.joined(separator: ";")
            }
            pendingVariantText = nil
            pendingTermEditorViewModel = nil
            vm.glossaryAddSheet = nil
            isTermPickerPresented = false
            activeTermEditorViewModel = editor
        } catch {
            glossaryErrorMessage = error.localizedDescription
        }
    }
}
