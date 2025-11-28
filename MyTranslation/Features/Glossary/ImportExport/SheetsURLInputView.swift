import SwiftUI

struct SheetsURLInputView: View {
    @Bindable var viewModel: SheetsImportViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("Google 스프레드시트 URL을 입력하세요.")
                .multilineTextAlignment(.center)
                .padding(.top, 40)
            TextField("https://", text: $viewModel.spreadsheetURL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(.horizontal)
            Button {
                Task { await viewModel.validateURL() }
            } label: {
                Label("탭 불러오기", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.spreadsheetURL.isEmpty || viewModel.isProcessing)
            if viewModel.isProcessing {
                ProgressView()
            }
            Spacer()
        }
        .padding()
        .onAppear { focused = true }
    }
}
