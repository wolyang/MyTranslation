import Foundation
import SwiftData

@MainActor
extension TermEditorViewModel {
    func fetchAllTermsForPicker() throws -> [TermPickerItem] {
        let descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(
            sortBy: [SortDescriptor(\.target)]
        )
        let terms = try context.fetch(descriptor)
        return terms.map { term in
            TermPickerItem(
                key: term.key,
                target: term.target,
                sourcePreview: term.sources.first?.text ?? ""
            )
        }
    }

    func termTarget(for key: String) -> String? {
        let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.key == key }
        let descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: predicate)
        return try? context.fetch(descriptor).first?.target
    }

    static func fetchPattern(id: String, context: ModelContext) throws -> PatternReference {
        guard let pattern = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == id })).first else {
            throw NSError(domain: "TermEditor", code: 0, userInfo: [NSLocalizedDescriptionKey: "패턴을 찾을 수 없습니다."])
        }
        let meta = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>(predicate: #Predicate { $0.name == id })).first
        let groups = try fetchGroups(patternID: id, context: context)
        return PatternReference(pattern: pattern, meta: meta, groups: groups)
    }

    static func fetchGroups(patternID: String, context: ModelContext) throws -> [Glossary.SDModel.SDGroup] {
        let desc = FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: #Predicate { $0.pattern == patternID })
        return try context.fetch(desc)
    }

    static func loadPatternOptions(context: ModelContext) throws -> [PatternOption] {
        let patterns = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>())
        let metas = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>())
        let groups = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>())
        let metaMap = Dictionary(uniqueKeysWithValues: metas.map { ($0.name, $0) })
        let groupsMap = Dictionary(grouping: groups, by: { $0.pattern })
        return patterns.map { pattern in
            let meta = metaMap[pattern.name]
            let displayName = meta?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? pattern.name
            let metaRoles = pattern.roles // FIXME: Pattern 리팩토링 임시 처리
            let roleOptions: [String] = metaRoles
            let grouping = meta?.grouping ?? .none
            let groupLabel = meta?.groupLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "그룹"
            let groupOptions = (groupsMap[pattern.name] ?? []).map { GroupOption(id: $0.uid, name: $0.name) }.sorted { $0.name < $1.name }
            return PatternOption(
                id: pattern.name,
                displayName: displayName,
                grouping: grouping,
                groupLabel: groupLabel,
                roleOptions: roleOptions,
                sourceTemplates: pattern.sourceTemplates,
                targetTemplate: pattern.targetTemplate,
                variantTemplates: pattern.variantTemplates,
                groups: groupOptions
            )
        }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
