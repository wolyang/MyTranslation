import SwiftData
import SwiftUI

extension TermEditorView {
    @ViewBuilder
    var generalForm: some View {
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
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("활성화 조건")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        if availableTerms.isEmpty {
                            availableTerms = (try? viewModel.fetchAllTermsForPicker()) ?? []
                        }
                        showingTermPicker = true
                    } label: {
                        Label("Term 추가", systemImage: "plus.circle.fill")
                            .font(.subheadline)
                    }
                }

                if viewModel.generalDraft.activatedByArray.isEmpty {
                    Text("지정된 Term이 동일 세그먼트에 출현하면 이 용어가 활성화됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    activatorChips
                }
            }
        }
        .sheet(isPresented: $showingTermPicker) {
            TermPickerSheet(terms: availableTerms) { selectedKey in
                viewModel.addActivatorTerm(key: selectedKey)
            }
        }
    }

    @ViewBuilder
    var patternForm: some View {
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
                    Picker("역할", selection: $draft.roleName) {
                        Text("역할 없음").tag("")
                        ForEach(viewModel.roleOptions, id: \.self) { option in
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

    func sourceField(
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

    func formTextField(
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

    func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
    }
}

struct GroupSelectionField: View {
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
