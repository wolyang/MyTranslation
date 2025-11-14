import SwiftUI

struct PatternListView: View {
    @Bindable var viewModel: GlossaryHomeViewModel

    let onCreatePattern: () -> Void
    let onEditPattern: (GlossaryHomeViewModel.PatternSummary) -> Void

    var body: some View {
        List {
            ForEach(viewModel.patterns) { pattern in
                Button {
                    onEditPattern(pattern)
                } label: {
                    PatternRowView(pattern: pattern)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("패턴 편집") { onEditPattern(pattern) }
                }
                .swipeActions(edge: .trailing) {
                    Button("패턴 편집") { onEditPattern(pattern) }
                        .tint(.accentColor)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.patterns.isEmpty {
                ContentUnavailableView(
                    "패턴 없음",
                    systemImage: "square.grid.2x2",
                    description: Text("패턴을 추가해 주세요.")
                )
            }
        }
        .navigationTitle("패턴")
        .toolbar { toolbar }
        .task { viewModel.load() }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("패턴 추가") { onCreatePattern() }
        }
    }
}

private struct PatternRowView: View {
    let pattern: GlossaryHomeViewModel.PatternSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pattern.displayName)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Text("ID: \(pattern.name)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !pattern.roles.isEmpty {
                Text("역할: \(pattern.roles.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if pattern.grouping != .none {
                Text("그룹: \(groupingDescription) • 레이블: \(pattern.groupLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            badges
        }
        .padding(.vertical, 8)
    }

    private var groupingDescription: String {
        switch pattern.grouping {
        case .none: return "없음"
        case .optional: return "선택"
        case .required: return "필수"
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            if pattern.isAppellation {
                badge(text: "호칭 패턴", color: .blue)
            }
            if pattern.preMask {
                badge(text: "프리마스크", color: .purple)
            }
            if (pattern.meta?.defaultProhibitStandalone ?? false) {
                badge(text: "단독 금지 기본", color: .orange)
            }
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.6), lineWidth: 1)
            )
    }
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = GlossaryHomeViewModel(context: context)
    Task { @MainActor in await vm.reloadAll() }
    return NavigationStack {
        PatternListView(viewModel: vm, onCreatePattern: {}, onEditPattern: { _ in })
    }
}
