// File: GlossaryHost.swift
import SwiftUI
import SwiftData

/// `GlossaryTabView`를 시트나 풀스크린 컨텍스트에서 노출할 때 닫기 버튼을 제공하는 래퍼입니다.
struct GlossaryHost: View {
    @Environment(\.dismiss) private var dismiss

    let modelContext: ModelContext

    @State private var homeViewModel: GlossaryHomeViewModel
    @State private var selection: GlossaryTabView.Tab = .terms
    @State private var activeSheet: GlossaryTabView.ActiveSheet? = nil
    @State private var showResetConfirm: Bool = false
    @State private var resetErrorMessage: String? = nil

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        _homeViewModel = State(initialValue: GlossaryHomeViewModel(context: modelContext))
    }

    var body: some View {
        NavigationStack {
            GlossaryTabView(
                modelContext: modelContext,
                viewModel: homeViewModel,
                selection: $selection,
                activeSheet: $activeSheet
            )
            .navigationTitle("용어집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert("용어집 초기화", isPresented: $showResetConfirm) {
                Button("취소", role: .cancel) { }
                Button("초기화", role: .destructive) {
                    Task { await resetGlossary() }
                }
            } message: {
                Text("모든 용어, 패턴, 호칭 정보를 삭제합니다. 계속하시겠습니까?")
            }
            .alert("초기화 실패", isPresented: Binding(get: { resetErrorMessage != nil }, set: { if !$0 { resetErrorMessage = nil } })) {
                Button("확인", role: .cancel) { resetErrorMessage = nil }
            } message: {
                Text(resetErrorMessage ?? "")
            }
        }
        .sheet(item: $activeSheet, onDismiss: { Task { await homeViewModel.reloadAll() } }) { sheet in
            switch sheet {
            case .term(let viewModel, _):
                TermEditorView(viewModel: viewModel)
            case .pattern(let viewModel, _):
                PatternEditorView(viewModel: viewModel)
            case .appellation(let viewModel, _):
                AppellationEditorView(viewModel: viewModel)
            case .importSheet:
                SheetsImportCoordinatorView(modelContext: modelContext)
            }
        }
        .interactiveDismissDisabled(false)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label("닫기", systemImage: "chevron.backward")
            }
            .accessibilityLabel("용어집 닫기")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("용어집 초기화") {
                showResetConfirm = true
            }
            Button("Google 시트 가져오기") {
                activeSheet = .importSheet()
            }
        }
    }

    private func resetGlossary() async {
        do {
            try await homeViewModel.resetGlossary()
        } catch {
            resetErrorMessage = error.localizedDescription
        }
    }
}
