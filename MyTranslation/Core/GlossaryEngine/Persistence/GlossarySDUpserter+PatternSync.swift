import Foundation
import SwiftData

extension Glossary.SDModel.GlossaryUpserter {
    func upsertPatterns(_ items: [JSPattern]) throws {
        var patternMap: [String: Glossary.SDModel.SDPattern] = [:]
        for p in try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>()) { patternMap[p.name] = p }
        var metaMap: [String: Glossary.SDModel.SDPatternMeta] = [:]
        for meta in try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>()) { metaMap[meta.name] = meta }
        for js in items {
            let dst = patternMap[js.name] ?? Glossary.SDModel.SDPattern(name: js.name)
            if let l = js.left {
                dst.leftRole = l.role
                dst.leftTagsAll = l.tagsAll ?? []
                dst.leftTagsAny = l.tagsAny ?? []
                dst.leftIncludeTerms = try fetchTerms(for: l.includeTermKeys)
                dst.leftExcludeTerms = try fetchTerms(for: l.excludeTermKeys)
            } else {
                dst.leftRole = nil
                dst.leftTagsAll = []
                dst.leftTagsAny = []
                dst.leftIncludeTerms = []
                dst.leftExcludeTerms = []
            }
            if let r = js.right {
                dst.rightRole = r.role
                dst.rightTagsAll = r.tagsAll ?? []
                dst.rightTagsAny = r.tagsAny ?? []
                dst.rightIncludeTerms = try fetchTerms(for: r.includeTermKeys)
                dst.rightExcludeTerms = try fetchTerms(for: r.excludeTermKeys)
            } else {
                dst.rightRole = nil
                dst.rightTagsAll = []
                dst.rightTagsAny = []
                dst.rightIncludeTerms = []
                dst.rightExcludeTerms = []
            }
            dst.skipPairsIfSameTerm = js.skipPairsIfSameTerm
            dst.sourceTemplates = js.sourceTemplates
            dst.targetTemplates = js.targetTemplates
            dst.sourceJoiners = js.sourceJoiners.isEmpty ? [""] : js.sourceJoiners
            dst.isAppellation = js.isAppellation
            dst.preMask = js.preMask
            dst.needPairCheck = js.needPairCheck
            if patternMap[js.name] == nil { context.insert(dst); patternMap[js.name] = dst }
            try upsertPatternMeta(js, metaMap: &metaMap)
        }
    }

    private func upsertPatternMeta(_ js: JSPattern, metaMap: inout [String: Glossary.SDModel.SDPatternMeta]) throws {
        let grouping = Glossary.SDModel.SDPatternGrouping(rawValue: js.grouping.rawValue) ?? .optional
        let trimmedDisplay = js.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDisplay.isEmpty ? js.name : trimmedDisplay
        let trimmedLabel = js.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupLabel = trimmedLabel.isEmpty ? Glossary.SDModel.Defaults.groupLabel : trimmedLabel
        if let meta = metaMap[js.name] {
            if merge == .overwrite {
                meta.displayName = displayName
                meta.roles = js.roles
                meta.grouping = grouping
                meta.groupLabel = groupLabel
                meta.defaultProhibitStandalone = js.defaultProhibitStandalone
                meta.defaultIsAppellation = js.defaultIsAppellation
                meta.defaultPreMask = js.defaultPreMask
            } else {
                if meta.displayName == meta.name || meta.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    meta.displayName = displayName
                }
                if meta.roles.isEmpty { meta.roles = js.roles }
                meta.grouping = grouping
                if meta.groupLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meta.groupLabel == Glossary.SDModel.Defaults.groupLabel {
                    meta.groupLabel = groupLabel
                }
            }
        } else {
            let created = Glossary.SDModel.SDPatternMeta(
                name: js.name,
                displayName: displayName,
                roles: js.roles,
                grouping: grouping,
                groupLabel: groupLabel,
                defaultProhibitStandalone: js.defaultProhibitStandalone,
                defaultIsAppellation: js.defaultIsAppellation,
                defaultPreMask: js.defaultPreMask
            )
            context.insert(created)
            metaMap[js.name] = created
        }
    }

    func fetchPatternMetaMap() throws -> [String: Glossary.SDModel.SDPatternMeta] {
        let metaList = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>())
        return Dictionary(uniqueKeysWithValues: metaList.map { ($0.name, $0) })
    }

    func fetchAllKeys<T: PersistentModel>(_ type: T.Type, key: KeyPath<T,String>) throws -> Set<String> {
        let list = try context.fetch(FetchDescriptor<T>())
        return Set(list.map { $0[keyPath: key] })
    }

    func fetchTerms(for keys: [String]?) throws -> [Glossary.SDModel.SDTerm] {
        guard let keys, !keys.isEmpty else { return [] }
        var out: [Glossary.SDModel.SDTerm] = []
        for key in keys {
            let pred = #Predicate<Glossary.SDModel.SDTerm> { $0.key == key }
            var desc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: pred)
            desc.fetchLimit = 1
            if let t = try context.fetch(desc).first { out.append(t) }
        }
        return out
    }

    func key(of c: Glossary.SDModel.SDComponent) -> String {
        let roleKey = normalizedRoleKey(c.role)
        let groupNames = c.groupLinks.map { $0.group.name }
        let groupKey = groupKey(of: groupNames)
        return "\(c.pattern)|\(roleKey)|\(groupKey)"
    }

    func key(of c: JSComponent) -> String {
        let roleKey = normalizedRoleKey(c.role)
        let groupKey = groupKey(of: c.groups)
        return "\(c.pattern)|\(roleKey)|\(groupKey)"
    }
}
