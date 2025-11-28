import SwiftData
import SwiftUI

struct TermEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TermEditorViewModel
    @State var showingTermPicker = false
    @State var availableTerms: [TermPickerItem] = []

    var body: some View {
        NavigationStack {
            Form {
                modePicker
                switch viewModel.mode {
                case .general:
                    generalForm
                case .pattern:
                    patternForm
                }
                componentEditor
            }
            .navigationTitle(viewModelTitle)
            .toolbar { toolbar }
            .alert("병합 안내", isPresented: Binding(get: { viewModel.mergeCandidate != nil }, set: { if !$0 { viewModel.mergeCandidate = nil } })) {
                Button("확인", role: .cancel) { viewModel.mergeCandidate = nil }
            } message: {
                if let term = viewModel.mergeCandidate {
                    Text("기존 용어(\(term.target))에 입력값을 병합했습니다.")
                } else {
                    Text("")
                }
            }
            .alert("오류", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("확인", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var viewModelTitle: String {
        if viewModel.editingTerm != nil {
            return "용어 수정"
        } else {
            return viewModel.pattern != nil ? "패턴 기반 생성" : "새 용어"
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        if viewModel.editingTerm == nil, viewModel.pattern != nil {
            Picker("모드", selection: $viewModel.mode) {
                Text("패턴 생성").tag(TermEditorViewModel.Mode.pattern)
                Text("일반").tag(TermEditorViewModel.Mode.general)
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("취소") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("저장") {
                do {
                    try viewModel.save()
                    dismiss()
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("일반") {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = try! TermEditorViewModel(context: context, termID: nil, patternID: nil)
    return TermEditorView(viewModel: vm)
}

#Preview("패턴") {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = try! TermEditorViewModel(context: context, termID: nil, patternID: "person")
    return TermEditorView(viewModel: vm)
}
