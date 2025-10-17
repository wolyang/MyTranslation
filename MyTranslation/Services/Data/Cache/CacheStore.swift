// File: CacheStore.swift
import Foundation

protocol CacheStore {
    func lookup(key: String) -> TranslationResult?
    func save(result: TranslationResult, forKey key: String)
    func purge(before date: Date)
}

final class DefaultCacheStore: CacheStore {
    private var store: [String: TranslationResult] = [:]
    func lookup(key: String) -> TranslationResult? { store[key] }
    func save(result: TranslationResult, forKey key: String) { store[key] = result }
    func purge(before date: Date) { /* no-op for MVP */ }
}
