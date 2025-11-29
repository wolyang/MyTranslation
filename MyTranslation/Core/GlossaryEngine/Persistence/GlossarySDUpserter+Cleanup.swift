import Foundation
import SwiftData

extension Glossary.SDModel.GlossaryUpserter {
    func deleteMissing(bundle: JSBundle) throws {
        if sync.removeMissingTerms {
            let existingTerms = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>())
            let incoming = Set(bundle.terms.map { $0.key })
            let candidates = existingTerms.filter { !incoming.contains($0.key) }
            let filteredTerms: [Glossary.SDModel.SDTerm]
            if let filter = sync.termDeletionFilter {
                filteredTerms = candidates.filter { filter($0.key) }
            } else {
                filteredTerms = candidates
            }
            for term in filteredTerms {
                try Glossary.SDModel.SourceIndexMaintainer.deleteAll(for: term, in: context)
                context.delete(term)
            }
        }
        if sync.removeMissingPatterns {
            let existing = try fetchAllKeys(Glossary.SDModel.SDPattern.self, key: \Glossary.SDModel.SDPattern.name)
            let incoming = Set(bundle.patterns.map { $0.name })
            let candidates = existing.subtracting(incoming)
            let filtered = sync.patternDeletionFilter.map { filter in candidates.filter { filter($0) } } ?? Array(candidates)
            for name in filtered {
                let pred = #Predicate<Glossary.SDModel.SDPattern> { $0.name == name }
                for p in try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>(predicate: pred)) { context.delete(p) }
            }
        }
    }

    func cleanupOrphans() throws {
        for tag in try context.fetch(FetchDescriptor<Glossary.SDModel.SDTag>()) where tag.termLinks.isEmpty { context.delete(tag) }
        for group in try context.fetch(FetchDescriptor<Glossary.SDModel.SDGroup>()) where group.componentLinks.isEmpty { context.delete(group) }
    }
}
