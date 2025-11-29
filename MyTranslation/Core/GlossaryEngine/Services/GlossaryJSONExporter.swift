import Foundation
import SwiftData

struct GlossaryJSONExporter {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func exportData() throws -> Data {
        let bundle = try exportBundle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    private func exportBundle() throws -> JSBundle {
        let termDesc = FetchDescriptor<Glossary.SDModel.SDTerm>(sortBy: [SortDescriptor(\.key)])
        let patternDesc = FetchDescriptor<Glossary.SDModel.SDPattern>(sortBy: [SortDescriptor(\.name)])
        let metaDesc = FetchDescriptor<Glossary.SDModel.SDPatternMeta>()

        let terms = try context.fetch(termDesc)
        let patterns = try context.fetch(patternDesc)
        let metaMap = Dictionary(uniqueKeysWithValues: try context.fetch(metaDesc).map { ($0.name, $0) })

        let jsTerms = terms.map(makeJSTerm)
        let jsPatterns = patterns.map { makeJSPattern($0, meta: metaMap[$0.name]) }
        return JSBundle(terms: jsTerms, patterns: jsPatterns)
    }

    private func makeJSTerm(_ term: Glossary.SDModel.SDTerm) -> JSTerm {
        let sources = term.sources
            .sorted { $0.text < $1.text }
            .map { JSSource(source: $0.text, prohibitStandalone: $0.prohibitStandalone) }

        let components = term.components
            .sorted { lhs, rhs in
                if lhs.pattern != rhs.pattern { return lhs.pattern < rhs.pattern }
                return (lhs.role ?? "").localizedCaseInsensitiveCompare(rhs.role ?? "") == .orderedAscending
            }
            .map { comp -> JSComponent in
                let groupNames = comp.groupLinks.map { $0.group.name }.sorted()
                return JSComponent(
                    pattern: comp.pattern,
                    role: sanitized(comp.role),
                    groups: groupNames.isEmpty ? nil : groupNames,
                    srcTplIdx: comp.srcTplIdx,
                    tgtTplIdx: comp.tgtTplIdx
                )
            }

        let tags = sortedUnique(term.termTagLinks.map { $0.tag.name })
        let activators = sortedUnique(term.activators.map { $0.key })

        return JSTerm(
            key: term.key,
            sources: sources,
            target: term.target,
            variants: orderedUnique(term.variants),
            tags: tags,
            components: components,
            isAppellation: term.isAppellation,
            preMask: term.preMask,
            activatedByKeys: activators.isEmpty ? [] : activators
        )
    }

    private func makeJSPattern(_ pattern: Glossary.SDModel.SDPattern, meta: Glossary.SDModel.SDPatternMeta?) -> JSPattern {
        let leftSelector = selector(
            role: pattern.leftRole,
            tagsAll: pattern.leftTagsAll,
            tagsAny: pattern.leftTagsAny,
            include: pattern.leftIncludeTerms,
            exclude: pattern.leftExcludeTerms
        )
        let rightSelector = selector(
            role: pattern.rightRole,
            tagsAll: pattern.rightTagsAll,
            tagsAny: pattern.rightTagsAny,
            include: pattern.rightIncludeTerms,
            exclude: pattern.rightExcludeTerms
        )

        return JSPattern(
            name: pattern.name,
            left: leftSelector,
            right: rightSelector,
            skipPairsIfSameTerm: pattern.skipPairsIfSameTerm,
            sourceJoiners: pattern.sourceJoiners,
            sourceTemplates: pattern.sourceTemplates,
            targetTemplates: pattern.targetTemplates,
            isAppellation: pattern.isAppellation,
            preMask: pattern.preMask,
            displayName: meta?.displayName ?? pattern.name,
            roles: meta?.roles ?? [],
            grouping: mapGrouping(meta?.grouping),
            groupLabel: meta?.groupLabel ?? "그룹",
            defaultProhibitStandalone: meta?.defaultProhibitStandalone ?? false,
            defaultIsAppellation: meta?.defaultIsAppellation ?? false,
            defaultPreMask: meta?.defaultPreMask ?? false,
            needPairCheck: pattern.needPairCheck
        )
    }

    private func selector(
        role: String?,
        tagsAll: [String],
        tagsAny: [String],
        include: [Glossary.SDModel.SDTerm],
        exclude: [Glossary.SDModel.SDTerm]
    ) -> JSTermSelector? {
        let normalizedRole = sanitized(role)
        let tagsAll = sortedUnique(tagsAll)
        let tagsAny = sortedUnique(tagsAny)
        let includeKeys = sortedUnique(include.map { $0.key })
        let excludeKeys = sortedUnique(exclude.map { $0.key })

        if normalizedRole == nil,
           tagsAll.isEmpty,
           tagsAny.isEmpty,
           includeKeys.isEmpty,
           excludeKeys.isEmpty {
            return nil
        }

        return JSTermSelector(
            role: normalizedRole,
            tagsAll: tagsAll.isEmpty ? nil : tagsAll,
            tagsAny: tagsAny.isEmpty ? nil : tagsAny,
            includeTermKeys: includeKeys.isEmpty ? nil : includeKeys,
            excludeTermKeys: excludeKeys.isEmpty ? nil : excludeKeys
        )
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var set: Set<String> = []
        var result: [String] = []
        for value in values {
            if set.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private func sanitized(_ role: String?) -> String? {
        guard let trimmed = role?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func mapGrouping(_ grouping: Glossary.SDModel.SDPatternGrouping?) -> JSGrouping {
        JSGrouping(rawValue: grouping?.rawValue ?? JSGrouping.optional.rawValue) ?? .optional
    }
}
