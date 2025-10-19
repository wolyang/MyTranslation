// File: GlossaryStore.swift
import Foundation
import SwiftData

private struct GlossarySeedIndex {
    private struct AliasKey: Hashable {
        let personId: String
        let target: String?
        let sourcesFingerprint: String

        init(personId: String, sources: [String], target: String?) {
            self.personId = personId
            self.target = target?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSources = sources
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            self.sourcesFingerprint = normalizedSources.joined(separator: "\u{001F}")
        }
    }

    private static func normalize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                results.append(trimmed)
            }
        }
        return results
    }

    static var empty: GlossarySeedIndex { .init() }

    private let termVariantsBySource: [String: [String]]
    private let familyVariantsByPersonId: [String: [String]]
    private let givenVariantsByPersonId: [String: [String]]
    private let aliasVariantsByKey: [AliasKey: [String]]

    private init(
        termVariantsBySource: [String: [String]] = [:],
        familyVariantsByPersonId: [String: [String]] = [:],
        givenVariantsByPersonId: [String: [String]] = [:],
        aliasVariantsByKey: [AliasKey: [String]] = [:]
    ) {
        self.termVariantsBySource = termVariantsBySource
        self.familyVariantsByPersonId = familyVariantsByPersonId
        self.givenVariantsByPersonId = givenVariantsByPersonId
        self.aliasVariantsByKey = aliasVariantsByKey
    }

    static func load() -> GlossarySeedIndex {
        guard let url = Bundle.main.url(forResource: "glossary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(GlossaryJSON.self, from: data)
        else {
            return .empty
        }

        var termVariants: [String: [String]] = [:]
        for term in decoded.terms {
            let variants = normalize(term.variants)
            if variants.isEmpty == false {
                termVariants[term.source] = variants
            }
        }

        var familyVariants: [String: [String]] = [:]
        var givenVariants: [String: [String]] = [:]
        var aliasVariants: [AliasKey: [String]] = [:]

        for person in decoded.people {
            let family = normalize(person.name.family.variants)
            if family.isEmpty == false {
                familyVariants[person.person_id] = family
            }

            let given = normalize(person.name.given.variants)
            if given.isEmpty == false {
                givenVariants[person.person_id] = given
            }

            for alias in person.aliases {
                let variants = normalize(alias.variants)
                if variants.isEmpty { continue }
                let key = AliasKey(personId: person.person_id, sources: alias.source, target: alias.target)
                aliasVariants[key] = variants
            }
        }

        return .init(
            termVariantsBySource: termVariants,
            familyVariantsByPersonId: familyVariants,
            givenVariantsByPersonId: givenVariants,
            aliasVariantsByKey: aliasVariants
        )
    }

    func termVariants(for source: String) -> [String] {
        termVariantsBySource[source] ?? []
    }

    func familyVariants(for personId: String) -> [String] {
        familyVariantsByPersonId[personId] ?? []
    }

    func givenVariants(for personId: String) -> [String] {
        givenVariantsByPersonId[personId] ?? []
    }

    func aliasVariants(personId: String, sources: [String], target: String?) -> [String] {
        aliasVariantsByKey[AliasKey(personId: personId, sources: sources, target: target)] ?? []
    }
}

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
    private let seedIndex: GlossarySeedIndex

    init(context: ModelContext) {
        self.context = context
        self.seedIndex = GlossarySeedIndex.load()
    }

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
        let seedIndex = self.seedIndex

        // 1️⃣ People
        let people: [Person] = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        for p in people {
            let mergedFamilyVariants = Self.mergeVariants(primary: p.familyVariants, fallback: seedIndex.familyVariants(for: p.personId))
            let mergedGivenVariants = Self.mergeVariants(primary: p.givenVariants, fallback: seedIndex.givenVariants(for: p.personId))

            let familyTargets = Self.makeTargetList(primary: p.familyTarget, variants: mergedFamilyVariants)
            let givenTargets = Self.makeTargetList(primary: p.givenTarget, variants: mergedGivenVariants)

            // family/given 풀네임 후보 생성(구분자: "", " ", "·", "・", "-")
            let seps = ["", " ", "·", "・", "-"]
            let fullVariants: [String] = {
                guard !familyTargets.isEmpty, !givenTargets.isEmpty else { return [] }
                var combos: [String] = []
                var seenCombos = Set<String>()
                for family in familyTargets {
                    for given in givenTargets {
                        let spaced = "\(family) \(given)"
                        Self.append(&combos, seen: &seenCombos, candidate: spaced)
                        let tight = "\(family)\(given)"
                        Self.append(&combos, seen: &seenCombos, candidate: tight)
                    }
                }
                return combos
            }()
            for f in p.familySources {
                for g in p.givenSources {
                    for s in seps {
                        let full = f + s + g
                        let fullKo = [p.familyTarget, p.givenTarget].compactMap { $0 }.joined(separator: " ")
                        if !fullKo.isEmpty {
                            entries.append(
                                .init(
                                    source: full,
                                    target: fullKo,
                                    variants: fullVariants,
                                    category: .person,
                                    personId: p.personId,
                                    sourceForms: [full]
                                )
                            )
                        }
                    }
                }
            }
            // 단일 성/이름
            if let ft = p.familyTarget {
                for fs in p.familySources {
                    entries.append(
                        .init(
                            source: fs,
                            target: ft,
                            variants: mergedFamilyVariants,
                            category: .person,
                            personId: p.personId,
                            sourceForms: p.familySources
                        )
                    )
                }
            }
            if let gt = p.givenTarget {
                for gs in p.givenSources {
                    entries.append(
                        .init(
                            source: gs,
                            target: gt,
                            variants: mergedGivenVariants,
                            category: .person,
                            personId: p.personId,
                            sourceForms: p.givenSources
                        )
                    )
                }
            }
            // alias
            for a in p.aliases {
                let tgt = a.target // nil 가능
                for s in a.sources {
                    if let tgt = tgt, !tgt.isEmpty {
                        let aliasVariants = Self.mergeVariants(
                            primary: a.variants,
                            fallback: seedIndex.aliasVariants(personId: p.personId, sources: a.sources, target: a.target)
                        )
                        entries.append(
                            .init(
                                source: s,
                                target: tgt,
                                variants: aliasVariants,
                                category: .person,
                                personId: p.personId,
                                sourceForms: a.sources
                            )
                        )
                    }
                }
            }
        }

        // 2️⃣ Terms
        let terms: [Term] = try fetchTerms(query: nil)
        for t in terms {
            let cat = TermCategory(with: t.category)
            let mergedVariants = Self.mergeVariants(primary: t.variants, fallback: seedIndex.termVariants(for: t.source))
            entries.append(.init(source: t.source, target: t.target, variants: mergedVariants, category: cat))
        }

        // 3️⃣ 정렬(긴 용어 우선)
        entries.sort { $0.source.count > $1.source.count }

        return entries
    }
}

private extension DefaultGlossaryStore {
    static func mergeVariants(primary: [String], fallback: [String]) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for value in primary + fallback {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                results.append(trimmed)
            }
        }
        return results
    }

    static func makeTargetList(primary: String?, variants: [String]) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        if let primary = primary?.trimmingCharacters(in: .whitespacesAndNewlines), !primary.isEmpty {
            results.append(primary)
            seen.insert(primary)
        }
        for variant in variants {
            append(&results, seen: &seen, candidate: variant)
        }
        return results
    }

    static func append(_ array: inout [String], seen: inout Set<String>, candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if seen.insert(trimmed).inserted {
            array.append(trimmed)
        }
    }
}
