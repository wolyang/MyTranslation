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

    // SwiftData 작업을 처리하는 컨텍스트
    let context: ModelContext
    // 수정 시 기존 용어를 보관해 업서트 여부를 판단
    private let existingTerm: Glossary.SDModel.SDTerm?
    // 패턴 기반 생성 모드일 때 참고할 패턴 데이터
    let pattern: PatternReference?
    // 편집 중인 용어 원본을 UI에서 확인할 때 사용
    var editingTerm: Glossary.SDModel.SDTerm? { existingTerm }

    // 일반/패턴 모드를 구분해 저장 플로우를 분기
    var mode: Mode
    // 일반 모드에서 단일 용어 입력을 위한 초안
    var generalDraft: RoleDraft
    // 패턴 모드에서 역할별 용어 입력을 위한 초안 목록
    var roleDrafts: [RoleDraft]
    // 패턴 모드에서 선택된 그룹 UID
    var selectedGroupID: String?
    // 새로운 그룹 이름 입력값
    var newGroupName: String
    // 패턴 메타에 정의된 그룹 선택지
    var patternGroups: [GroupOption]
    // 용어에 연결할 패턴 컴포넌트 초안 목록
    var componentDrafts: [ComponentDraft]
    // 패턴 선택지 목록(이름, 템플릿, 역할 옵션 포함)
    let patternOptions: [PatternOption]
    // 패턴 ID로 빠르게 옵션을 찾기 위한 맵
    private let patternOptionMap: [String: PatternOption]
    // 삭제 예약된 컴포넌트 ID 집합
    private var removedComponentIDs: Set<PersistentIdentifier> = []
    // 저장 실패 등 오류 메시지 전달용
    var errorMessage: String?
    // 충돌 시 병합 대상으로 보여줄 용어
    var mergeCandidate: Glossary.SDModel.SDTerm?
    // 저장 완료 여부를 UI에 알리기 위한 플래그
    var didSave: Bool = false

    // 패턴 메타에서 제공하는 역할 선택지
    var roleOptions: [String] {
        pattern?.roleOptions ?? []
    }


    // 기존 용어가 있을 때만 컴포넌트 편집 허용 여부
    var canEditComponents: Bool { editingTerm != nil }

    var sortedPatternOptions: [PatternOption] { patternOptions }

    func patternOption(for id: String?) -> PatternOption? {
        guard let id else { return nil }
        return patternOptionMap[id]
    }

    func patternDisplayName(for id: String?) -> String {
        patternOption(for: id)?.displayName ?? "패턴 선택"
    }

    // MARK: - Activator Term Management

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

    func fetchAllTermsForPicker() throws -> [(key: String, target: String)] {
        let descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(
            sortBy: [SortDescriptor(\.target)]
        )
        let terms = try context.fetch(descriptor)
        return terms.map { (key: $0.key, target: $0.target) }
    }

    func termTarget(for key: String) -> String? {
        let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.key == key }
        let descriptor = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: predicate)
        return try? context.fetch(descriptor).first?.target
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

    func addComponentDraft() {
        componentDrafts.append(ComponentDraft(existingID: nil,
                                              patternID: nil,
                                              roleName: "",
                                              selectedGroupUID: nil,
                                              customGroupName: "",
                                              srcTemplateIndex: 0,
                                              tgtTemplateIndex: 0))
    }

    func removeComponentDraft(id: UUID) {
        guard let index = componentDrafts.firstIndex(where: { $0.id == id }) else { return }
        if let existingID = componentDrafts[index].existingID {
            removedComponentIDs.insert(existingID)
        }
        componentDrafts.remove(at: index)
    }

    func didSelectPattern(for draftID: UUID, patternID: String?) {
        guard let index = componentDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        componentDrafts[index].patternID = patternID
        componentDrafts[index].roleName = ""
        componentDrafts[index].selectedGroupUID = nil
        componentDrafts[index].customGroupName = ""
        componentDrafts[index].srcTemplateIndex = 0
        componentDrafts[index].tgtTemplateIndex = 0
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
                var draft = RoleDraft(roleName: role,
                                      sourcesOK: "",
                                      sourcesProhibit: "",
                                      target: "",
                                      variants: "",
                                      tags: "",
                                      prohibitStandaloneDefault: defaults.defaultProhibitStandalone,
                                      isAppellation: defaults.defaultIsAppellation,
                                      preMask: defaults.defaultPreMask,
                                      activatedBy: "")
                draft.applyDefaults(from: defaults)
                return draft
            }
            roleDrafts = rds
            if rds.isEmpty {
                roleDrafts = [RoleDraft(roleName: "기본", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: defaults.defaultProhibitStandalone, isAppellation: defaults.defaultIsAppellation, preMask: defaults.defaultPreMask, activatedBy: "")]
            }
            generalDraft = RoleDraft(roleName: "", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: defaults.defaultProhibitStandalone, isAppellation: defaults.defaultIsAppellation, preMask: defaults.defaultPreMask, activatedBy: "")
            patternGroups = defaults.groups.map { GroupOption(id: $0.uid, name: $0.name) }.sorted { $0.name < $1.name }
            selectedGroupID = nil
            newGroupName = ""
            componentDrafts = []
        } else {
            mode = .general
            generalDraft = RoleDraft(roleName: "", sourcesOK: "", sourcesProhibit: "", target: "", variants: "", tags: "", prohibitStandaloneDefault: true, isAppellation: false, preMask: false, activatedBy: "")
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
        try? applyActivators(draft.activatedByArray, to: term)
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

    private func applyActivators(_ activatorKeys: [String], to term: Glossary.SDModel.SDTerm) throws {
        let trimmed = activatorKeys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // 1) 기존 activators 중 새 목록에 없는 것 제거
        let oldActivators = term.activators
        for activator in oldActivators where !trimmed.contains(activator.key) {
            if let idx = term.activators.firstIndex(where: { $0.key == activator.key }) {
                term.activators.remove(at: idx)
            }
        }

        // 2) 새 목록에 있는 activator 추가
        for activatorKey in trimmed {
            // 이미 관계가 설정되어 있으면 스킵
            if term.activators.contains(where: { $0.key == activatorKey }) {
                continue
            }

            // activator Term 찾기
            let pred = #Predicate<Glossary.SDModel.SDTerm> { $0.key == activatorKey }
            var desc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: pred)
            desc.fetchLimit = 1
            guard let activator = try context.fetch(desc).first else {
                print("[TermEditor][Warning] Activator Term not found: \(activatorKey)")
                continue
            }

            // activators에만 추가 (activates는 inverse에 의해 자동 관리됨)
            term.activators.append(activator)
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
            let roleForTerm: String?
            if let draft = roleDrafts.first(where: { $0.target.trimmingCharacters(in: .whitespacesAndNewlines) == term.target }) {
                let trimmedRole = draft.roleName.trimmingCharacters(in: .whitespaces)
                roleForTerm = trimmedRole.isEmpty ? nil : trimmedRole
            } else {
                roleForTerm = nil
            }
            let component = Glossary.SDModel.SDComponent(pattern: patternModel.name, role: roleForTerm, srcTplIdx: 0, tgtTplIdx: 0, term: term)
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
            guard let existingID = draft.existingID else { return nil }
            return (existingID, draft)
        })
        var componentsToRemove: [Glossary.SDModel.SDComponent] = []
        for component in term.components {
            let compID = component.persistentModelID
            if removedComponentIDs.contains(compID) {
                componentsToRemove.append(component)
                continue
            }
            guard let draft = lookup[compID], let patternID = draft.patternID else { continue }
            component.pattern = patternID
            let trimmedRole = draft.roleName.trimmingCharacters(in: .whitespaces)
            component.role = trimmedRole.isEmpty ? nil : trimmedRole
            if let option = patternOptionMap[patternID] {
                let normalizedSrc = TermEditorViewModel.normalizeTemplateIndex(draft.srcTemplateIndex, templates: option.sourceTemplates)
                let normalizedTgt = TermEditorViewModel.normalizeTemplateIndex(draft.tgtTemplateIndex, templates: option.targetTemplates)
                component.srcTplIdx = normalizedSrc
                component.tgtTplIdx = normalizedTgt
                for link in component.groupLinks {
                    context.delete(link)
                }
                component.groupLinks.removeAll()
                if let name = try resolvedGroupName(from: draft, option: option) {
                    let group = try fetchOrCreateGroup(patternID: patternID, name: name)
                    let bridge = Glossary.SDModel.SDComponentGroup(component: component, group: group)
                    context.insert(bridge)
                    component.groupLinks.append(bridge)
                }
            }
        }
        for component in componentsToRemove {
            for link in component.groupLinks { context.delete(link) }
            term.components.removeAll { $0 === component }
            context.delete(component)
        }
        removedComponentIDs.removeAll()

        for draft in componentDrafts where draft.existingID == nil {
            guard let patternID = draft.patternID,
                  let option = patternOptionMap[patternID] else { continue }
            let role = draft.roleName.trimmingCharacters(in: .whitespaces)
            let roleValue = role.isEmpty ? nil : role
            let srcIdx = TermEditorViewModel.normalizeTemplateIndex(draft.srcTemplateIndex, templates: option.sourceTemplates)
            let tgtIdx = TermEditorViewModel.normalizeTemplateIndex(draft.tgtTemplateIndex, templates: option.targetTemplates)
            let component = Glossary.SDModel.SDComponent(pattern: patternID, role: roleValue, srcTplIdx: srcIdx, tgtTplIdx: tgtIdx, term: term)
            context.insert(component)
            term.components.append(component)
            if let name = try resolvedGroupName(from: draft, option: option) {
                let group = try fetchOrCreateGroup(patternID: patternID, name: name)
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

    private func resolvedGroupName(from draft: ComponentDraft, option: PatternOption) throws -> String? {
        if option.grouping == .none { return nil }
        let trimmedCustom = draft.customGroupName.trimmingCharacters(in: .whitespaces)
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if let selected = draft.selectedGroupUID,
           let found = option.groups.first(where: { $0.id == selected }) {
            return found.name
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

    private static func loadPatternOptions(context: ModelContext) throws -> [PatternOption] {
        let patterns = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>())
        let metas = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>())
        let groups = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>())
        let metaMap = Dictionary(uniqueKeysWithValues: metas.map { ($0.name, $0) })
        let groupsMap = Dictionary(grouping: groups, by: { $0.pattern })
        return patterns.map { pattern in
            let meta = metaMap[pattern.name]
            let displayName = meta?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? pattern.name
            let metaRoles = meta?.roles ?? []
            let roleOptions: [String]
            if !metaRoles.isEmpty {
                roleOptions = metaRoles
            } else {
                roleOptions = pattern.roleListFromSelectors
            }
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
                targetTemplates: pattern.targetTemplates,
                groups: groupOptions
            )
        }.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    private static func normalizeTemplateIndex(_ index: Int, templates: [String]) -> Int {
        guard !templates.isEmpty else { return 0 }
        let clamped = max(0, min(index, templates.count - 1))
        return clamped
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Glossary.SDModel.SDPattern {
    var roleListFromSelectors: [String] {
        [leftRole.nilIfEmpty, rightRole.nilIfEmpty].compactMap { $0 }
    }
}
