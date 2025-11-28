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
        var activatedBy: String  // 조건부 활성화: 이 Term을 활성화하는 Term 키들 (세미콜론 분리)

        mutating func applyDefaults(from pattern: PatternReference) {
            isAppellation = pattern.defaultIsAppellation
            preMask = pattern.defaultPreMask
            prohibitStandaloneDefault = pattern.defaultProhibitStandalone
        }

        var okSources: [String] {
            RoleDraft.splitSources(from: sourcesOK)
        }

        var ngSources: [String] {
            RoleDraft.splitSources(from: sourcesProhibit)
        }

        var variantArray: [String] {
            variants.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var tagArray: [String] {
            tags.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var activatedByArray: [String] {
            activatedBy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        private static func splitSources(from text: String) -> [String] {
            text.split(whereSeparator: { $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    struct GroupOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct ComponentDraft: Identifiable, Hashable {
        let id: UUID = UUID()
        let existingID: PersistentIdentifier?
        var patternID: String?
        var roleName: String
        var selectedGroupUID: String?
        var customGroupName: String
        var srcTemplateIndex: Int
        var tgtTemplateIndex: Int

        var isNew: Bool { existingID == nil }
    }

    struct PatternOption: Identifiable, Hashable {
        let id: String
        let displayName: String
        let grouping: Glossary.SDModel.SDPatternGrouping
        let groupLabel: String
        let roleOptions: [String]
        let sourceTemplates: [String]
        let targetTemplates: [String]
        let groups: [GroupOption]

        var hasRoles: Bool { !roleOptions.isEmpty }
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
            return pattern.roleListFromSelectors
        }
    }

    enum Mode { case general, pattern }

    let context: ModelContext
    let existingTerm: Glossary.SDModel.SDTerm?
    let pattern: PatternReference?
    var editingTerm: Glossary.SDModel.SDTerm? { existingTerm }

    var mode: Mode
    var generalDraft: RoleDraft
    var roleDrafts: [RoleDraft]
    var selectedGroupID: String?
    var newGroupName: String
    var patternGroups: [GroupOption]
    var componentDrafts: [ComponentDraft]
    let patternOptions: [PatternOption]
    let patternOptionMap: [String: PatternOption]
    var removedComponentIDs: Set<PersistentIdentifier> = []
    var errorMessage: String?
    var mergeCandidate: Glossary.SDModel.SDTerm?
    var didSave: Bool = false

    var roleOptions: [String] {
        pattern?.roleOptions ?? []
    }

    var canEditComponents: Bool { editingTerm != nil }
    var sortedPatternOptions: [PatternOption] { patternOptions }

    func patternOption(for id: String?) -> PatternOption? {
        guard let id else { return nil }
        return patternOptionMap[id]
    }

    func patternDisplayName(for id: String?) -> String {
        patternOption(for: id)?.displayName ?? "패턴 선택"
    }

    func availableRoles(for id: String?) -> [String] {
        patternOption(for: id)?.roleOptions ?? []
    }

    func availableGroups(for id: String?) -> [GroupOption] {
        patternOption(for: id)?.groups ?? []
    }

    func grouping(for id: String?) -> Glossary.SDModel.SDPatternGrouping {
        patternOption(for: id)?.grouping ?? .none
    }

    func groupLabel(for id: String?) -> String {
        patternOption(for: id)?.groupLabel ?? "그룹"
    }

    func sourceTemplates(for id: String?) -> [String] {
        patternOption(for: id)?.sourceTemplates ?? []
    }

    func targetTemplates(for id: String?) -> [String] {
        patternOption(for: id)?.targetTemplates ?? []
    }

    func addActivatorTerm(key: String) {
        let current = generalDraft.activatedByArray
        if !current.contains(key) {
            let updated = (current + [key]).joined(separator: ";")
            generalDraft.activatedBy = updated
        }
    }

    func removeActivatorTerm(key: String) {
        let current = generalDraft.activatedByArray
        let filtered = current.filter { $0 != key }
        generalDraft.activatedBy = filtered.joined(separator: ";")
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
        let loadedPatternOptions = try TermEditorViewModel.loadPatternOptions(context: context)
        self.patternOptions = loadedPatternOptions
        let patternOptionMap = Dictionary(uniqueKeysWithValues: loadedPatternOptions.map { ($0.id, $0) })
        self.patternOptionMap = patternOptionMap
        if let term = existingTerm {
            mode = .general
            generalDraft = RoleDraft(
                roleName: "",
                sourcesOK: term.sources.filter { !$0.prohibitStandalone }.map { $0.text }.joined(separator: ";"),
                sourcesProhibit: term.sources.filter { $0.prohibitStandalone }.map { $0.text }.joined(separator: ";"),
                target: term.target,
                variants: term.variants.joined(separator: ";"),
                tags: term.termTagLinks.map { $0.tag.name }.joined(separator: ";"),
                prohibitStandaloneDefault: true,
                isAppellation: term.isAppellation,
                preMask: term.preMask,
                activatedBy: term.activators.map { $0.key }.joined(separator: ";")
            )
            roleDrafts = []
            patternGroups = []
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = term.components.compactMap { comp in
                let patternID = comp.pattern
                let option = patternOptionMap[patternID]
                let existingGroups = comp.groupLinks.map { $0.group }
                let selectedUID: String?
                let customName: String
                if let firstGroup = existingGroups.first,
                   let option,
                   option.groups.contains(where: { $0.id == firstGroup.uid }) {
                    selectedUID = firstGroup.uid
                    customName = ""
                } else {
                    selectedUID = nil
                    customName = existingGroups.first?.name ?? ""
                }
                let sourceTemplates = option?.sourceTemplates ?? []
                let targetTemplates = option?.targetTemplates ?? []
                let srcIdx = TermEditorViewModel.normalizeTemplateIndex(comp.srcTplIdx ?? 0, templates: sourceTemplates)
                let tgtIdx = TermEditorViewModel.normalizeTemplateIndex(comp.tgtTplIdx ?? 0, templates: targetTemplates)
                let role = comp.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return ComponentDraft(
                    existingID: comp.persistentModelID,
                    patternID: patternID,
                    roleName: role,
                    selectedGroupUID: selectedUID,
                    customGroupName: customName,
                    srcTemplateIndex: srcIdx,
                    tgtTemplateIndex: tgtIdx
                )
            }
        } else if let pattern {
            mode = .pattern
            let defaults = pattern
            let rds = defaults.roles.map { role in
                var draft = RoleDraft(
                    roleName: role,
                    sourcesOK: "",
                    sourcesProhibit: "",
                    target: "",
                    variants: "",
                    tags: "",
                    prohibitStandaloneDefault: defaults.defaultProhibitStandalone,
                    isAppellation: defaults.defaultIsAppellation,
                    preMask: defaults.defaultPreMask,
                    activatedBy: ""
                )
                draft.applyDefaults(from: defaults)
                return draft
            }
            roleDrafts = rds
            if rds.isEmpty {
                roleDrafts = [
                    RoleDraft(
                        roleName: "기본",
                        sourcesOK: "",
                        sourcesProhibit: "",
                        target: "",
                        variants: "",
                        tags: "",
                        prohibitStandaloneDefault: defaults.defaultProhibitStandalone,
                        isAppellation: defaults.defaultIsAppellation,
                        preMask: defaults.defaultPreMask,
                        activatedBy: ""
                    )
                ]
            }
            generalDraft = RoleDraft(
                roleName: "",
                sourcesOK: "",
                sourcesProhibit: "",
                target: "",
                variants: "",
                tags: "",
                prohibitStandaloneDefault: defaults.defaultProhibitStandalone,
                isAppellation: defaults.defaultIsAppellation,
                preMask: defaults.defaultPreMask,
                activatedBy: ""
            )
            patternGroups = defaults.groups.map { GroupOption(id: $0.uid, name: $0.name) }.sorted { $0.name < $1.name }
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = []
        } else {
            mode = .general
            generalDraft = RoleDraft(
                roleName: "",
                sourcesOK: "",
                sourcesProhibit: "",
                target: "",
                variants: "",
                tags: "",
                prohibitStandaloneDefault: true,
                isAppellation: false,
                preMask: false,
                activatedBy: ""
            )
            roleDrafts = []
            patternGroups = []
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = []
        }
    }
}
