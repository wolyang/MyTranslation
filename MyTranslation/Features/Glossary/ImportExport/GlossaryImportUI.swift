import Foundation
import SwiftUI
import SwiftData

extension Glossary.SDModel {
    struct ImportDryRunView: View {
        let report: ImportDryRunReport
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Stat("Terms", report.terms)
                    Stat("Patterns", report.patterns)
                }
                if !report.warnings.isEmpty {
                    Divider()
                    Text("Warnings").font(.headline)
                    ForEach(Array(report.warnings.enumerated()), id: \.0) { _, w in
                        Text("• \(w)").foregroundStyle(.orange)
                    }
                }
                if !(report.termKeyCollisions.isEmpty && report.patternKeyCollisions.isEmpty) {
                    Divider()
                    Text("Key Collisions").font(.headline)
                    if !report.termKeyCollisions.isEmpty {
                        Text("Terms").font(.subheadline)
                        ForEach(report.termKeyCollisions.sorted(by: { $0.key < $1.key }), id: \.self) { c in
                            Text("• \(c.key) ×\(c.count)")
                        }
                    }
                    if !report.patternKeyCollisions.isEmpty {
                        Text("Patterns").font(.subheadline).padding(.top, 6)
                        ForEach(report.patternKeyCollisions.sorted(by: { $0.key < $1.key }), id: \.self) { c in
                            Text("• \(c.key) ×\(c.count)")
                        }
                    }
                }
            }
            .padding()
        }
        @ViewBuilder private func Stat(_ title: String, _ b: ImportDryRunReport.Bucket) -> some View {
            VStack {
                Text(title).font(.subheadline)
                HStack {
                    Label("+\(b.newCount)", systemImage: "plus.circle").foregroundStyle(.green)
                    Label("±\(b.updateCount)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                    Label("=\(b.unchangedCount)", systemImage: "equal").foregroundStyle(.secondary)
                    Label("−\(b.deleteCount)", systemImage: "trash").foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @MainActor final class ToastHub: ObservableObject {
        static let shared = ToastHub()
        @Published var message: String? = nil
        func show(_ text: String, seconds: Double = 2.0) {
            message = text
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if message == text { message = nil } }
        }
    }

    @MainActor
    struct ImportCoordinator {
        let context: ModelContext
        func performImport(bundle: JSBundle, merge: ImportMergePolicy, sync: ImportSyncPolicy = .init()) async {
            do {
                let upserter = GlossaryUpserter(context: context, merge: merge, sync: sync)
                let report = try upserter.dryRun(bundle: bundle)
                _ = try upserter.apply(bundle: bundle)
                ToastHub.shared.show("임포트 완료: Terms +\(report.terms.newCount+report.terms.updateCount), Patterns +\(report.patterns.newCount+report.patterns.updateCount)")
            } catch {
                ToastHub.shared.show("임포트 실패: \(error.localizedDescription)")
            }
        }
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

struct ToastOverlay: ViewModifier {
    @ObservedObject var hub = Glossary.SDModel.ToastHub.shared
    func body(content: Content) -> some View {
        ZStack {
            content
            if let msg = hub.message {
                Text(msg)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 6)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hub.message)
    }
}
