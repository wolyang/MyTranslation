import Foundation
@testable import MyTranslation

final class MockCacheStore: CacheStore {
    private var store: [String: TranslationResult] = [:]

    // Call tracking
    private(set) var lookupCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var clearAllCallCount = 0
    private(set) var clearBySegmentIDsCallCount = 0
    private(set) var purgeCallCount = 0
    private(set) var lastLookupKey: String?
    private(set) var lastSaveKey: String?
    private(set) var lastClearedIDs: [String] = []

    // Configuration
    var shouldReturnNil = false

    func preload(_ entries: [String: TranslationResult]) {
        store = entries
    }

    func lookup(key: String) -> TranslationResult? {
        lookupCallCount += 1
        lastLookupKey = key
        if shouldReturnNil { return nil }
        return store[key]
    }

    func save(result: TranslationResult, forKey key: String) {
        saveCallCount += 1
        lastSaveKey = key
        store[key] = result
    }

    func purge(before date: Date) {
        purgeCallCount += 1
    }

    func clearAll() {
        clearAllCallCount += 1
        store.removeAll()
    }

    func clearBySegmentIDs(_ ids: [String]) {
        clearBySegmentIDsCallCount += 1
        lastClearedIDs = ids
        guard ids.isEmpty == false else { return }

        let idSet = Set(ids)
        store = store.filter { key, _ in
            guard let prefix = key.split(separator: "|").first else { return true }
            return idSet.contains(String(prefix)) == false
        }
    }
}
