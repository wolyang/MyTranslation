import SwiftUI

struct SheetsImportPreviewView: View {
    @Bindable var viewModel: SheetsImportViewModel
    let onComplete: () -> Void
    @State private var showSuccessToast: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            if let report = viewModel.dryRunReport {
                VStack(alignment: .leading, spacing: 16) {
                    statCard(title: "용어", bucket: report.terms)
                    statCard(title: "패턴", bucket: report.patterns)
                }
                .padding(.horizontal)
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

    private func statCard(title: String, bucket: Glossary.SDModel.ImportDryRunReport.Bucket) -> some View {
        let total = bucket.newCount + bucket.updateCount + bucket.unchangedCount + bucket.deleteCount
        return VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                statRow(title: "전체", value: total, systemImage: "number", color: .primary)
                statRow(title: "신규", value: bucket.newCount, systemImage: "plus.circle", color: .green)
                statRow(title: "갱신", value: bucket.updateCount, systemImage: "arrow.triangle.2.circlepath", color: .blue)
                statRow(title: "변경없음", value: bucket.unchangedCount, systemImage: "equal", color: .secondary)
                statRow(title: "삭제", value: bucket.deleteCount, systemImage: "trash", color: .red)
            }
            .font(.footnote)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(title: String, value: Int, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(color)
            Spacer()
            Text("\(value)")
                .foregroundStyle(color == .primary ? .primary : color)
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
