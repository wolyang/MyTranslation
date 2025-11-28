//
//  SegmentTermMatcher.swift
//  MyTranslation
//

import Foundation

final class SegmentTermMatcher {

    func findAppearedTerms(
        segmentText: String,
        matchedTerms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>]
    ) -> [AppearedTerm] {
        matchedTerms.compactMap { term in
            let matchedSourceTexts = matchedSources[term.key] ?? []
            let filteredSources = term.sources.filter { source in
                guard matchedSourceTexts.contains(source.text), segmentText.contains(source.text) else { return false }
                return shouldKeep(term: term, segmentText: segmentText)
            }
            guard filteredSources.isEmpty == false else { return nil }
            return AppearedTerm(sdTerm: term, appearedSources: filteredSources)
        }
    }

    private func shouldKeep(term: Glossary.SDModel.SDTerm, segmentText: String) -> Bool {
        guard term.deactivatedIn.isEmpty == false else { return true }
        for ctx in term.deactivatedIn where ctx.isEmpty == false {
            if segmentText.contains(ctx) { return false }
        }
        return true
    }
}
