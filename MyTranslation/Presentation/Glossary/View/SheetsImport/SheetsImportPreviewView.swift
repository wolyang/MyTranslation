import SwiftUI

struct SheetsImportPreviewView: View {
    @Bindable var viewModel: SheetsImportViewModel
    let onComplete: () -> Void
    @State private var showSuccessToast: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            if let report = viewModel.dryRunReport {
                VStack(alignment: .leading, spacing: 12) {
                    summaryRow(title: "용어", bucket: report.terms)
                    summaryRow(title: "패턴", bucket: report.patterns)
                }
                .padding()
            } else {
                Text("선택된 탭이 없습니다.")
            }
            if let warnings = viewModel.dryRunReport?.warnings, !warnings.isEmpty {
                List(warnings, id: \.self) { warning in
                    Text(warning)
                }
                .frame(maxHeight: 200)
            }
            Spacer()
            if viewModel.isProcessing {
                ProgressView()
            }
            HStack {
                Button("다시 선택") { viewModel.step = .tabs }
                Spacer()
                Button {
                    Task {
                        await viewModel.importSelection()
                        showSuccessToast = true
                        onComplete()
                    }
                } label: {
                    Label("가져오기", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
            .padding()
        }
        .toast(isPresented: $showSuccessToast) {
            Label("가져오기 완료", systemImage: "checkmark.circle")
        }
    }

    private func summaryRow(title: String, bucket: Glossary.SDModel.ImportDryRunReport.Bucket) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("신규 \(bucket.newCount) / 갱신 \(bucket.updateCount) / 변경없음 \(bucket.unchangedCount) / 삭제 \(bucket.deleteCount)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToastModifier<ToastContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let content: () -> ToastContent

    func body(content base: Content) -> some View {
        ZStack(alignment: .top) {
            base
            if isPresented {
                self.content()
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { isPresented = false }
                        }
                    }
            }
        }
        .animation(.spring(), value: isPresented)
    }
}

private extension View {
    func toast<ToastContent: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> ToastContent) -> some View {
        modifier(ToastModifier(isPresented: isPresented, content: content))
    }
}
