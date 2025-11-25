import Foundation
import Combine

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [BrowsingHistory] = []

    private let storageKey = "browsingHistory"
    private let userDefaults: UserDefaults
    private let maxEntries = 500

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.items = Self.load(from: userDefaults, key: storageKey)
    }

    func recordVisit(url: URL, title: String?) {
        guard shouldStore(url: url) else { return }
        let normalizedURL = url.absoluteString
        let rawTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeaningfulTitle = rawTitle.isEmpty == false
        let resolvedTitle = hasMeaningfulTitle ? rawTitle : normalizedURL

        var updated = items
        if let existingIndex = updated.firstIndex(where: { $0.url == normalizedURL }) {
            var existing = updated.remove(at: existingIndex)
            existing.visitedAt = Date()
            if hasMeaningfulTitle {
                existing.title = resolvedTitle
            }
            updated.insert(existing, at: 0)
        } else {
            let entry = BrowsingHistory(
                url: normalizedURL,
                title: resolvedTitle.isEmpty ? normalizedURL : resolvedTitle
            )
            updated.insert(entry, at: 0)
        }
        trim(&updated)
        items = updated
        persist()
    }

    func deleteAll() {
        items = []
        persist()
    }

    func delete(at offsets: IndexSet) {
        var updated = items
        for index in offsets.sorted(by: >) {
            if updated.indices.contains(index) {
                updated.remove(at: index)
            }
        }
        items = updated
        persist()
    }

    func delete(ids: Set<UUID>) {
        guard ids.isEmpty == false else { return }
        var updated = items
        updated.removeAll { ids.contains($0.id) }
        items = updated
        persist()
    }

    func replace(with newItems: [BrowsingHistory]) {
        var trimmed = newItems
        trim(&trimmed)
        items = trimmed
        persist()
    }

    // MARK: - Persistence
    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func trim(_ items: inout [BrowsingHistory]) {
        if items.count > maxEntries {
            items = Array(items.prefix(maxEntries))
        }
    }

    private func shouldStore(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func load(from userDefaults: UserDefaults, key: String) -> [BrowsingHistory] {
        guard let data = userDefaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BrowsingHistory].self, from: data)) ?? []
    }
}
