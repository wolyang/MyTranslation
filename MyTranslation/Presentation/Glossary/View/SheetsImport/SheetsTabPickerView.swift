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
                            Text("호칭").tag(Optional(SheetsImportViewModel.Tab.Kind.marker))
                        }
                        .pickerStyle(.menu)
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
            if viewModel.selectedMarkerTabs.contains(id) { return .marker }
            return nil
        } set: { newValue in
            viewModel.selectedTermTabs.remove(id)
            viewModel.selectedPatternTabs.remove(id)
            viewModel.selectedMarkerTabs.remove(id)
            switch newValue {
            case .term?: viewModel.selectedTermTabs.insert(id)
            case .pattern?: viewModel.selectedPatternTabs.insert(id)
            case .marker?: viewModel.selectedMarkerTabs.insert(id)
            default: break
            }
        }
    }
}
