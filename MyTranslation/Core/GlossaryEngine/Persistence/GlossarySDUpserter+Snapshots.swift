import Foundation
import SwiftData

extension Glossary.SDModel.GlossaryUpserter {
    // MARK: - Snapshot models
    struct TermSnapshot: Hashable {
        let target: String
        let variants: [String]
        let tags: Set<String>
        let sources: Set<SourceSnapshot>
        let components: Set<ComponentSnapshot>
        let isAppellation: Bool
        let preMask: Bool
        let activatorKeys: Set<String>
    }

    struct SourceSnapshot: Hashable {
        let text: String
        let prohibitStandalone: Bool
    }

    struct ComponentSnapshot: Hashable {
        let pattern: String
        let roleKey: String
        let groupKey: String
        let srcTplIdx: Int?
        let tgtTplIdx: Int?
    }

    struct PatternSnapshot: Hashable {
        let name: String
        let left: SelectorSnapshot
        let right: SelectorSnapshot
        let skipPairsIfSameTerm: Bool
        let sourceTemplates: [String]
        let targetTemplates: [String]
        let sourceJoiners: [String]
        let isAppellation: Bool
        let preMask: Bool
        let needPairCheck: Bool
        let displayName: String
        let roles: [String]
        let grouping: Glossary.SDModel.SDPatternGrouping
        let groupLabel: String
        let defaultProhibitStandalone: Bool
        let defaultIsAppellation: Bool
        let defaultPreMask: Bool
    }

    struct SelectorSnapshot: Hashable {
        let role: String?
        let tagsAll: [String]
        let tagsAny: [String]
        let includeKeys: [String]
        let excludeKeys: [String]
    }

    // MARK: - Snapshot builders
    func termSnapshot(of term: Glossary.SDModel.SDTerm) -> TermSnapshot {
        let sourceSet = Set(term.sources.map { SourceSnapshot(text: $0.text, prohibitStandalone: $0.prohibitStandalone) })
        let componentSet = Set(term.components.map { comp in
            let groups = comp.groupLinks.map { $0.group.name }
            return ComponentSnapshot(
                pattern: comp.pattern,
                roleKey: normalizedRoleKey(comp.role),
                groupKey: groupKey(of: groups),
                srcTplIdx: comp.srcTplIdx,
                tgtTplIdx: comp.tgtTplIdx
            )
        })
        let activators = Set(term.activators.map { $0.key })
        let tags = Set(term.termTagLinks.map { $0.tag.name })
        return TermSnapshot(
            target: term.target,
            variants: orderedUnique(term.variants),
            tags: tags,
            sources: sourceSet,
            components: componentSet,
            isAppellation: term.isAppellation,
            preMask: term.preMask,
            activatorKeys: activators
        )
    }

    func termSnapshot(of term: JSTerm) -> TermSnapshot {
        let sourceSet = Set(term.sources.map { SourceSnapshot(text: $0.source, prohibitStandalone: $0.prohibitStandalone) })
        let componentSet = Set(term.components.map { comp in
            ComponentSnapshot(
                pattern: comp.pattern,
                roleKey: normalizedRoleKey(comp.role),
                groupKey: groupKey(of: comp.groups),
                srcTplIdx: comp.srcTplIdx,
                tgtTplIdx: comp.tgtTplIdx
            )
        })
        let activators = Set(normalizedActivatorKeys(term.activatedByKeys, termKey: term.key))
        return TermSnapshot(
            target: term.target,
            variants: orderedUnique(term.variants),
            tags: Set(term.tags),
            sources: sourceSet,
            components: componentSet,
            isAppellation: term.isAppellation,
            preMask: term.preMask,
            activatorKeys: activators
        )
    }

    func patternSnapshot(of pattern: Glossary.SDModel.SDPattern, meta: Glossary.SDModel.SDPatternMeta?) -> PatternSnapshot {
        PatternSnapshot(
            name: pattern.name,
            left: selectorSnapshot(role: pattern.leftRole, tagsAll: pattern.leftTagsAll, tagsAny: pattern.leftTagsAny, include: pattern.leftIncludeTerms, exclude: pattern.leftExcludeTerms),
            right: selectorSnapshot(role: pattern.rightRole, tagsAll: pattern.rightTagsAll, tagsAny: pattern.rightTagsAny, include: pattern.rightIncludeTerms, exclude: pattern.rightExcludeTerms),
            skipPairsIfSameTerm: pattern.skipPairsIfSameTerm,
            sourceTemplates: pattern.sourceTemplates,
            targetTemplates: pattern.targetTemplates,
            sourceJoiners: pattern.sourceJoiners,
            isAppellation: pattern.isAppellation,
            preMask: pattern.preMask,
            needPairCheck: pattern.needPairCheck,
            displayName: meta?.displayName ?? pattern.name,
            roles: meta?.roles ?? [],
            grouping: meta?.grouping ?? .optional,
            groupLabel: meta?.groupLabel ?? Glossary.SDModel.Defaults.groupLabel,
            defaultProhibitStandalone: meta?.defaultProhibitStandalone ?? true,
            defaultIsAppellation: meta?.defaultIsAppellation ?? false,
            defaultPreMask: meta?.defaultPreMask ?? false
        )
    }

    func patternSnapshot(of pattern: JSPattern, meta _: Glossary.SDModel.SDPatternMeta?) -> PatternSnapshot {
        let trimmedDisplay = pattern.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDisplay.isEmpty ? pattern.name : trimmedDisplay
        let trimmedLabel = pattern.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupLabel = trimmedLabel.isEmpty ? Glossary.SDModel.Defaults.groupLabel : trimmedLabel
        return PatternSnapshot(
            name: pattern.name,
            left: selectorSnapshot(pattern.left),
            right: selectorSnapshot(pattern.right),
            skipPairsIfSameTerm: pattern.skipPairsIfSameTerm,
            sourceTemplates: pattern.sourceTemplates,
            targetTemplates: pattern.targetTemplates,
            sourceJoiners: pattern.sourceJoiners.isEmpty ? [""] : pattern.sourceJoiners,
            isAppellation: pattern.isAppellation,
            preMask: pattern.preMask,
            needPairCheck: pattern.needPairCheck,
            displayName: displayName,
            roles: pattern.roles,
            grouping: Glossary.SDModel.SDPatternGrouping(rawValue: pattern.grouping.rawValue) ?? .optional,
            groupLabel: groupLabel,
            defaultProhibitStandalone: pattern.defaultProhibitStandalone,
            defaultIsAppellation: pattern.defaultIsAppellation,
            defaultPreMask: pattern.defaultPreMask
        )
    }

    private func selectorSnapshot(_ selector: JSTermSelector?) -> SelectorSnapshot {
        guard let selector else {
            return SelectorSnapshot(role: nil, tagsAll: [], tagsAny: [], includeKeys: [], excludeKeys: [])
        }
        return SelectorSnapshot(
            role: selector.role,
            tagsAll: (selector.tagsAll ?? []).sorted(),
            tagsAny: (selector.tagsAny ?? []).sorted(),
            includeKeys: (selector.includeTermKeys ?? []).sorted(),
            excludeKeys: (selector.excludeTermKeys ?? []).sorted()
        )
    }

    private func selectorSnapshot(role: String?, tagsAll: [String], tagsAny: [String], include: [Glossary.SDModel.SDTerm], exclude: [Glossary.SDModel.SDTerm]) -> SelectorSnapshot {
        SelectorSnapshot(
            role: role,
            tagsAll: tagsAll.sorted(),
            tagsAny: tagsAny.sorted(),
            includeKeys: include.map { $0.key }.sorted(),
            excludeKeys: exclude.map { $0.key }.sorted()
        )
    }

    // MARK: - Key helpers
    func normalizedRoleKey(_ role: String?) -> String {
        guard let role else { return "-" }
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-" : trimmed
    }

    func groupKey(of names: [String]?) -> String {
        guard let names, !names.isEmpty else { return "-" }
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "-" }
        let unique = Set(trimmed)
        return unique.sorted().joined(separator: ",")
    }
}
