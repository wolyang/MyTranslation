import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TermEditorViewModel {
    struct RoleDraft: Identifiable, Hashable {
        let id: UUID = UUID()
        var roleName: String
        var sourcesOK: String
        var sourcesProhibit: String
        var target: String
        var variants: String
        var tags: String
        var prohibitStandaloneDefault: Bool
        var isAppellation: Bool
        var preMask: Bool

        mutating func applyDefaults(from pattern: PatternReference) {
            isAppellation = pattern.defaultIsAppellation
            preMask = pattern.defaultPreMask
            prohibitStandaloneDefault = pattern.defaultProhibitStandalone
        }

        var okSources: [String] {
            sourcesOK.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var ngSources: [String] {
            sourcesProhibit.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var variantArray: [String] {
            variants.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var tagArray: [String] {
            tags.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    struct GroupOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct ComponentDraft: Identifiable, Hashable {
        let id: PersistentIdentifier?
        let patternID: String
        let patternDisplayName: String
        let grouping: Glossary.SDModel.SDPatternGrouping
        let groupLabel: String
        let availableGroups: [GroupOption]
        let availableRoles: [String]
        var roleName: String
        var selectedGroupUID: String?
        var customGroupName: String

        var displayRoleOptions: [String] { availableRoles }
    }

    struct PatternReference {
        let pattern: Glossary.SDModel.SDPattern
        let meta: Glossary.SDModel.SDPatternMeta?
        let groups: [Glossary.SDModel.SDGroup]
        var roles: [String] { meta?.roles ?? [] }
        var defaultProhibitStandalone: Bool { meta?.defaultProhibitStandalone ?? true }
        var defaultIsAppellation: Bool { meta?.defaultIsAppellation ?? false }
        var defaultPreMask: Bool { meta?.defaultPreMask ?? false }
        var grouping: Glossary.SDModel.SDPatternGrouping { meta?.grouping ?? .none }
        var groupLabel: String { meta?.groupLabel ?? "그룹" }
        var roleOptions: [String] {
            let metaRoles = roles
            if !metaRoles.isEmpty { return metaRoles }
            let combined = pattern.leftRoles + pattern.rightRoles
            return combined
        }
    }

    enum Mode { case general, pattern }

    let context: ModelContext
    private let existingTerm: Glossary.SDModel.SDTerm?
    let pattern: PatternReference?
    var editingTerm: Glossary.SDModel.SDTerm? { existingTerm }

    var mode: Mode
    var generalDraft: RoleDraft
    var roleDrafts: [RoleDraft]
    var selectedGroupID: String?
    var newGroupName: String
    var patternGroups: [GroupOption]
    var componentDrafts: [ComponentDraft]
    var errorMessage: String?
    var mergeCandidate: Glossary.SDModel.SDTerm?
    var didSave: Bool = false

    var roleOptions: [String] {
        pattern?.roleOptions ?? []
    }

    init(context: ModelContext, termID: PersistentIdentifier?, patternID: String?) throws {
        self.context = context
        if let termID, let term = context.model(for: termID) as? Glossary.SDModel.SDTerm {
            self.existingTerm = term
        } else {
            self.existingTerm = nil
        }
        if let patternID {
            self.pattern = try TermEditorViewModel.fetchPattern(id: patternID, context: context)
        } else {
            self.pattern = nil
        }

        if let term = existingTerm {
            mode = .general
            generalDraft = RoleDraft(
                roleName: "",
                sourcesOK: term.sources.filter { !$0.prohibitStandalone }.map { $0.text }.joined(separator: "\n"),
                sourcesProhibit: term.sources.filter { $0.prohibitStandalone }.map { $0.text }.joined(separator: "\n"),
                target: term.target,
                variants: term.variants.joined(separator: ";"),
                tags: term.termTagLinks.map { $0.tag.name }.joined(separator: ";"),
                prohibitStandaloneDefault: true,
                isAppellation: term.isAppellation,
                preMask: term.preMask
            )
            roleDrafts = []
            patternGroups = []
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = term.components.compactMap { comp in
                guard let ref = try? TermEditorViewModel.fetchPattern(id: comp.pattern, context: context) else { return nil }
                let options = ref.groups.map { GroupOption(id: $0.uid, name: $0.name) }.sorted { $0.name < $1.name }
                let existingGroups = comp.groupLinks.map { $0.group }
                let selectedUID = existingGroups.first?.uid
                let customName = selectedUID == nil ? (existingGroups.first?.name ?? "") : ""
                return ComponentDraft(
                    id: comp.persistentModelID,
                    patternID: comp.pattern,
                    patternDisplayName: ref.meta?.displayName ?? comp.pattern,
                    grouping: ref.grouping,
                    groupLabel: ref.groupLabel,
                    availableGroups: options,
                    availableRoles: ref.roleOptions,
                    roleName: comp.roles?.first ?? "",
                    selectedGroupUID: selectedUID,
                    customGroupName: customName
                )
            }
        } else if let pattern {
            mode = .pattern
            let defaults = PatternReference(pattern: pattern.pattern, meta: pattern.meta)
            let rds = defaults.roles.map { role in
                var draft = RoleDraft(roleName: role,
                                      sourcesOK: "",
                                      sourcesProhibit: "",
                                      target: "",
                                      variants: "",
                                      tags: "",
                                      prohibitStandaloneDefault: defaults.defaultProhibitStandalone,
                                      isAppellation: defaults.defaultIsAppellation,
                                      preMask: defaults.defaultPreMask)
                draft.applyDefaults(from: defaults)
                return draft
            }
            roleDrafts = rds
            if rds.isEmpty {
                roleDrafts = [RoleDraft(roleName: "기본", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: defaults.defaultProhibitStandalone, isAppellation: defaults.defaultIsAppellation, preMask: defaults.defaultPreMask)]
            }
            generalDraft = RoleDraft(roleName: "", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: defaults.defaultProhibitStandalone, isAppellation: defaults.defaultIsAppellation, preMask: defaults.defaultPreMask)
            patternGroups = defaults.groups.map { GroupOption(id: $0.uid, name: $0.name) }.sorted { $0.name < $1.name }
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = []
        } else {
            mode = .general
            generalDraft = RoleDraft(roleName: "", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: true, isAppellation: false, preMask: false)
            roleDrafts = []
            patternGroups = []
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = []
        }
    }

    func save() throws {
        switch mode {
        case .general:
            try saveGeneral()
        case .pattern:
            try savePattern()
        }
        try context.save()
        didSave = true
    }

    private func saveGeneral() throws {
        let draft = generalDraft
        guard !draft.okSources.isEmpty || !draft.ngSources.isEmpty || !draft.target.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "입력된 내용이 없습니다."
            return
        }
        let target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            errorMessage = "번역값을 입력하세요."
            return
        }
        var term: Glossary.SDModel.SDTerm
        if let existingTerm {
            term = existingTerm
        } else if let conflict = try findTerm(target: target, sources: draft.okSources + draft.ngSources, excluding: nil) {
            mergeCandidate = conflict
            try merge(term: conflict, with: draft)
            return
        } else {
            term = Glossary.SDModel.SDTerm(key: makeKey(for: target), target: target)
            context.insert(term)
        }
        apply(draft: draft, to: term)
        if let existingTerm { try updateComponents(for: existingTerm) }
    }

    private func savePattern() throws {
        guard let pattern else {
            errorMessage = "패턴 정보가 없습니다."
            return
        }
        var createdTerms: [Glossary.SDModel.SDTerm] = []
        for draft in roleDrafts {
            let trimmedTarget = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTarget.isEmpty else { continue }
            let allSources = draft.okSources + draft.ngSources
            if let conflict = try findTerm(target: trimmedTarget, sources: allSources, excluding: nil) {
                mergeCandidate = conflict
                try merge(term: conflict, with: draft)
                createdTerms.append(conflict)
                continue
            }
            let term = Glossary.SDModel.SDTerm(key: makeKey(for: trimmedTarget), target: trimmedTarget, variants: draft.variantArray, isAppellation: draft.isAppellation, preMask: draft.preMask)
            context.insert(term)
            applySources(draft: draft, to: term)
            try applyTags(draft.tagArray, to: term)
            createdTerms.append(term)
        }
        guard !createdTerms.isEmpty else {
            errorMessage = "생성할 용어가 없습니다."
            return
        }
        try attachComponents(terms: createdTerms, pattern: pattern)
    }

    private func saveOrUpdateSources(for term: Glossary.SDModel.SDTerm, draft: RoleDraft) {
        let okSet = Set(draft.okSources)
        let ngSet = Set(draft.ngSources)
        // 삭제
        for source in term.sources where !(okSet.contains(source.text) || ngSet.contains(source.text)) {
            context.delete(source)
        }
        term.sources.removeAll { src in !(okSet.contains(src.text) || ngSet.contains(src.text)) }
        func ensure(_ text: String, prohibit: Bool) {
            if let existing = term.sources.first(where: { $0.text == text }) {
                existing.prohibitStandalone = prohibit
            } else {
                let src = Glossary.SDModel.SDSource(text: text, prohibitStandalone: prohibit, term: term)
                context.insert(src)
                term.sources.append(src)
            }
        }
        for text in draft.okSources { ensure(text, prohibit: false) }
        for text in draft.ngSources { ensure(text, prohibit: true) }
    }

    private func apply(draft: RoleDraft, to term: Glossary.SDModel.SDTerm) {
        term.target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        term.variants = draft.variantArray
        term.isAppellation = draft.isAppellation
        term.preMask = draft.preMask
        saveOrUpdateSources(for: term, draft: draft)
        try? applyTags(draft.tagArray, to: term)
    }

    private func applySources(draft: RoleDraft, to term: Glossary.SDModel.SDTerm) {
        for text in draft.okSources {
            let src = Glossary.SDModel.SDSource(text: text, prohibitStandalone: false, term: term)
            context.insert(src)
            term.sources.append(src)
        }
        for text in draft.ngSources {
            let src = Glossary.SDModel.SDSource(text: text, prohibitStandalone: true, term: term)
            context.insert(src)
            term.sources.append(src)
        }
    }

    private func applyTags(_ tags: [String], to term: Glossary.SDModel.SDTerm) throws {
        let trimmed = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var existingLinks: [Glossary.SDModel.SDTermTagLink] = term.termTagLinks
        for link in existingLinks where !trimmed.contains(link.tag.name) {
            context.delete(link)
        }
        term.termTagLinks.removeAll { link in !trimmed.contains(link.tag.name) }
        for name in trimmed {
            let tag = try fetchOrCreateTag(name: name)
            if term.termTagLinks.contains(where: { $0.tag.name == name }) { continue }
            let link = Glossary.SDModel.SDTermTagLink(term: term, tag: tag)
            context.insert(link)
            term.termTagLinks.append(link)
        }
    }

    private func fetchOrCreateTag(name: String) throws -> Glossary.SDModel.SDTag {
        if let tag = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTag>(predicate: #Predicate { $0.name == name })).first {
            return tag
        }
        let tag = Glossary.SDModel.SDTag(name: name)
        context.insert(tag)
        return tag
    }

    private func attachComponents(terms: [Glossary.SDModel.SDTerm], pattern: PatternReference) throws {
        let patternModel = pattern.pattern
        for term in terms {
            if term.components.contains(where: { $0.pattern == patternModel.name }) { continue }
            let rolesForTerm: [String]
            if let draft = roleDrafts.first(where: { $0.target.trimmingCharacters(in: .whitespacesAndNewlines) == term.target }) {
                rolesForTerm = [draft.roleName].filter { !$0.isEmpty }
            } else {
                rolesForTerm = []
            }
            let component = Glossary.SDModel.SDComponent(pattern: patternModel.name, roles: rolesForTerm.isEmpty ? nil : rolesForTerm, srcTplIdx: 0, tgtTplIdx: 0, term: term)
            context.insert(component)
            term.components.append(component)
            if pattern.grouping != .none {
                let fallback = terms.map { $0.target }.joined(separator: " ")
                if let groupName = try resolvedGroupName(forPattern: pattern, fallback: fallback) {
                    let group = try fetchOrCreateGroup(patternID: patternModel.name, name: groupName)
                    let bridge = Glossary.SDModel.SDComponentGroup(component: component, group: group)
                    context.insert(bridge)
                    component.groupLinks.append(bridge)
                }
            }
        }
    }

    private func updateComponents(for term: Glossary.SDModel.SDTerm) throws {
        let lookup: [PersistentIdentifier: ComponentDraft] = Dictionary(uniqueKeysWithValues: componentDrafts.compactMap { draft in
            guard let id = draft.id else { return nil }
            return (id, draft)
        })
        for component in term.components {
            guard let compID = component.persistentModelID, let draft = lookup[compID] else { continue }
            let trimmedRole = draft.roleName.trimmingCharacters(in: .whitespaces)
            component.roles = trimmedRole.isEmpty ? nil : [trimmedRole]
            for link in component.groupLinks {
                context.delete(link)
            }
            component.groupLinks.removeAll()
            guard draft.grouping != .none else { continue }
            if let name = try resolvedGroupName(from: draft) {
                let group = try fetchOrCreateGroup(patternID: draft.patternID, name: name)
                let bridge = Glossary.SDModel.SDComponentGroup(component: component, group: group)
                context.insert(bridge)
                component.groupLinks.append(bridge)
            }
        }
    }

    private func resolvedGroupName(forPattern pattern: PatternReference, fallback: String) throws -> String? {
        let trimmedCustom = newGroupName.trimmingCharacters(in: .whitespaces)
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if let selectedGroupID,
           let group = patternGroups.first(where: { $0.id == selectedGroupID }) {
            return group.name
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespaces)
        return trimmedFallback.isEmpty ? nil : trimmedFallback
    }

    private func resolvedGroupName(from draft: ComponentDraft) throws -> String? {
        let trimmedCustom = draft.customGroupName.trimmingCharacters(in: .whitespaces)
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if let selected = draft.selectedGroupUID,
           let option = draft.availableGroups.first(where: { $0.id == selected }) {
            return option.name
        }
        return nil
    }

    private func fetchOrCreateGroup(patternID: String, name: String) throws -> Glossary.SDModel.SDGroup {
        let uid = "\(patternID)#\(name)"
        if let group = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: #Predicate { $0.uid == uid })).first {
            return group
        }
        let group = Glossary.SDModel.SDGroup(uid: uid, pattern: patternID, name: name)
        context.insert(group)
        return group
    }

    private func makeKey(for target: String) -> String {
        var used: Set<String> = []
        let existing = (try? context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>())) ?? []
        used.formUnion(existing.map { $0.key })
        var key = "manual:\(latinSlug(target).lowercased())"
        if key.isEmpty { key = "manual:term" }
        var idx = 2
        while used.contains(key) {
            key = "manual:term-\(idx)"
            idx += 1
        }
        return key
    }

    private func findTerm(target: String, sources: [String], excluding: Glossary.SDModel.SDTerm?) throws -> Glossary.SDModel.SDTerm? {
        let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.target == target }
        let matches = try context.fetch(FetchDescriptor(predicate: predicate))
        let srcSet = Set(sources)
        for term in matches where term !== excluding {
            let existingSources = Set(term.sources.map { $0.text })
            if !existingSources.isDisjoint(with: srcSet) { return term }
        }
        return nil
    }

    private func merge(term: Glossary.SDModel.SDTerm, with draft: RoleDraft) throws {
        let mergedSources = Set(term.sources.map { $0.text }).union(draft.okSources + draft.ngSources)
        for text in mergedSources {
            if let existing = term.sources.first(where: { $0.text == text }) {
                if draft.ngSources.contains(text) { existing.prohibitStandalone = true }
            } else {
                let prohibit = draft.ngSources.contains(text)
                let src = Glossary.SDModel.SDSource(text: text, prohibitStandalone: prohibit, term: term)
                context.insert(src)
                term.sources.append(src)
            }
        }
        var variants = Set(term.variants)
        variants.formUnion(draft.variantArray)
        term.variants = Array(variants)
        term.isAppellation = draft.isAppellation || term.isAppellation
        term.preMask = draft.preMask || term.preMask
        try applyTags(draft.tagArray, to: term)
    }

    private static func fetchPattern(id: String, context: ModelContext) throws -> PatternReference {
        guard let pattern = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == id })).first else {
            throw NSError(domain: "TermEditor", code: 0, userInfo: [NSLocalizedDescriptionKey: "패턴을 찾을 수 없습니다."])
        }
        let meta = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>(predicate: #Predicate { $0.name == id })).first
        let groups = try fetchGroups(patternID: id, context: context)
        return PatternReference(pattern: pattern, meta: meta, groups: groups)
    }

    private static func fetchGroups(patternID: String, context: ModelContext) throws -> [Glossary.SDModel.SDGroup] {
        let desc = FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: #Predicate { $0.pattern == patternID })
        return try context.fetch(desc)
    }
}
