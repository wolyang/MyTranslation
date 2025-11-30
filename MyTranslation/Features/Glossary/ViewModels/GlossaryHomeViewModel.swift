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
        let pattern: Glossary.SDModel.SDPattern
        let meta: Glossary.SDModel.SDPatternMeta?
    }

    struct TermRow: Identifiable, Hashable {
        struct ComponentInfo: Hashable {
            let pattern: String
            let role: String?
            let groups: [Group]

            struct Group: Hashable { let uid: String; let name: String }
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
            let template = pattern.pattern.targetTemplate
            let roleToFill = comp.role ?? pattern.roles.first
            guard let roleToFill else { return target }

            // 단일 Term가 맡은 role 자리에만 target을 채워 넣고, 나머지는 플레이스홀더 그대로 둔다.
            let filled = template.replacingOccurrences(of: "{\(roleToFill)}", with: rawTerm.target)
            return filled
        }
    }

    struct PatternGroupRow: Identifiable, Hashable {
        let id: String
        let name: String
        let componentTerms: [Glossary.SDModel.SDTerm]
        let badgeTargets: [String]
    }
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

    func resetGlossary() async throws {
        isLoading = true
        defer { isLoading = false }
        let termDesc = FetchDescriptor<Glossary.SDModel.SDTerm>()
        let sourceDesc = FetchDescriptor<Glossary.SDModel.SDSource>()
        let sourceIndexDesc = FetchDescriptor<Glossary.SDModel.SDSourceIndex>()
        let componentDesc = FetchDescriptor<Glossary.SDModel.SDComponent>()
        let componentGroupDesc = FetchDescriptor<Glossary.SDModel.SDComponentGroup>()
        let tagLinkDesc = FetchDescriptor<Glossary.SDModel.SDTermTagLink>()
        let patternDesc = FetchDescriptor<Glossary.SDModel.SDPattern>()
        let metaDesc = FetchDescriptor<Glossary.SDModel.SDPatternMeta>()
        let tagDesc = FetchDescriptor<Glossary.SDModel.SDTag>()
        let groupDesc = FetchDescriptor<Glossary.SDModel.SDGroup>()
        do {
            let componentGroups = try context.fetch(componentGroupDesc)
            componentGroups.forEach { context.delete($0) }
            let tagLinks = try context.fetch(tagLinkDesc)
            tagLinks.forEach { context.delete($0) }
            let sources = try context.fetch(sourceDesc)
            sources.forEach { context.delete($0) }
            let sourceIndexes = try context.fetch(sourceIndexDesc)
            sourceIndexes.forEach { context.delete($0) }
            let components = try context.fetch(componentDesc)
            components.forEach { context.delete($0) }
            let terms = try context.fetch(termDesc)
            terms.forEach { context.delete($0) }
            let patterns = try context.fetch(patternDesc)
            patterns.forEach { context.delete($0) }
            let metas = try context.fetch(metaDesc)
            metas.forEach { context.delete($0) }
            let tags = try context.fetch(tagDesc)
            tags.forEach { context.delete($0) }
            let groups = try context.fetch(groupDesc)
            groups.forEach { context.delete($0) }
            try context.save()
            await reloadAll()
        } catch {
            errorMessage = nil
            throw error
        }
    }

    func resetFilters() {
        searchText = ""
        selectedTagNames = []
        selectedPatternID = nil
        selectedGroupUIDs = []
    }

    func setPattern(_ pattern: PatternSummary?) {
        if selectedPatternID != pattern?.id {
            selectedGroupUIDs = []
        }
        selectedPatternID = pattern?.id
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
            let dup = Glossary.SDModel.SDComponent(pattern: comp.pattern, role: comp.role, term: clone)
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
                roles: pattern.roles,
                grouping: meta?.grouping ?? .none,
                groupLabel: meta?.groupLabel ?? "그룹",
                isAppellation: pattern.isAppellation,
                preMask: pattern.preMask,
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
                return .init(
                    pattern: comp.pattern,
                    role: comp.role,
                    groups: comp.groupLinks.map({ .init(uid: $0.group.uid, name: groupLookup[$0.group.uid]?.name ?? "") })
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
                for group in comp.groups {
                    var bucket = grouped[group.uid, default: GroupBucket()]
                    bucket.terms.append(row.rawTerm)
                    bucket.rows.append(row)
                    if bucket.name == nil { bucket.name = group.name }
                    grouped[group.uid] = bucket
                }
            }
        }
        for (uid, bucket) in grouped {
            let name = bucket.name ?? uid
            groups.append(PatternGroupRow(id: uid, name: name, componentTerms: bucket.terms, badgeTargets: bucket.terms.map { $0.target }))
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
                    comp.pattern == pattern.id && !Set(comp.groups.map({ $0.uid })).isDisjoint(with: selectedGroupUIDs)
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

    var shouldShowGroupList: Bool {
        guard selectedPatternID != nil else { return false }
        return patternGroups.isEmpty == false
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
