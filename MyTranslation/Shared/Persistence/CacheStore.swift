// File: CacheStore.swift
import Foundation

protocol CacheStore {
    func lookup(key: String) -> TranslationResult?
    func save(result: TranslationResult, forKey key: String)
    func purge(before date: Date)
    func clearAll()
    func clearBySegmentIDs(_ ids: [String])
}

final class DefaultCacheStore: CacheStore {
    private var store: [String: TranslationResult] = [:]
    func lookup(key: String) -> TranslationResult? { store[key] }
    func save(result: TranslationResult, forKey key: String) { store[key] = result }
    func purge(before date: Date) {
        store = store.filter { _, value in
            value.createdAt >= date
        }
    }
    func clearAll() { store.removeAll() }
    func clearBySegmentIDs(_ ids: [String]) {
        guard ids.isEmpty == false else { return }
        let idSet = Set(ids)
        store = store.filter { key, _ in
            guard let prefix = key.split(separator: "|").first else { return true }
            return idSet.contains(String(prefix)) == false
        }
    }
}
