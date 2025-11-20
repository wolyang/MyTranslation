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

    @ViewBuilder
    private var generalForm: some View {
        Section("원문") {
            sourceField(
                title: "허용 원문",
                text: $viewModel.generalDraft.sourcesOK,
                help: "세미콜론(;)으로 구분해 단독 번역을 허용할 원문을 입력하세요.",
                accessibilityLabel: "허용 원문"
            )
            sourceField(
                title: "금지 원문",
                text: $viewModel.generalDraft.sourcesProhibit,
                help: "세미콜론(;)으로 구분해 단독 번역을 금지할 원문을 입력하세요.",
                accessibilityLabel: "금지 원문"
            )
        }
        Section("번역") {
            formTextField("번역", text: $viewModel.generalDraft.target)
            formTextField(
                "변형",
                text: $viewModel.generalDraft.variants,
                help: "세미콜론(;)으로 구분해 여러 변형을 입력하세요."
            )
        }
        Section("태그") {
            formTextField(
                "태그",
                text: $viewModel.generalDraft.tags,
                help: "세미콜론(;)으로 태그를 구분합니다."
            )
        }
        Section("속성") {
            Toggle("호칭 여부", isOn: $viewModel.generalDraft.isAppellation)
            Toggle("Pre-mask", isOn: $viewModel.generalDraft.preMask)
        }
    }

    @ViewBuilder
    private var patternForm: some View {
        if let pattern = viewModel.pattern {
            Section(header: Text("패턴 정보")) {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(title: "단독 번역 기본값", value: pattern.defaultProhibitStandalone ? "금지" : "허용")
                    infoRow(title: "호칭 기본값", value: pattern.defaultIsAppellation ? "사용" : "미사용")
                    infoRow(title: "Pre-mask 기본값", value: pattern.defaultPreMask ? "사용" : "미사용")
                    Text("위 기본값은 새 용어 생성 시 자동으로 적용됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if pattern.grouping != .none {
                Section(header: Text("\(pattern.groupLabel) 선택")) {
                    GroupSelectionField(
                        label: pattern.groupLabel,
                        grouping: pattern.grouping,
                        options: viewModel.patternGroups,
                        selectedGroupID: $viewModel.selectedGroupID,
                        customName: $viewModel.newGroupName
                    )
                }
            }
        }
        ForEach($viewModel.roleDrafts) { $draft in
            Section(header: Text(draft.roleName.isEmpty ? "항목" : draft.roleName)) {
                if !viewModel.roleOptions.isEmpty {
                    let existingRole = draft.roleName
                    let roleOptions = viewModel.roleOptions
                    let needsExistingTag = !existingRole.isEmpty && !roleOptions.contains(existingRole)
                    Picker("역할", selection: $draft.roleName) {
                        Text("역할 없음").tag("")
                        if needsExistingTag {
                            Text(existingRole).tag(existingRole)
                        }
                        ForEach(roleOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    formTextField(
                        "역할",
                        text: $draft.roleName,
                        help: "필요하다면 역할 이름을 직접 입력하세요."
                    )
                }
                sourceField(
                    title: "허용 원문",
                    text: $draft.sourcesOK,
                    help: "세미콜론(;)으로 구분해 단독 번역을 허용할 원문을 입력하세요.",
                    accessibilityLabel: "허용 원문"
                )
                sourceField(
                    title: "금지 원문",
                    text: $draft.sourcesProhibit,
                    help: "세미콜론(;)으로 구분해 단독 번역을 금지할 원문을 입력하세요.",
                    accessibilityLabel: "금지 원문"
                )
                formTextField("번역", text: $draft.target)
                formTextField(
                    "변형",
                    text: $draft.variants,
                    help: "세미콜론(;)으로 구분해 여러 변형을 입력하세요."
                )
                formTextField(
                    "태그",
                    text: $draft.tags,
                    help: "세미콜론(;)으로 태그를 구분합니다."
                )
                Toggle("호칭", isOn: $draft.isAppellation)
                Toggle("Pre-mask", isOn: $draft.preMask)
            }
        }
    }

    private func sourceField(
        title: String,
        text: Binding<String>,
        help: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibilityLabel)
            Text(help)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func formTextField(
        _ title: String,
        text: Binding<String>,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
            if let help {
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var componentEditor: some View {
        if viewModel.canEditComponents {
            Section("패턴 연결") {
                if viewModel.componentDrafts.isEmpty {
                    Text("패턴을 선택해 새 연결을 추가하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach($viewModel.componentDrafts) { component in
                    componentCard(for: component)
                        .padding(.vertical, 4)
                }
                Button {
                    viewModel.addComponentDraft()
                } label: {
                    Label("패턴 연결 추가", systemImage: "plus")
                }
            }
        }
    }

    private func componentCard(for component: Binding<TermEditorViewModel.ComponentDraft>) -> some View {
        let patternSelection = Binding<String?>(
            get: { component.patternID.wrappedValue },
            set: { newValue in
                component.patternID.wrappedValue = newValue
                viewModel.didSelectPattern(for: component.wrappedValue.id, patternID: newValue)
            }
        )
        let patternID = component.patternID.wrappedValue
        let hasPattern = viewModel.patternOption(for: patternID) != nil
        return VStack(alignment: .leading, spacing: 12) {
            Picker("패턴", selection: patternSelection) {
                Text("패턴 선택").tag(String?.none)
                if let patternID,
                   !viewModel.sortedPatternOptions.contains(where: { $0.id == patternID }) {
                    Text(patternID).tag(Optional(patternID))
                }
                ForEach(viewModel.sortedPatternOptions) { option in
                    Text(option.displayName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)

            if hasPattern {
                let roles = viewModel.availableRoles(for: patternID)
                let existingRole = component.roleName.wrappedValue
                let needsExistingRole = !existingRole.isEmpty && !roles.contains(existingRole)
                if !roles.isEmpty {
                    Picker("역할", selection: component.roleName) {
                        Text("역할 없음").tag("")
                        if needsExistingRole {
                            Text(existingRole).tag(existingRole)
                        }
                        ForEach(roles, id: \.self) { role in
                            Text(role).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text("이 패턴에는 지정할 역할 슬롯이 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                let grouping = viewModel.grouping(for: patternID)
                if grouping != .none {
                    GroupSelectionField(
                        label: viewModel.groupLabel(for: patternID),
                        grouping: grouping,
                        options: viewModel.availableGroups(for: patternID),
                        selectedGroupID: component.selectedGroupUID,
                        customName: component.customGroupName
                    )
                }

                templatePicker(
                    title: "원문 템플릿",
                    templates: viewModel.sourceTemplates(for: patternID),
                    selection: component.srcTemplateIndex
                )
                templatePicker(
                    title: "번역 템플릿",
                    templates: viewModel.targetTemplates(for: patternID),
                    selection: component.tgtTemplateIndex
                )
            } else {
                Text("패턴을 선택하면 역할, 그룹, 템플릿을 설정할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                viewModel.removeComponentDraft(id: component.wrappedValue.id)
            } label: {
                Label("연결 삭제", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    private func templatePicker(title: String, templates: [String], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            if templates.isEmpty {
                Text("사용 가능한 템플릿이 없습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker(title, selection: selection) {
                    ForEach(Array(templates.enumerated()), id: \.offset) { item in
                        Text("\(item.offset + 1): \(item.element)")
                            .lineLimit(2)
                            .tag(item.offset)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private struct GroupSelectionField: View {
        let label: String
        let grouping: Glossary.SDModel.SDPatternGrouping
        let options: [TermEditorViewModel.GroupOption]
        @Binding var selectedGroupID: String?
        @Binding var customName: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Picker("기존 \(label) 선택", selection: $selectedGroupID) {
                    Text("선택 안 함").tag(String?.none)
                    ForEach(options) { option in
                        Text(option.name).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedGroupID) { _, newValue in
                    if newValue != nil {
                        customName = ""
                    }
                }

                TextField("새로운 \(label)", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customName) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                            selectedGroupID = nil
                        }
                    }

                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        private var description: String {
            switch grouping {
            case .none:
                return "이 패턴은 그룹을 사용하지 않습니다."
            case .optional:
                return "기존 그룹을 선택하거나 새 이름을 입력해 그룹을 지정할 수 있습니다."
            case .required:
                return "필수 그룹입니다. 기존 항목을 선택하거나 새 그룹 이름을 입력하세요."
            }
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
