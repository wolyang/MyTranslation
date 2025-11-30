import Foundation
import SwiftData

@MainActor
extension TermEditorViewModel {
    func addComponentDraft() {
        componentDrafts.append(
            ComponentDraft(
                existingID: nil,
                patternID: nil,
                roleName: "",
                selectedGroupUID: nil,
                customGroupName: ""
            )
        )
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
    }

    func updateComponents(for term: Glossary.SDModel.SDTerm) throws {
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
            let component = Glossary.SDModel.SDComponent(pattern: patternID, role: roleValue, term: term)
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

    func resolvedGroupName(forPattern pattern: PatternReference, fallback: String) throws -> String? {
        let trimmedCustom = newGroupName.trimmingCharacters(in: .whitespaces)
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if let selectedGroupID,
           let group = patternGroups.first(where: { $0.id == selectedGroupID }) {
            return group.name
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespaces)
        return trimmedFallback.isEmpty ? nil : trimmedFallback
    }

    func resolvedGroupName(from draft: ComponentDraft, option: PatternOption) throws -> String? {
        if option.grouping == .none { return nil }
        let trimmedCustom = draft.customGroupName.trimmingCharacters(in: .whitespaces)
        if !trimmedCustom.isEmpty { return trimmedCustom }
        if let selected = draft.selectedGroupUID,
           let found = option.groups.first(where: { $0.id == selected }) {
            return found.name
        }
        return nil
    }

    func fetchOrCreateGroup(patternID: String, name: String) throws -> Glossary.SDModel.SDGroup {
        let uid = "\(patternID)#\(name)"
        if let group = try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>(predicate: #Predicate { $0.uid == uid })).first {
            return group
        }
        let group = Glossary.SDModel.SDGroup(uid: uid, pattern: patternID, name: name)
        context.insert(group)
        return group
    }
}
