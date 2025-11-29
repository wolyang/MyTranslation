import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PatternEditorViewModel {
    struct GroupItem: Identifiable, Hashable {
        let id: String
        var name: String
        var termCount: Int
    }

    let context: ModelContext
    private let originalID: String?
    var existingPatternID: String? { originalID }

    var patternID: String
    var displayName: String
    var leftRole: String
    var rightRole: String
    var grouping: Glossary.SDModel.SDPatternGrouping
    var groupLabel: String
    var sourceJoiners: String
    var sourceTemplates: String
    var targetTemplates: String
    var skipPairsIfSameTerm: Bool
    var isAppellation: Bool
    var preMask: Bool
    var defaultProhibit: Bool
    var defaultIsAppellation: Bool
    var defaultPreMask: Bool

    private(set) var groups: [GroupItem] = []
    var errorMessage: String?
    var didSave: Bool = false

    init(context: ModelContext, patternID: String?) throws {
        self.context = context
        if let patternID,
           let pattern = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == patternID })).first {
            let meta = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>(predicate: #Predicate { $0.name == patternID })).first
            originalID = pattern.name
            self.patternID = pattern.name
            displayName = meta?.displayName ?? pattern.name
            // FIXME: Pattern 리팩토링 임시 처리
            let metaRoles = pattern.roles
            if metaRoles.count >= 2 {
                leftRole = metaRoles[0]
                rightRole = metaRoles[1]
            } else {
                // FIXME: Pattern 리팩토링 임시 처리
                leftRole = /*pattern.leftRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? metaRoles.first ?? */""
                rightRole = ""//pattern.rightRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? (metaRoles.dropFirst().first ?? "")
            }
            grouping = meta?.grouping ?? .none
            groupLabel = meta?.groupLabel ?? "그룹"
            // FIXME: Pattern 리팩토링 임시 처리
            sourceJoiners = ""//pattern.sourceJoiners.joined(separator: ";")
            sourceTemplates = pattern.sourceTemplates.joined(separator: ";")
            targetTemplates = pattern.targetTemplate//s.joined(separator: ";")
            skipPairsIfSameTerm = pattern.skipPairsIfSameTerm
            isAppellation = pattern.isAppellation
            preMask = pattern.preMask
            defaultProhibit = meta?.defaultProhibitStandalone ?? true
            defaultIsAppellation = meta?.defaultIsAppellation ?? false
            defaultPreMask = meta?.defaultPreMask ?? false
        } else {
            originalID = nil
            self.patternID = ""
            displayName = ""
            leftRole = ""
            rightRole = ""
            grouping = .none
            groupLabel = "그룹"
            sourceJoiners = ""
            sourceTemplates = ""
            targetTemplates = ""
            skipPairsIfSameTerm = true
            isAppellation = false
            preMask = false
            defaultProhibit = true
            defaultIsAppellation = false
            defaultPreMask = false
        }
        try reloadGroups()
    }

    func reloadGroups() throws {
        guard !patternID.isEmpty else {
            groups = []
            return
        }
        let desc = FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: #Predicate { $0.pattern == patternID })
        let fetched = try context.fetch(desc)
        groups = fetched.map { group in
            GroupItem(id: group.uid, name: group.name, termCount: group.componentLinks.count)
        }.sorted { $0.name < $1.name }
    }

    func save() throws {
        let trimmedID = patternID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            errorMessage = "ID를 입력하세요."
            return
        }
        let trimmedTargetTemplates = targetTemplates.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmedTargetTemplates.isEmpty else {
            errorMessage = "타깃 템플릿을 입력하세요."
            return
        }
        let sourceJoinerArray = sourceJoiners.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let sourceTemplateArray = sourceTemplates.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trimmedLeftRole = leftRole.trimmingCharacters(in: .whitespaces)
        let trimmedRightRole = rightRole.trimmingCharacters(in: .whitespaces)
        if trimmedLeftRole.isEmpty != trimmedRightRole.isEmpty {
            errorMessage = "좌우 역할은 모두 입력하거나 모두 비워야 합니다."
            return
        }
        let roleList: [String] = trimmedLeftRole.isEmpty ? [] : [trimmedLeftRole, trimmedRightRole]
        let pattern: Glossary.SDModel.SDPattern
        if let originalID,
           let existing = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == originalID })).first {
            pattern = existing
        } else {
            if try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == trimmedID })).first != nil {
                errorMessage = "이미 존재하는 ID입니다."
                return
            }
            pattern = Glossary.SDModel.SDPattern(name: trimmedID)
            context.insert(pattern)
        }
        pattern.name = trimmedID
        pattern.skipPairsIfSameTerm = skipPairsIfSameTerm
        pattern.isAppellation = isAppellation
        pattern.preMask = preMask
        pattern.sourceTemplates = sourceTemplateArray
        // FIXME: Pattern 리팩토링 임시 처리
        pattern.targetTemplate = trimmedTargetTemplates[0]
        pattern.roles = roleList
//        pattern.sourceJoiners = sourceJoinerArray
//        pattern.leftRole = trimmedLeftRole.isEmpty ? nil : trimmedLeftRole
//        pattern.rightRole = trimmedRightRole.isEmpty ? nil : trimmedRightRole

        let meta: Glossary.SDModel.SDPatternMeta
        if let existing = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>(predicate: #Predicate { $0.name == trimmedID })).first {
            meta = existing
        } else {
            meta = Glossary.SDModel.SDPatternMeta(name: trimmedID, displayName: displayName.isEmpty ? trimmedID : displayName, grouping: grouping, groupLabel: groupLabel, defaultProhibitStandalone: defaultProhibit, defaultIsAppellation: defaultIsAppellation, defaultPreMask: defaultPreMask)
            context.insert(meta)
        }
        meta.displayName = displayName.isEmpty ? trimmedID : displayName
        meta.grouping = grouping
        meta.groupLabel = groupLabel
        meta.defaultProhibitStandalone = defaultProhibit
        meta.defaultIsAppellation = defaultIsAppellation
        meta.defaultPreMask = defaultPreMask

        try context.save()
        didSave = true
    }

    func delete() throws {
        guard let originalID,
              let pattern = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: #Predicate { $0.name == originalID })).first else {
            return
        }
        context.delete(pattern)
        if let meta = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPatternMeta>(predicate: #Predicate { $0.name == originalID })).first {
            context.delete(meta)
        }
        try context.save()
        didSave = true
    }

}
