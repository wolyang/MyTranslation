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
    }

    struct PatternSnapshot: Hashable {
        let name: String
        let skipPairsIfSameTerm: Bool
        let sourceTemplates: [String]
        let targetTemplate: String
        let variantTemplates: [String]
        let isAppellation: Bool
        let preMask: Bool
        let displayName: String
        let roles: [String]
        let grouping: Glossary.SDModel.SDPatternGrouping
        let groupLabel: String
        let defaultProhibitStandalone: Bool
        let defaultIsAppellation: Bool
        let defaultPreMask: Bool
    }

    // MARK: - Snapshot builders
    func termSnapshot(of term: Glossary.SDModel.SDTerm) -> TermSnapshot {
        let sourceSet = Set(term.sources.map { SourceSnapshot(text: $0.text, prohibitStandalone: $0.prohibitStandalone) })
        let componentSet = Set(term.components.map { comp in
            let groups = comp.groupLinks.map { $0.group.name }
            return ComponentSnapshot(
                pattern: comp.pattern,
                roleKey: normalizedRoleKey(comp.role),
                groupKey: groupKey(of: groups)
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
                groupKey: groupKey(of: comp.groups)
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
            skipPairsIfSameTerm: pattern.skipPairsIfSameTerm,
            sourceTemplates: pattern.sourceTemplates,
            targetTemplate: pattern.targetTemplate,
            variantTemplates: pattern.variantTemplates,
            isAppellation: pattern.isAppellation,
            preMask: pattern.preMask,
            displayName: meta?.displayName ?? pattern.name,
            roles: pattern.roles,
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
            skipPairsIfSameTerm: pattern.skipPairsIfSameTerm,
            sourceTemplates: pattern.sourceTemplates,
            targetTemplate: pattern.targetTemplate,
            variantTemplates: pattern.variantTemplates,
            isAppellation: pattern.isAppellation,
            preMask: pattern.preMask,
            displayName: displayName,
            roles: pattern.roles,
            grouping: Glossary.SDModel.SDPatternGrouping(rawValue: pattern.grouping.rawValue) ?? .optional,
            groupLabel: groupLabel,
            defaultProhibitStandalone: pattern.defaultProhibitStandalone,
            defaultIsAppellation: pattern.defaultIsAppellation,
            defaultPreMask: pattern.defaultPreMask
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
