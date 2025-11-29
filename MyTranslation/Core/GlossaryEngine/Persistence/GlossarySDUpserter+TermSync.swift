import Foundation
import SwiftData

extension Glossary.SDModel.GlossaryUpserter {
    func upsertTerms(_ items: [JSTerm]) throws {
        var map: [String: Glossary.SDModel.SDTerm] = [:]
        for t in try context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>()) { map[t.key] = t }

        // Phase 1: 모든 Term을 생성/업데이트하고, activatedBy 정보 수집
        var activationMap: [String: [String]] = [:]  // termKey → activatorKeys
        for src in items {
            let trimmedActivators = normalizedActivatorKeys(src.activatedByKeys, termKey: src.key)

            let dst: Glossary.SDModel.SDTerm
            if let existing = map[src.key] {
                try update(term: existing, with: src)
                dst = existing
            } else {
                let created = Glossary.SDModel.SDTerm(key: src.key, target: src.target)
                try update(term: created, with: src)
                context.insert(created)
                map[src.key] = created
                dst = created
            }
            try Glossary.SDModel.SourceIndexMaintainer.rebuild(for: dst, in: context)

            if merge == .overwrite {
                activationMap[src.key] = trimmedActivators
            } else if !trimmedActivators.isEmpty {
                activationMap[src.key] = trimmedActivators
            }
        }

        try setupActivatorRelationships(activationMap: activationMap, termMap: map)
    }

    private func update(term dst: Glossary.SDModel.SDTerm, with src: JSTerm) throws {
        if merge == .overwrite {
            dst.target = src.target
            dst.isAppellation = src.isAppellation
            dst.preMask = src.preMask
            dst.variants = orderedUnique(src.variants)
            dst.deactivatedIn = src.deactivatedIn
        } else {  // .merge
            // Single-value fields: overwrite
            dst.target = src.target
            dst.isAppellation = src.isAppellation
            dst.preMask = src.preMask
            // Array fields: union
            dst.variants = mergeSet(dst.variants, src.variants)
            dst.deactivatedIn = mergeSet(dst.deactivatedIn, src.deactivatedIn)
        }

        upsertSources(term: dst, with: src)
        try upsertComponents(term: dst, with: src)
        try ensureTags(dst, names: src.tags, removingMissing: merge == .overwrite)
    }

    private func setupActivatorRelationships(activationMap: [String: [String]], termMap: [String: Glossary.SDModel.SDTerm]) throws {
        for (termKey, activatorKeys) in activationMap {
            guard let term = termMap[termKey] else { continue }

            if merge == .overwrite {
                // Clear existing activators before adding new ones
                let oldActivators = term.activators
                for oldActivator in oldActivators {
                    if let idx = term.activators.firstIndex(where: { $0.key == oldActivator.key }) {
                        term.activators.remove(at: idx)
                    }
                }
            }
            // For .merge mode: keep existing activators, add new ones (union behavior)

            for activatorKey in activatorKeys {
                // Skip if activator already exists (for both modes)
                if term.activators.contains(where: { $0.key == activatorKey }) {
                    continue
                }

                let activator: Glossary.SDModel.SDTerm?
                if let found = termMap[activatorKey] {
                    activator = found
                } else {
                    let pred = #Predicate<Glossary.SDModel.SDTerm> { $0.key == activatorKey }
                    var desc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: pred)
                    desc.fetchLimit = 1
                    activator = try context.fetch(desc).first
                }

                guard let activator else {
                    print("[Import][Warning] Activator Term not found: \(activatorKey) for term: \(termKey)")
                    continue
                }

                term.activators.append(activator)
            }
        }
    }

    private func upsertSources(term dst: Glossary.SDModel.SDTerm, with src: JSTerm) {
        var existingByText: [String: Glossary.SDModel.SDSource] = [:]
        for s in dst.sources { existingByText[s.text] = s }
        var seen: Set<String> = []
        for js in src.sources {
            seen.insert(js.source)
            if let s = existingByText[js.source] {
                // Always update prohibitStandalone (it's a single-value field)
                s.prohibitStandalone = js.prohibitStandalone
            } else {
                let s = Glossary.SDModel.SDSource(text: js.source, prohibitStandalone: js.prohibitStandalone, term: dst)
                context.insert(s)
                dst.sources.append(s)
            }
        }
        // Only delete unmatched sources in overwrite mode
        if merge == .overwrite {
            for (text, source) in existingByText where !seen.contains(text) {
                if let idx = dst.sources.firstIndex(where: { $0 === source }) {
                    dst.sources.remove(at: idx)
                }
                context.delete(source)
            }
        }
    }

    private func upsertComponents(term dst: Glossary.SDModel.SDTerm, with src: JSTerm) throws {
        if merge == .overwrite {
            // Overwrite mode: match by composite key (pattern + role + groups)
            var existingCompKeys: [String: Glossary.SDModel.SDComponent] = [:]
            var seen: Set<String> = []
            for c in dst.components { existingCompKeys[key(of: c)] = c }
            for jc in src.components {
                let compKey = key(of: jc)
                seen.insert(compKey)
                let comp: Glossary.SDModel.SDComponent
                if let c = existingCompKeys[compKey] {
                    comp = c
                } else {
                    comp = Glossary.SDModel.SDComponent(pattern: jc.pattern, role: jc.role, term: dst)
                    context.insert(comp)
                    dst.components.append(comp)
                }
                if let groups = jc.groups {
                    try ensureGroups(groups, for: comp, pattern: jc.pattern)
                }
            }
            // Delete unmatched components
            for (key, old) in existingCompKeys where !seen.contains(key) {
                if let idx = dst.components.firstIndex(where: { $0 === old }) {
                    dst.components.remove(at: idx)
                }
                context.delete(old)
            }
        } else {  // .merge
            // Merge mode: match by pattern name only
            var existingByPattern: [String: Glossary.SDModel.SDComponent] = [:]
            for c in dst.components { existingByPattern[c.pattern] = c }

            for jc in src.components {
                if let existing = existingByPattern[jc.pattern] {
                    // Pattern exists: update role/indices, merge groups
                    existing.role = jc.role

                    // Merge groups (union)
                    let existingGroups = existing.groupLinks.map { $0.group.name }
                    let newGroups = jc.groups ?? []
                    let mergedGroups = mergeSet(existingGroups, newGroups)
                    try ensureGroups(mergedGroups, for: existing, pattern: jc.pattern)
                } else {
                    // Pattern doesn't exist: add new component
                    let comp = Glossary.SDModel.SDComponent(pattern: jc.pattern, role: jc.role, term: dst)
                    context.insert(comp)
                    dst.components.append(comp)
                    if let groups = jc.groups {
                        try ensureGroups(groups, for: comp, pattern: jc.pattern)
                    }
                }
            }
            // Keep all existing components (don't delete unmatched)
        }
    }

    private func ensureGroups(_ names: [String], for comp: Glossary.SDModel.SDComponent, pattern: String) throws {
        let cur = Set(comp.groupLinks.map({ $0.group.uid }))
        let new = Set(names.map({ "\(pattern)#\($0)" }))
        let removes = cur.subtracting(new)
        if !removes.isEmpty {
            for remove in removes {
                if let removeLink = comp.groupLinks.first(where: { $0.group.uid == remove }) {
                    context.delete(removeLink)
                }
                let pred = #Predicate<Glossary.SDModel.SDGroup> { $0.uid == remove }
                var desc = FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: pred)
                desc.fetchLimit = 1
                if let g = try context.fetch(desc).first {
                    g.componentLinks.removeAll(where: { $0.component.term == comp.term })
                }
                comp.groupLinks.removeAll(where: { $0.group.uid == remove })
            }
        }

        var linked: [String: Glossary.SDModel.SDGroup] = [:]
        for link in comp.groupLinks { linked[link.group.uid] = link.group }
        for name in names {
            let uid = "\(pattern)#\(name)"
            let group = try findOrCreateGroup(uid: uid, pattern: pattern, name: name)
            if linked[uid] == nil {
                let link = Glossary.SDModel.SDComponentGroup(component: comp, group: group)
                context.insert(link)
                comp.groupLinks.append(link)
                group.componentLinks.append(link)
            }
        }
    }

    private func findOrCreateGroup(uid: String, pattern: String, name: String) throws -> Glossary.SDModel.SDGroup {
        let pred = #Predicate<Glossary.SDModel.SDGroup> { $0.uid == uid }
        var desc = FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: pred)
        desc.fetchLimit = 1
        if let g = try context.fetch(desc).first { return g }
        let g = Glossary.SDModel.SDGroup(uid: uid, pattern: pattern, name: name)
        context.insert(g)
        return g
    }

    private func ensureTags(_ term: Glossary.SDModel.SDTerm, names: [String], removingMissing: Bool) throws {
        var existing: [String: Glossary.SDModel.SDTag] = [:]
        for link in term.termTagLinks { existing[link.tag.name] = link.tag }
        for name in names {
            let tag = try findOrCreateTag(name)
            if existing[name] == nil {
                let link = Glossary.SDModel.SDTermTagLink(term: term, tag: tag)
                context.insert(link)
                term.termTagLinks.append(link)
                tag.termLinks.append(link)
            }
        }
        if removingMissing {
            let incoming = Set(names)
            for (name, tag) in existing where !incoming.contains(name) {
                if let linkIdx = term.termTagLinks.firstIndex(where: { $0.tag.name == name }) {
                    let link = term.termTagLinks.remove(at: linkIdx)
                    context.delete(link)
                }
                tag.termLinks.removeAll(where: { $0.term.key == term.key })
            }
        }
    }

    private func findOrCreateTag(_ name: String) throws -> Glossary.SDModel.SDTag {
        let pred = #Predicate<Glossary.SDModel.SDTag> { $0.name == name }
        var desc = FetchDescriptor<Glossary.SDModel.SDTag>(predicate: pred)
        desc.fetchLimit = 1
        if let t = try context.fetch(desc).first { return t }
        let t = Glossary.SDModel.SDTag(name: name)
        context.insert(t)
        return t
    }
}
