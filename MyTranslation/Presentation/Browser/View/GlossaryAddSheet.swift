import SwiftUI

struct GlossaryAddSheet: View {
    let state: GlossaryAddSheetState
    let onAddNew: () -> Void
    let onAppendToExisting: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader
                selectedTextCard
                actionButtons
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .navigationTitle("용어집에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                }
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.sectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("선택한 텍스트")
                .font(.headline)
        }
    }

    private var selectedTextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.selectedText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .lineLimit(6)
            Text("선택한 내용으로 용어를 추가할 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                onAddNew()
            } label: {
                Label("새 용어로 추가", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                onAppendToExisting()
            } label: {
                Label("기존 용어에 변형 추가", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}
