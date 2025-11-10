import SwiftData
import SwiftUI

struct TermEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: TermEditorViewModel

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

    private var generalForm: some View {
        Section("원문") {
            TextEditor(text: $viewModel.generalDraft.sourcesOK)
                .frame(minHeight: 80)
                .accessibilityLabel("허용 원문")
            TextEditor(text: $viewModel.generalDraft.sourcesProhibit)
                .frame(minHeight: 80)
                .accessibilityLabel("금지 원문")
        }
        Section("번역") {
            TextField("번역", text: $viewModel.generalDraft.target)
            TextField("변형 (세미콜론)", text: $viewModel.generalDraft.variants)
            TextField("태그 (세미콜론)", text: $viewModel.generalDraft.tags)
        }
        Section("속성") {
            Toggle("호칭 여부", isOn: $viewModel.generalDraft.isAppellation)
            Toggle("Pre-mask", isOn: $viewModel.generalDraft.preMask)
        }
    }

    private var patternForm: some View {
        Section(header: Text("그룹")) {
            TextField(viewModel.pattern?.groupLabel ?? "그룹", text: $viewModel.groupName)
            if let pattern = viewModel.pattern {
                Text("기본 금지: \(pattern.defaultProhibitStandalone ? "예" : "아니오")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach($viewModel.roleDrafts) { $draft in
            Section(header: Text(draft.roleName.isEmpty ? "항목" : draft.roleName)) {
                TextEditor(text: $draft.sourcesOK)
                    .frame(minHeight: 70)
                    .accessibilityLabel("허용 원문")
                TextEditor(text: $draft.sourcesProhibit)
                    .frame(minHeight: 70)
                    .accessibilityLabel("금지 원문")
                TextField("번역", text: $draft.target)
                TextField("변형 (세미콜론)", text: $draft.variants)
                TextField("태그 (세미콜론)", text: $draft.tags)
                Toggle("호칭", isOn: $draft.isAppellation)
                Toggle("Pre-mask", isOn: $draft.preMask)
            }
        }
    }

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
