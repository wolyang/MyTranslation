import SwiftUI

struct AppellationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: AppellationEditorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("원문") {
                    formTextField("원문", text: $viewModel.source)
                }
                Section("번역") {
                    formTextField("번역", text: $viewModel.target)
                    formTextField(
                        "변형",
                        text: $viewModel.variants,
                        help: "세미콜론(;)으로 변형을 구분합니다."
                    )
                }
                Section("속성") {
                    Picker("위치", selection: $viewModel.position) {
                        ForEach(AppellationEditorViewModel.Position.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("단독 번역 금지", isOn: $viewModel.prohibitStandalone)
                }
            }
            .navigationTitle(viewModel.title)
            .toolbar { toolbar }
            .alert(
                "오류",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("확인", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("취소") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("저장") {
                if viewModel.save() {
                    dismiss()
                }
            }
            .bold()
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
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let viewModel = try! AppellationEditorViewModel(context: context, markerID: nil)
    return AppellationEditorView(viewModel: viewModel)
}
