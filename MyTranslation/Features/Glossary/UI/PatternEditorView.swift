import SwiftData
import SwiftUI

struct PatternEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PatternEditorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("기본 정보") {
                    LabeledContent("패턴 ID") {
                        TextField("예: person", text: $viewModel.patternID)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("표시 이름") {
                        TextField("예: 인물 패턴", text: $viewModel.displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("그룹 정책") {
                        Picker("그룹 정책", selection: $viewModel.grouping) {
                            Text("없음").tag(Glossary.SDModel.SDPatternGrouping.none)
                            Text("선택").tag(Glossary.SDModel.SDPatternGrouping.optional)
                            Text("필수").tag(Glossary.SDModel.SDPatternGrouping.required)
                        }
                        .pickerStyle(.menu)
                    }
                    LabeledContent("그룹 라벨") {
                        TextField("예: 그룹", text: $viewModel.groupLabel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Section("역할") {
                    Text("세미콜론(;)으로 구분해 역할 슬롯을 입력하세요. 비워두면 역할 없는 패턴으로 처리됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("역할 목록") {
                        TextField("예: family;given", text: $viewModel.rolesText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Section("템플릿") {
                    LabeledContent("원문 템플릿") {
                        TextField("세미콜론(;)으로 구분", text: $viewModel.sourceTemplates)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("번역 템플릿") {
                        TextField("단일 템플릿", text: $viewModel.targetTemplate)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("번역 변형 템플릿") {
                        TextField("세미콜론(;)으로 구분", text: $viewModel.variantTemplates)
                            .textFieldStyle(.roundedBorder)
                    }
                    TemplatePreviewView(rolesText: $viewModel.rolesText, targetTemplate: $viewModel.targetTemplate, variantTemplates: $viewModel.variantTemplates)
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
    @Binding var rolesText: String
    @Binding var sourceTemplates: String
    @Binding var targetTemplate: String
    @Binding var variantTemplates: String

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
        let roles = rolesText
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let target = targetTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let templates = [target] + variantTemplates
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let first = templates.first(where: { !$0.isEmpty }) else { return "{role} 템플릿" }
        return fill(template: first, roles: roles)
    }

    private func fill(template: String, roles: [String]) -> String {
        let slots = extractSlots(from: template)
        let samples = ["홍", "길동", "샘플"]
        var rendered = template
        for (idx, slot) in slots.enumerated() {
            let replacement: String
            if let roleIndex = roles.firstIndex(of: slot), roleIndex < samples.count {
                replacement = samples[roleIndex]
            } else {
                replacement = samples[idx % samples.count]
            }
            rendered = rendered.replacingOccurrences(of: "{\(slot)}", with: replacement)
        }
        return rendered
    }

    private func extractSlots(from template: String) -> [String] {
        var slots: [String] = []
        var current = ""
        var inside = false

        for ch in template {
            if ch == "{" {
                inside = true
                current = ""
            } else if ch == "}" {
                if inside, !current.isEmpty {
                    slots.append(current)
                }
                inside = false
            } else if inside {
                current.append(ch)
            }
        }

        return slots
    }
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = try! PatternEditorViewModel(context: context, patternID: "person")
    return PatternEditorView(viewModel: vm)
}
