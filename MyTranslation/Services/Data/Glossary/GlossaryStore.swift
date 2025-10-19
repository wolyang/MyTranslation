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

    // MARK: - Basic CRUD for Terms
    func fetchTerms(query: String? = nil) throws -> [Term] {
        var descriptor = FetchDescriptor<Term>()
        if let q = query, !q.isEmpty {
            descriptor.predicate = #Predicate { $0.source.contains(q) || $0.target.contains(q) }
        }
        return try context.fetch(descriptor)
    }

    func upsert(term: Term) throws {
        try context.save()
    }

    func delete(term: Term) throws {
        context.delete(term)
        try context.save()
    }

    // MARK: - Snapshot → GlossaryEntry[]
    func snapshot() throws -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        // 1️⃣ People
        let people: [Person] = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        for p in people {
            // family/given 풀네임 후보 생성(구분자: "", " ", "·", "・", "-")
            let seps = ["", " ", "·", "・", "-"]
            for f in p.familySources {
                for g in p.givenSources {
                    for s in seps {
                        let full = f + s + g
                        let fullKo = [p.familyTarget, p.givenTarget].compactMap { $0 }.joined(separator: " ")
                        if !fullKo.isEmpty {
                            entries.append(.init(source: full, target: fullKo, variants: [], category: .person, personId: p.personId))
                        }
                    }
                }
            }
            // 단일 성/이름
            if let ft = p.familyTarget {
                for fs in p.familySources {
                    entries.append(.init(source: fs, target: ft, variants: p.familyVariants, category: .person, personId: p.personId)) }
            }
            if let gt = p.givenTarget {
                for gs in p.givenSources {
                    entries.append(.init(source: gs, target: gt, variants: p.givenVariants, category: .person, personId: p.personId)) }
            }
            // alias
            for a in p.aliases {
                let tgt = a.target // nil 가능
                for s in a.sources {
                    if let tgt = tgt, !tgt.isEmpty {
                        entries.append(.init(source: s, target: tgt, variants: a.variants, category: .person, personId: p.personId))
                    }
                }
            }
        }

        // 2️⃣ Terms
        let terms: [Term] = try fetchTerms(query: nil)
        for t in terms {
            let cat = TermCategory(with: t.category)
            entries.append(.init(source: t.source, target: t.target, variants: t.variants, category: cat))
        }

        // 3️⃣ 정렬(긴 용어 우선)
        entries.sort { $0.source.count > $1.source.count }

        return entries
    }
}
