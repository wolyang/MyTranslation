import SwiftUI

struct HistoryView: View {
    @ObservedObject var historyStore: HistoryStore
    var onSelect: (BrowsingHistory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var isConfirmingDeleteAll: Bool = false

    var body: some View {
        List {
            if groupedItems.isEmpty {
                VStack(spacing: 8) {
                    Text("방문 기록이 없습니다.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("번역하거나 탐색한 페이지가 여기에 표시됩니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else {
                ForEach(groupedItems, id: \.date) { group in
                    Section(sectionTitle(for: group.date)) {
                        ForEach(group.items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.url)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(timeString(for: item.visitedAt))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { group.items[$0].id }
                            historyStore.delete(ids: Set(ids))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "URL 또는 제목 검색")
        .navigationTitle("히스토리")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("닫기") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if historyStore.items.isEmpty == false {
                    Button("전체 삭제") { isConfirmingDeleteAll = true }
                        .foregroundStyle(.red)
                }
            }
        }
        .alert("히스토리를 모두 삭제할까요?", isPresented: $isConfirmingDeleteAll) {
            Button("삭제", role: .destructive) { historyStore.deleteAll() }
            Button("취소", role: .cancel) { }
        }
    }

    private var filteredItems: [BrowsingHistory] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return historyStore.items }
        return historyStore.items.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.url.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var groupedItems: [(date: Date, items: [BrowsingHistory])] {
        let grouped = Dictionary(grouping: filteredItems) { item in
            Calendar.current.startOfDay(for: item.visitedAt)
        }
        return grouped
            .map { (date: $0.key, items: $0.value.sorted { $0.visitedAt > $1.visitedAt }) }
            .sorted { $0.date > $1.date }
    }

    private func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "오늘" }
        if calendar.isDateInYesterday(date) { return "어제" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
