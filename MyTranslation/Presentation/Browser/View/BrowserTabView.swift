// MARK: - BrowserTabView.swift
import SwiftUI
import Translation
import WebKit

struct BrowserTabView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var vm: BrowserViewModel
    @AppStorage("preferredEngine") private var preferredEngineRawValue: String = EngineTag.afm.rawValue

    // TranslationSession 트리거
    @State private var trConfig: TranslationSession.Configuration? = nil
    
    init(container: AppContainer) {
        _vm = StateObject(
            wrappedValue: BrowserViewModel(
                container: container,
                extractor: WKContentExtractor(),
                router: container.router,
                replacer: WebViewInlineReplacer(),
                fmQuery: container.fmQuery,
                settings: container.settings
            )
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            URLBarView(
                urlString: $vm.urlString,
                selectedEngine: preferredEngineBinding,
                showOriginal: $vm.showOriginal,
                isEditing: $vm.isEditingURL,
                currentPageURLString: vm.currentPageURLString,
                onSelectEngine: { engine, wasShowingOriginal in
                    vm.onEngineSelected(engine, wasShowingOriginal: wasShowingOriginal)
                }
            ) { url in
                vm.load(urlString: url)
                triggerTranslationSession()
            }

            ZStack(alignment: .top) {
                WebContainerView(
                    request: vm.request,
                    onAttach: { webView in vm.attachWebView(webView) },
                    onDidFinish: { webView, url in
                        vm.onWebViewDidFinishLoad(webView, url: url)
                    },
                    onSelectSegmentID: { sid in
                        Task {
                            await vm.onSegmentTapped(id: sid)
                        }
                    },
                    onAskAI: { Task { await vm.askAIForSelected() } },
                    onApplyAI: { vm.applyAIImproved() },
                    onClosePanel: { /* 필요 시 상태 정리 */ },
                    onNavigate: { vm.willNavigate() }
                )
                .background(OverlayButtonHost(vm: vm)) // 패널 버튼 액션 연결용 호스트
                if vm.isTranslating {
                    ProgressView().padding(.top, 12)
                }
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
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
        // WebView 로드 이후 자동 번역
        .task(id: vm.pendingAutoTranslateID) {
            if vm.pendingAutoTranslateID != nil {
                vm.onShowOriginalChanged(vm.showOriginal)
            }
        }
        // TranslationSession을 컨테이너 서비스에 연결
        .translationTask(trConfig) { session in
            // (선택) 사전 준비: 모델 다운로드/권한 UX 향상
            // try? await session.prepareTranslation()
            container.attachAFMSession(session)
        }
    }

    private var preferredEngineBinding: Binding<EngineTag> {
        Binding(
            get: { EngineTag(rawValue: preferredEngineRawValue) ?? .afm },
            set: { preferredEngineRawValue = $0.rawValue }
        )
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
}

// WebContainerView의 패널 버튼 액션을 뷰모델에 연결하기 위한 호스트 뷰
private struct OverlayButtonHost: UIViewRepresentable {
    let vm: BrowserViewModel
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {
        // 패널 버튼 액션은 Coordinator가 직접 처리하지 않고,
        // VM의 메서드를 호출하도록 여기에 연결하고 싶다면
        // 필요 시 Notification/Combine 등으로도 연결 가능.
        // (현 스니펫에선 패널의 버튼 콜백을 Coordinator가 직접 가지지 않게
        // 설계했으므로 별도 훅 없이 VM 메서드를 직접 호출하면 됨)
    }
}
