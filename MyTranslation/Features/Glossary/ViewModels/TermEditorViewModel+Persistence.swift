import Foundation
import SwiftData

@MainActor
extension TermEditorViewModel {
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

    fileprivate func saveGeneral() throws {
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

    fileprivate func savePattern() throws {
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
            let term = Glossary.SDModel.SDTerm(
                key: makeKey(for: trimmedTarget),
                target: trimmedTarget,
                variants: draft.variantArray,
                isAppellation: draft.isAppellation,
                preMask: draft.preMask
            )
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

    fileprivate func saveOrUpdateSources(for term: Glossary.SDModel.SDTerm, draft: RoleDraft) {
        let okSet = Set(draft.okSources)
        let ngSet = Set(draft.ngSources)
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

    fileprivate func apply(draft: RoleDraft, to term: Glossary.SDModel.SDTerm) {
        term.target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        term.variants = draft.variantArray
        term.isAppellation = draft.isAppellation
        term.preMask = draft.preMask
        saveOrUpdateSources(for: term, draft: draft)
        try? applyTags(draft.tagArray, to: term)
        try? applyActivators(draft.activatedByArray, to: term)
    }

    fileprivate func applySources(draft: RoleDraft, to term: Glossary.SDModel.SDTerm) {
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

    fileprivate func applyTags(_ tags: [String], to term: Glossary.SDModel.SDTerm) throws {
        let trimmed = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let existingLinks: [Glossary.SDModel.SDTermTagLink] = term.termTagLinks
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

    fileprivate func applyActivators(_ activatorKeys: [String], to term: Glossary.SDModel.SDTerm) throws {
        let trimmed = activatorKeys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let oldActivators = term.activators
        for activator in oldActivators where !trimmed.contains(activator.key) {
            if let idx = term.activators.firstIndex(where: { $0.key == activator.key }) {
                term.activators.remove(at: idx)
            }
        }

        for activatorKey in trimmed {
            if term.activators.contains(where: { $0.key == activatorKey }) {
                continue
            }

            let pred = #Predicate<Glossary.SDModel.SDTerm> { $0.key == activatorKey }
            var desc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: pred)
            desc.fetchLimit = 1
            guard let activator = try context.fetch(desc).first else {
                print("[TermEditor][Warning] Activator Term not found: \(activatorKey)")
                continue
            }

            term.activators.append(activator)
        }
    }

    fileprivate func fetchOrCreateTag(name: String) throws -> Glossary.SDModel.SDTag {
        if let tag = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTag>(predicate: #Predicate { $0.name == name })).first {
            return tag
        }
        let tag = Glossary.SDModel.SDTag(name: name)
        context.insert(tag)
        return tag
    }

    fileprivate func attachComponents(terms: [Glossary.SDModel.SDTerm], pattern: PatternReference) throws {
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

    fileprivate func makeKey(for target: String) -> String {
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

    fileprivate func findTerm(target: String, sources: [String], excluding: Glossary.SDModel.SDTerm?) throws -> Glossary.SDModel.SDTerm? {
        let predicate = #Predicate<Glossary.SDModel.SDTerm> { $0.target == target }
        let matches = try context.fetch(FetchDescriptor(predicate: predicate))
        let srcSet = Set(sources)
        for term in matches where term !== excluding {
            let existingSources = Set(term.sources.map { $0.text })
            if !existingSources.isDisjoint(with: srcSet) { return term }
        }
        return nil
    }

    fileprivate func merge(term: Glossary.SDModel.SDTerm, with draft: RoleDraft) throws {
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
}
