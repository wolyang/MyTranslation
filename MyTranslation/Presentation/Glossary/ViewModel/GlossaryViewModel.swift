// File: GlossaryViewModel.swift
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class GlossaryViewModel: ObservableObject {
    @Published var query: String = "" { didSet { refresh() } }
    @Published private(set) var terms: [Term] = []
    @Published private(set) var people: [Person] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        refresh()
    }

    func refresh() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Terms
            if q.isEmpty {
                let descriptor = FetchDescriptor<Term>(sortBy: [SortDescriptor(\.source, comparator: .localizedStandard)])
                terms = try modelContext.fetch(descriptor)
            } else {
                let predicate: Predicate<Term> = #Predicate { t in
                    t.source.localizedStandardContains(q) ||
                        t.target.localizedStandardContains(q) ||
                        t.category.localizedStandardContains(q)
                }
                let descriptor = FetchDescriptor<Term>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.source, comparator: .localizedStandard)]
                )
                terms = try modelContext.fetch(descriptor)
            }
            // People
            if q.isEmpty {
                let pDesc = FetchDescriptor<Person>(sortBy: [SortDescriptor(\.personId, comparator: .localizedStandard)])
                people = try modelContext.fetch(pDesc)
            } else {
                // 간단히 전량 fetch 후 메모리 필터 (배열/관계 포함 검색)
                let all = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
                people = all.filter { p in
                    func haystack() -> [String] {
                        var h: [String] = []
                        h.append(p.personId)
                        h.append(contentsOf: p.familySources)
                        h.append(contentsOf: p.givenSources)
                        if let ft = p.familyTarget { h.append(ft) }
                        if let gt = p.givenTarget { h.append(gt) }
                        h.append(contentsOf: p.familyVariants)
                        h.append(contentsOf: p.givenVariants)
                        for a in p.aliases { h.append(contentsOf: a.sources); if let t = a.target { h.append(t) } }
                        for a in p.aliases { h.append(contentsOf: a.variants) }
                        return h
                    }
                    return haystack().contains { $0.localizedStandardContains(q) }
                }
                // 정렬: 표시명 기준
                people.sort { displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending }
            }
        } catch {
            print("[GlossaryVM] fetch error: \(error)")
            terms = []
            people = []
        }
    }

    // 표시용 이름: target 우선, 없으면 source 사용
    func displayName(for p: Person) -> String {
        let family = p.familyTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given  = p.givenTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = (family?.isEmpty == false) ? family! : (p.familySources.first ?? "")
        let g = (given?.isEmpty == false) ? given!  : (p.givenSources.first  ?? "")
        let name = [f,g].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? p.personId : name
    }

    func upsert(term: Term?, source: String, target: String, category: String, isEnabled: Bool) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }

        // 동일 source 존재 시 업데이트, 없으면 생성
        if let term {
            term.source = s
            term.target = t
            term.category = c
            term.isEnabled = isEnabled
        } else {
            if let exist = try? modelContext.fetch(FetchDescriptor<Term>(predicate: #Predicate { $0.source == s })).first {
                exist.target = t
                exist.category = c
                exist.isEnabled = isEnabled
            } else {
                let term = Term(source: s, target: t, category: c, isEnabled: isEnabled)
                modelContext.insert(term)
            }
        }
        try? modelContext.save()
        refresh()
    }

    func delete(_ term: Term) {
        modelContext.delete(term)
        try? modelContext.save()
        refresh()
    }

    // MARK: - People CRUD
    func createPerson(personId: String,
                      familySources: [String],
                      familyTarget: String?,
                      givenSources: [String],
                      givenTarget: String?,
                      aliases: [(sources: [String], target: String?)]) {
        guard !personId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let p = Person(personId: personId,
                       familySources: familySources,
                       familyTarget: familyTarget,
                       givenSources: givenSources,
                       givenTarget: givenTarget,
                       aliases: [])
        p.familyVariants = []
        p.givenVariants = []
        // aliases
        p.aliases = aliases.map { Alias(sources: $0.sources, target: $0.target, variants: [], person: p) }
        modelContext.insert(p)
        try? modelContext.save()
        refresh()
    }

    func updatePerson(_ person: Person,
                      familySources: [String],
                      familyTarget: String?,
                      givenSources: [String],
                      givenTarget: String?,
                      aliases: [(sources: [String], target: String?)]) {
        person.familySources = familySources
        person.familyTarget  = familyTarget
        person.familyVariants = []
        person.givenSources  = givenSources
        person.givenTarget   = givenTarget
        person.givenVariants = []
        // 단순화: 기존 별칭을 교체
        person.aliases = aliases.map { Alias(sources: $0.sources, target: $0.target, variants: [], person: person) }
        try? modelContext.save()
        refresh()
    }

    func deletePerson(_ person: Person) {
        modelContext.delete(person)
        try? modelContext.save()
        refresh()
    }
    
    func importJSON(from url: URL) throws {
        let data = try Data(contentsOf: url)
        // v3: GlossaryJSONDocument(payload: GlossaryJSON)
        let doc = try JSONDecoder().decode(GlossaryJSON.self, from: data)

        for item in doc.terms {
            if let exist = try? modelContext.fetch(FetchDescriptor<Term>(predicate: #Predicate { $0.source == item.source })).first {
                exist.target = item.target
                exist.category = item.category
                exist.variants = item.variants
                exist.isEnabled = item.isEnabled
            } else {
                let t = Term(
                    source: item.source,
                    target: item.target,
                    category: item.category,
                    variants: item.variants,
                    isEnabled: item.isEnabled
                )
                modelContext.insert(t)
            }
        }
        try modelContext.save()
        refresh()
    }

    /// fileImporter onCompletion 어댑터: View에서 직접 넘겨 쓰기 용도
    func importFromPicker(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do { try importJSON(from: url) } catch {
                print("import error: \(error)")
            }
        case .failure(let err):
            print("import picker error: \(err)")
        }
    }

    func makeExportDocument() -> GlossaryJSONDocument {
        let items = terms.map {
            GlossaryJSON.TermItem(
                source: $0.source,
                target: $0.target,
                category: $0.category,
                variants: $0.variants,
                isEnabled: $0.isEnabled
            )
        }
        let payload = GlossaryJSON(terms: items, people: [])
        return GlossaryJSONDocument(payload: payload)
    }

    func term(for identifier: PersistentIdentifier?) -> Term? {
        guard let identifier else { return nil }
        return (try? modelContext.model(for: identifier)) as? Term
    }

    func person(for identifier: PersistentIdentifier?) -> Person? {
        guard let identifier else { return nil }
        return (try? modelContext.model(for: identifier)) as? Person
    }
}
