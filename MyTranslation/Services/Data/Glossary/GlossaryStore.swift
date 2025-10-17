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
            let seps = ["", " ", "·", "・", "-"]

            // full name 조합
            for f in p.familySources {
                for g in p.givenSources {
                    for sep in seps {
                        let fullZh = f + sep + g
                        let fullKo = [p.familyTarget, p.givenTarget].compactMap { $0 }.joined(separator: " ")
                        if !fullKo.isEmpty {
                            entries.append(
                                GlossaryEntry(source: fullZh, target: fullKo, category: .person)
                            )
                        }
                    }
                }
            }

            // 성/이름 단독
            if let ft = p.familyTarget {
                for fs in p.familySources {
                    entries.append(.init(source: fs, target: ft, category: .person))
                }
            }
            if let gt = p.givenTarget {
                for gs in p.givenSources {
                    entries.append(.init(source: gs, target: gt, category: .person))
                }
            }

            // aliases
            for alias in p.aliases {
                guard let tgt = alias.target else { continue }
                for src in alias.sources {
                    entries.append(.init(source: src, target: tgt, category: .person))
                }
            }
        }

        // 2️⃣ Terms
        let terms: [Term] = try fetchTerms(query: nil)
        for t in terms {
            let cat = TermCategory(with: t.category)
            entries.append(.init(source: t.source, target: t.target, category: cat))
        }

        // 3️⃣ 정렬(긴 용어 우선)
        entries.sort { $0.source.count > $1.source.count }

        return entries
    }
}
