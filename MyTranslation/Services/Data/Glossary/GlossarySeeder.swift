// Services/GlossarySeeder.swift
import Foundation
import SwiftData

enum GlossarySeeder {
    private static let seededVersionKey = "seededTermsVersion"

    static func seedIfNeeded(_ modelContext: ModelContext) {
        guard let url = Bundle.main.url(forResource: "glossary", withExtension: "json") else {
            print("GlossarySeeder: glossary.json not found"); return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GlossaryJSON.self, from: data)

            // 개발 중엔 항상 갱신(배포 전엔 버전가드 복구)
            try seedPeople(decoded.people, in: modelContext)
            try seedTerms(decoded.terms, in: modelContext)
            try modelContext.save()

            UserDefaults.standard.set(decoded.meta.version, forKey: seededVersionKey)
            print("GlossarySeeder: seeded v\(decoded.meta.version) (people:\(decoded.people.count), terms:\(decoded.terms.count))")
        } catch {
            print("GlossarySeeder error:", error)
        }
    }

    private static func uniqSorted(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for v in arr.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            if seen.insert(v).inserted { order.append(v) }
        }
        return order.sorted { (a, b) in
            if a.count != b.count { return a.count > b.count } // 길이 내림차순(최장일치 유리)
            return a < b
        }
    }

    // PEOPLE
    private static func seedPeople(_ items: [GlossaryJSON.PersonItem], in ctx: ModelContext) throws {
        let existing = (try? ctx.fetch(FetchDescriptor<Person>())) ?? []
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.personId, $0) })

        for p in items {
            let person = byId[p.person_id] ?? {
                let np = Person(personId: p.person_id)
                ctx.insert(np); byId[p.person_id] = np
                return np
            }()

            person.familySources = uniqSorted(p.name.family.source)
            person.givenSources  = uniqSorted(p.name.given.source)
            person.familyTarget  = p.name.family.target
            person.givenTarget   = p.name.given.target
            person.familyVariants = uniqSorted(p.name.family.variants)
            person.givenVariants  = uniqSorted(p.name.given.variants)

            // aliases: target별로 source 병합
            var exByTarget = Dictionary(uniqueKeysWithValues: person.aliases.map { (($0.target ?? "<nil>"), $0) })
            var newAliases: [Alias] = []
            for a in p.aliases {
                let key = a.target ?? "<nil>"
                if let ex = exByTarget[key] {
                    ex.sources = uniqSorted(ex.sources + a.source)
                    ex.variants = uniqSorted(ex.variants + a.variants)
                    newAliases.append(ex)
                } else {
                    newAliases.append(Alias(sources: uniqSorted(a.source), target: a.target, variants: uniqSorted(a.variants), person: person))
                }
            }
            person.aliases = newAliases
        }
    }

    // TERMS
    private static func seedTerms(_ items: [GlossaryJSON.TermItem], in ctx: ModelContext) throws {
        let existing = (try? ctx.fetch(FetchDescriptor<Term>())) ?? []
        var bySource = Dictionary(uniqueKeysWithValues: existing.map { ($0.source, $0) })
        for t in items {
            if let ex = bySource[t.source] {
                ex.target = t.target
                ex.category = t.category
                ex.variants = uniqSorted(t.variants)
            } else {
                let nt = Term(source: t.source, target: t.target, category: t.category, variants: uniqSorted(t.variants))
                ctx.insert(nt); bySource[t.source] = nt
            }
        }
    }
}
