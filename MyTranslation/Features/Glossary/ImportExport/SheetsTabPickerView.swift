import SwiftUI

struct SheetsTabPickerView: View {
    @Bindable var viewModel: SheetsImportViewModel

    var body: some View {
        List {
            Section("탭 분류") {
                ForEach(viewModel.availableTabs) { tab in
                    HStack {
                        Text(tab.title)
                        Spacer()
                        Picker("유형", selection: binding(for: tab.id)) {
                            Text("미선택").tag(SheetsImportViewModel.Tab.Kind?.none)
                            Text("용어").tag(Optional(SheetsImportViewModel.Tab.Kind.term))
                            Text("패턴").tag(Optional(SheetsImportViewModel.Tab.Kind.pattern))
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            Section("동기화") {
                Toggle(isOn: $viewModel.applyDeletions) {
                    Text("문서에 없는 용어/패턴을 기기에서도 삭제하기")
                }
            }
            Section("병합 정책") {
                Picker("병합 방식", selection: $viewModel.mergePolicy) {
                    Text("병합").tag(SheetsImportViewModel.MergePolicy.merge)
                    Text("덮어쓰기").tag(SheetsImportViewModel.MergePolicy.overwrite)
                }
                .pickerStyle(.segmented)

                Group {
                    if viewModel.mergePolicy == .merge {
                        Text("기존 데이터와 새 데이터를 병합합니다. 배열 필드는 합치고, 단일 값은 새 값으로 갱신됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("새 데이터로 완전히 덮어씁니다. 문서에 없는 항목은 기기에서도 제거됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button {
                    Task { await viewModel.loadPreview() }
                } label: {
                    Label("미리보기", systemImage: "play")
                }
                .disabled(viewModel.isProcessing)
            }
        }
        .overlay {
            if viewModel.isProcessing { ProgressView() }
        }
    }

    private func binding(for id: UUID) -> Binding<SheetsImportViewModel.Tab.Kind?> {
        Binding {
            if viewModel.selectedTermTabs.contains(id) { return .term }
            if viewModel.selectedPatternTabs.contains(id) { return .pattern }
            return nil
        } set: { newValue in
            viewModel.setSelection(kind: newValue, forTab: id)
        }
    }
}
