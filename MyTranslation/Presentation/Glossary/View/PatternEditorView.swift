import SwiftData
import SwiftUI

struct PatternEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PatternEditorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("기본 정보") {
                    TextField("패턴 ID", text: $viewModel.patternID)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("표시 이름", text: $viewModel.displayName)
                    TextField("역할 (세미콜론)", text: $viewModel.rolesText)
                    Picker("그룹 정책", selection: $viewModel.grouping) {
                        Text("없음").tag(Glossary.SDModel.SDPatternGrouping.none)
                        Text("선택").tag(Glossary.SDModel.SDPatternGrouping.optional)
                        Text("필수").tag(Glossary.SDModel.SDPatternGrouping.required)
                    }
                    TextField("그룹 라벨", text: $viewModel.groupLabel)
                }
                Section("템플릿") {
                    TextField("원문 조인자 (세미콜론)", text: $viewModel.sourceJoiners)
                    TextField("원문 템플릿 (세미콜론)", text: $viewModel.sourceTemplates)
                    TextField("번역 템플릿 (세미콜론)", text: $viewModel.targetTemplates)
                    TemplatePreviewView(sourceTemplates: $viewModel.sourceTemplates, targetTemplates: $viewModel.targetTemplates)
                }
                Section("역할 배치") {
                    let roles = viewModel.rolesText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if roles.isEmpty {
                        Text("역할을 먼저 입력하세요.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(roles, id: \.self) { role in
                            HStack {
                                Text(role)
                                Spacer()
                                Toggle("LEFT", isOn: Binding(get: { viewModel.leftRoles.contains(role) }, set: { newValue in viewModel.set(role: role, side: .left, active: newValue) }))
                                    .labelsHidden()
                                Toggle("RIGHT", isOn: Binding(get: { viewModel.rightRoles.contains(role) }, set: { newValue in viewModel.set(role: role, side: .right, active: newValue) }))
                                    .labelsHidden()
                            }
                        }
                    }
                }
                Section("옵션") {
                    Toggle("동일 용어 페어 건너뛰기", isOn: $viewModel.skipPairsIfSameTerm)
                    Toggle("호칭 패턴", isOn: $viewModel.isAppellation)
                    Toggle("Pre-mask", isOn: $viewModel.preMask)
                }
                Section("기본값") {
                    Toggle("신규 용어 금지 기본값", isOn: $viewModel.defaultProhibit)
                    Toggle("신규 용어 호칭 기본값", isOn: $viewModel.defaultIsAppellation)
                    Toggle("신규 용어 Pre-mask 기본값", isOn: $viewModel.defaultPreMask)
                }
                if !viewModel.groups.isEmpty {
                    Section("그룹") {
                        ForEach(viewModel.groups) { group in
                            HStack {
                                Text(group.name)
                                Spacer()
                                Text("\(group.termCount)개")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(viewModel.existingPatternID == nil ? "새 패턴" : "패턴 편집")
            .toolbar { toolbar }
            .alert("오류", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("확인", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("닫기") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.existingPatternID != nil {
                Button("삭제", role: .destructive) {
                    try? viewModel.delete()
                    dismiss()
                }
            }
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

struct TemplatePreviewView: View {
    @Binding var sourceTemplates: String
    @Binding var targetTemplates: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("미리보기")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(renderTargetPreview())
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func renderTargetPreview() -> String {
        let target = targetTemplates.split(separator: ";").map { String($0) }.first ?? "{L}"
        let sampleL = "홍"
        let sampleR = "길동"
        var output = target.replacingOccurrences(of: "{L}", with: sampleL)
        output = output.replacingOccurrences(of: "{R}", with: sampleR)
        return output
    }
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = try! PatternEditorViewModel(context: context, patternID: "person")
    return PatternEditorView(viewModel: vm)
}
