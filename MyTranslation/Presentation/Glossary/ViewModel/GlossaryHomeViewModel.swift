import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class GlossaryHomeViewModel {
    struct PatternSummary: Identifiable, Hashable {
        let id: String
        let name: String
        let displayName: String
        let roles: [String]
        let grouping: Glossary.SDModel.SDPatternGrouping
        let groupLabel: String
        let isAppellation: Bool
        let preMask: Bool
        let leftRoles: Set<String>
        let rightRoles: Set<String>
        let pattern: Glossary.SDModel.SDPattern
        let meta: Glossary.SDModel.SDPatternMeta?
    }

    struct TermRow: Identifiable, Hashable {
        struct ComponentInfo: Hashable {
            let pattern: String
            let roles: [String]
            let groupUIDs: [String]
            let groupNames: [String]
            let srcTemplateIndex: Int?
            let tgtTemplateIndex: Int?
        }

        let id: PersistentIdentifier
        let key: String
        let target: String
        let primarySources: [String]
        let variants: [String]
        let tags: [String]
        let isAppellation: Bool
        let preMask: Bool
        let components: [ComponentInfo]
        let rawTerm: Glossary.SDModel.SDTerm

        func displayName(for pattern: PatternSummary?) -> String {
            guard let pattern else { return target }
            guard let comp = components.first(where: { $0.pattern == pattern.id }) else {
                return target
            }
            let L = rawTerm
            // 패턴이 이 Term를 어떤 역할로 참조하는지에 따라 템플릿 렌더링을 다르게 처리한다.
            let tplIndex = comp.tgtTemplateIndex ?? 0
            let template = pattern.pattern.targetTemplates.indices.contains(tplIndex) ? pattern.pattern.targetTemplates[tplIndex] : pattern.pattern.targetTemplates.first ?? "{L}"
            if pattern.rightRoles.isEmpty {
                return Glossary.Util.renderTarget(template, L: L, R: nil)
            }
            // 그룹 내 다른 Term 탐색은 외부에서 처리되므로 우선 자기 자신만 반영
            return Glossary.Util.renderTarget(template, L: L, R: nil)
        }
    }

    struct PatternGroupRow: Identifiable, Hashable {
        let id: String
        let name: String
        let displayName: String
        let componentTerms: [Glossary.SDModel.SDTerm]
        let badgeTargets: [String]
    }

    enum Segment: String, CaseIterable, Identifiable { case terms = "용어"; case groups = "그룹"; var id: String { rawValue } }

    var segment: Segment = .terms
    var searchText: String = "" { didSet { applyFilters() } }
    var selectedTagNames: Set<String> = [] { didSet { applyFilters() } }
    var selectedPatternID: String? { didSet { updateGroups(); applyFilters() } }
    var selectedGroupUIDs: Set<String> = [] { didSet { applyFilters() } }

    private let context: ModelContext

    private(set) var termRows: [TermRow] = []
    private(set) var filteredTermRows: [TermRow] = []
    private(set) var patternGroups: [PatternGroupRow] = []
    private(set) var filteredPatternGroups: [PatternGroupRow] = []
    private(set) var patterns: [PatternSummary] = []
    private(set) var availableTags: [String] = []
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String? = nil
    private var termRowMap: [PersistentIdentifier: TermRow] = [:]

    init(context: ModelContext) {
        self.context = context
    }

    func load() {
        Task { [weak self] in
            guard let self else { return }
            await self.reloadAll()
        }
    }

    func reloadAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let terms = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>())
            let patterns = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>())
            let metas = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>())
            let tags = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTag>())
            let groups = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>())
            mapPatterns(patterns: patterns, metas: metas)
            mapTerms(terms: terms, groups: groups)
            availableTags = tags.map { $0.name }.sorted()
            updateGroups()
            applyFilters()
        } catch {
            errorMessage = "데이터를 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func resetFilters() {
        searchText = ""
        selectedTagNames = []
        selectedPatternID = nil
        selectedGroupUIDs = []
    }

    func setPattern(_ pattern: PatternSummary?) {
        selectedPatternID = pattern?.id
        if pattern == nil {
            selectedGroupUIDs = []
            segment = .terms
        }
    }

    func pattern(for id: String?) -> PatternSummary? {
        guard let id else { return nil }
        return patterns.first(where: { $0.id == id })
    }

    func delete(term row: TermRow) throws {
        try Glossary.SDModel.SourceIndexMaintainer.deleteAll(for: row.rawTerm, in: context)
        context.delete(row.rawTerm)
        try context.save()
        try refreshAfterMutation()
    }

    func duplicate(term row: TermRow) throws -> Glossary.SDModel.SDTerm {
        let term = row.rawTerm
        let clone = Glossary.SDModel.SDTerm(key: uniqueKey(basedOn: term.key), target: term.target, variants: term.variants, isAppellation: term.isAppellation, preMask: term.preMask)
        for src in term.sources {
            let dup = Glossary.SDModel.SDSource(text: src.text, prohibitStandalone: src.prohibitStandalone, term: clone)
            context.insert(dup)
            clone.sources.append(dup)
        }
        for comp in term.components {
            let dup = Glossary.SDModel.SDComponent(pattern: comp.pattern, roles: comp.roles, srcTplIdx: comp.srcTplIdx, tgtTplIdx: comp.tgtTplIdx, term: clone)
            context.insert(dup)
            clone.components.append(dup)
            for link in comp.groupLinks {
                let bridge = Glossary.SDModel.SDComponentGroup(component: dup, group: link.group)
                context.insert(bridge)
                dup.groupLinks.append(bridge)
            }
        }
        for tagLink in term.termTagLinks {
            let tag = tagLink.tag
            let link = Glossary.SDModel.SDTermTagLink(term: clone, tag: tag)
            context.insert(link)
            clone.termTagLinks.append(link)
        }
        context.insert(clone)
        try context.save()
        try refreshAfterMutation()
        return clone
    }

    func refreshAfterMutation() throws {
        let terms = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>())
        let groups = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>())
        mapTerms(terms: terms, groups: groups)
        updateGroups()
        applyFilters()
    }

    private func mapPatterns(patterns: [Glossary.SDModel.SDPattern], metas: [Glossary.SDModel.SDPatternMeta]) {
        let metaDict = Dictionary(uniqueKeysWithValues: metas.map { ($0.name, $0) })
        self.patterns = patterns.sorted { $0.name < $1.name }.map { pattern in
            let meta = metaDict[pattern.name]
            return PatternSummary(
                id: pattern.name,
                name: pattern.name,
                displayName: meta?.displayName ?? pattern.name,
                roles: meta?.roles ?? [],
                grouping: meta?.grouping ?? .none,
                groupLabel: meta?.groupLabel ?? "그룹",
                isAppellation: pattern.isAppellation,
                preMask: pattern.preMask,
                leftRoles: Set(pattern.leftRoles),
                rightRoles: Set(pattern.rightRoles),
                pattern: pattern,
                meta: meta
            )
        }
    }

    private func mapTerms(terms: [Glossary.SDModel.SDTerm], groups: [Glossary.SDModel.SDGroup]) {
        let groupLookup = Dictionary(uniqueKeysWithValues: groups.map { ($0.uid, $0) })
        termRows = terms.map { term in
            let sources = term.sources.sorted { $0.text < $1.text }
            let components = term.components.map { comp -> TermRow.ComponentInfo in
                let groupUIDs = comp.groupLinks.map { $0.group.uid }
                let groupNames = comp.groupLinks.compactMap { groupLookup[$0.group.uid]?.name }
                return .init(
                    pattern: comp.pattern,
                    roles: comp.roles ?? [],
                    groupUIDs: groupUIDs,
                    groupNames: groupNames,
                    srcTemplateIndex: comp.srcTplIdx,
                    tgtTemplateIndex: comp.tgtTplIdx
                )
            }
            let tags = term.termTagLinks.compactMap { $0.tag.name }
            return TermRow(
                id: term.persistentModelID,
                key: term.key,
                target: term.target,
                primarySources: Array(sources.prefix(3)).map { $0.text },
                variants: term.variants,
                tags: tags.sorted(),
                isAppellation: term.isAppellation,
                preMask: term.preMask,
                components: components,
                rawTerm: term
            )
        }
        termRowMap = Dictionary(uniqueKeysWithValues: termRows.map { ($0.id, $0) })
    }

    private func updateGroups() {
        guard let patternID = selectedPatternID,
              let pattern = pattern(for: patternID) else {
            patternGroups = []
            filteredPatternGroups = []
            return
        }
        var groups: [PatternGroupRow] = []
        struct GroupBucket { var terms: [Glossary.SDModel.SDTerm] = []; var rows: [TermRow] = []; var name: String? = nil }
        var grouped: [String: GroupBucket] = [:]
        for row in termRows {
            guard row.components.contains(where: { $0.pattern == pattern.id }) else { continue }
            for comp in row.components where comp.pattern == pattern.id {
                for uid in comp.groupUIDs {
                    var bucket = grouped[uid, default: GroupBucket()]
                    bucket.terms.append(row.rawTerm)
                    bucket.rows.append(row)
                    if bucket.name == nil, let name = comp.groupNames.first { bucket.name = name }
                    grouped[uid] = bucket
                }
            }
        }
        for (uid, bucket) in grouped {
            guard let firstRow = bucket.rows.first else { continue }
            let name = bucket.name ?? uid
            let tpl = pattern.pattern.targetTemplates.first ?? "{L}"
            let leftRoles = pattern.leftRoles
            let rightRoles = pattern.rightRoles
            var leftTerm: Glossary.SDModel.SDTerm? = nil
            var rightTerm: Glossary.SDModel.SDTerm? = nil
            for row in bucket.rows {
                for comp in row.components where comp.pattern == pattern.id {
                    if let role = comp.roles.first {
                        if leftRoles.contains(role) { leftTerm = row.rawTerm }
                        if rightRoles.contains(role) { rightTerm = row.rawTerm }
                    }
                }
            }
            let display = Glossary.Util.renderTarget(tpl, L: leftTerm ?? firstRow.rawTerm, R: rightTerm)
            groups.append(PatternGroupRow(id: uid, name: name, displayName: name, componentTerms: bucket.terms, badgeTargets: bucket.terms.map { $0.target }))
        }
        patternGroups = groups.sorted { $0.name < $1.name }
        filteredPatternGroups = patternGroups
    }

    private func applyFilters() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = pattern(for: selectedPatternID)
        filteredTermRows = termRows.filter { row in
            if let pattern {
                guard row.components.contains(where: { $0.pattern == pattern.id }) else { return false }
            }
            if !selectedTagNames.isEmpty {
                guard selectedTagNames.isSubset(of: Set(row.tags)) else { return false }
            }
            if !selectedGroupUIDs.isEmpty, let pattern {
                let hit = row.components.contains { comp in
                    comp.pattern == pattern.id && !Set(comp.groupUIDs).isDisjoint(with: selectedGroupUIDs)
                }
                if !hit { return false }
            }
            guard q.isEmpty || matchesSearch(row: row, query: q) else { return false }
            return true
        }
        if let pattern {
            filteredTermRows.sort { lhs, rhs in
                lhs.displayName(for: pattern).localizedCaseInsensitiveCompare(rhs.displayName(for: pattern)) == .orderedAscending
            }
        } else {
            filteredTermRows.sort { lhs, rhs in
                lhs.target.localizedCaseInsensitiveCompare(rhs.target) == .orderedAscending
            }
        }
        if selectedGroupUIDs.isEmpty {
            filteredPatternGroups = patternGroups
        } else {
            filteredPatternGroups = patternGroups.filter { selectedGroupUIDs.contains($0.id) }
        }
    }

    private func matchesSearch(row: TermRow, query: String) -> Bool {
        if row.target.localizedCaseInsensitiveContains(query) { return true }
        if row.primarySources.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if row.variants.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        if row.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        return false
    }

    private func uniqueKey(basedOn key: String) -> String {
        var index = 2
        var candidate = key + "-복제"
        while hasTerm(key: candidate) {
            candidate = key + "-복제\(index)"
            index += 1
        }
        return candidate
    }

    private func hasTerm(key: String) -> Bool {
        (try? context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: #Predicate { $0.key == key })).isEmpty == false) ?? false
    }
}
