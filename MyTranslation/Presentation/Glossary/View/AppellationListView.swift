import SwiftUI

struct AppellationListView: View {
    @Bindable var viewModel: GlossaryHomeViewModel
    let onCreateMarker: () -> Void
    let onEditMarker: (GlossaryHomeViewModel.AppellationMarkerRow) -> Void

    var body: some View {
        List(viewModel.markers) { marker in
            Button {
                onEditMarker(marker)
            } label: {
                AppellationRowView(marker: marker)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.markers.isEmpty {
                ContentUnavailableView(
                    "호칭 없음",
                    systemImage: "text.quote",
                    description: Text("호칭 마커를 추가해 주세요.")
                )
            }
        }
        .navigationTitle("호칭")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("새 호칭", action: onCreateMarker)
            }
        }
        .task { viewModel.load() }
    }
}

private struct AppellationRowView: View {
    let marker: GlossaryHomeViewModel.AppellationMarkerRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(marker.source)
                    .font(.headline)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(marker.target)
                    .font(.headline)
                Spacer()
            }
            if !marker.variants.isEmpty {
                Text(marker.variants.joined(separator: "; "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 8) {
                label(text: positionLabel, systemImage: "textformat")
                if marker.prohibitStandalone {
                    label(text: "단독 금지", systemImage: "hand.raised")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var positionLabel: String {
        switch marker.position {
        case "prefix": return "접두" 
        case "suffix": return "접미"
        default: return marker.position
        }
    }

    private func label(text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }
}

#Preview {
    let container = PreviewData.container
    let context = container.mainContext
    let vm = GlossaryHomeViewModel(context: context)
    Task { @MainActor in await vm.reloadAll() }
    return NavigationStack {
        AppellationListView(viewModel: vm, onCreateMarker: {}, onEditMarker: { _ in })
    }
}
