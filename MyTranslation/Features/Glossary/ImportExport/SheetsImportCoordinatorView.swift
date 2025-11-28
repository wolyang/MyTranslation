import SwiftData
import SwiftUI

struct SheetsImportCoordinatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SheetsImportViewModel

    init(modelContext: ModelContext) {
        _viewModel = State(initialValue: SheetsImportViewModel(context: modelContext))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .url:
                    SheetsURLInputView(viewModel: viewModel)
                case .tabs:
                    SheetsTabPickerView(viewModel: viewModel)
                case .preview:
                    SheetsImportPreviewView(viewModel: viewModel, onComplete: {
                        dismiss()
                    })
                }
            }
            .navigationTitle("Google 시트 가져오기")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
            .alert("오류", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button("확인", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}
