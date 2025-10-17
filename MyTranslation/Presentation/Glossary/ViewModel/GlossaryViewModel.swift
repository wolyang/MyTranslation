// File: GlossaryViewModel.swift
import Foundation
import SwiftData

@MainActor
final class GlossaryViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var terms: [Term] = []
    @Published var isPresentingEditor: Bool = false
    @Published var editingTerm: Term? = nil
    @Published var selectedCategory: String = "전체"

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func refresh() {
        // 1) 우선 카테고리만 DB에서 걸러서 가져오기 (이건 SQL로 안전)
        var desc = FetchDescriptor<Term>()
        desc.sortBy = [SortDescriptor(\.source, order: .forward)]

        if selectedCategory != "전체" {
            let cat = selectedCategory
            desc.predicate = #Predicate<Term> { ($0.category ?? "") == cat }
        }

        let fetched = (try? modelContext.fetch(desc)) ?? []

        // 2) 검색어는 메모리에서 로케일 친화적으로 필터
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            terms = fetched
        } else {
            terms = fetched.filter {
                $0.source.localizedStandardContains(q)
                || $0.target.localizedStandardContains(q)
                || ($0.notes?.localizedStandardContains(q) ?? false)
            }
        }
    }

    func addNew() { editingTerm = nil; isPresentingEditor = true }
    func edit(_ term: Term) { editingTerm = term; isPresentingEditor = true }

    func upsert(_ t: Term) {
        if let existing = editingTerm {
            existing.source = t.source
            existing.target = t.target
            existing.strict = t.strict
            existing.variants = t.variants
            existing.notes = t.notes
        } else {
            modelContext.insert(t)
        }
        try? modelContext.save()
        isPresentingEditor = false
        editingTerm = nil
        refresh()
    }

    func delete(at offsets: IndexSet) {
        for idx in offsets { modelContext.delete(terms[idx]) }
        try? modelContext.save()
        refresh()
    }

    // MARK: - Import / Export
    func exportJSON(to url: URL) {
        let payload = GlossaryJSON(
            meta: .init(version: 1, lang: "zh->ko"),
            terms: terms.map {
                .init(source: $0.source, target: $0.target,
                      strict: $0.strict, variants: $0.variants, notes: $0.notes, category: $0.category)
            }
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch { print("Export error:", error) }
    }

    func importJSON(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GlossaryJSON.self, from: data)
            let all: [Term] = (try? modelContext.fetch(FetchDescriptor<Term>())) ?? []
            let existingBySource = Dictionary(uniqueKeysWithValues: all.map { ($0.source, $0) })
            for item in decoded.terms {
                if let exist = existingBySource[item.source] {
                    exist.target = item.target
                    exist.strict = item.strict ?? true
                    exist.variants = item.variants ?? []
                    exist.notes = item.notes
                    exist.category = item.category ?? exist.category
                } else {
                    modelContext.insert(
                        Term(source: item.source,
                             target: item.target,
                             strict: item.strict ?? true,
                             variants: item.variants ?? [],
                             notes: item.notes,
                             category: item.category)
                    )
                }
            }
            try modelContext.save()
            refresh()
        } catch { print("Import error:", error) }
    }
}
