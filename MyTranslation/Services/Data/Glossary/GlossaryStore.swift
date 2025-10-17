// File: GlossaryStore.swift
import Foundation
import SwiftData

@MainActor
protocol GlossaryStore {
    func fetchTerms(query: String?) throws -> [Term]
    func upsert(term: Term) throws
    func delete(term: Term) throws
    func snapshot() throws -> [GlossaryEntry]
}

final class NopGlossaryStore: GlossaryStore {
    func fetchTerms(query: String?) throws -> [Term] { [] }
    func upsert(term: Term) throws { }
    func delete(term: Term) throws { }
    func snapshot() throws -> [GlossaryEntry] { [] }
}

final class DefaultGlossaryStore: GlossaryStore {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }
    
    func fetchTerms(query: String?) throws -> [Term] {
        let descriptor = FetchDescriptor<Term>()
        // (필요시 query로 predicate 구성)
        return try context.fetch(descriptor)
    }
    func upsert(term: Term) throws { try context.save() }
    func delete(term: Term) throws { context.delete(term); try context.save() }
    func snapshot() throws -> [GlossaryEntry] {
        let terms = try fetchTerms(query: nil)
        var entries: [GlossaryEntry] = []
        for t in terms {
            var entry = GlossaryEntry(source: t.source, target: t.target, category: TermCategory(with: t.category))
            entries.append(entry)
            // variants → 동일 타겟으로 맵핑
            for v in t.variants {
                var entry = GlossaryEntry(source: v, target: t.target, category: TermCategory(with: t.category))
                entries.append(entry)
            }
        }
        return entries
    }
}
