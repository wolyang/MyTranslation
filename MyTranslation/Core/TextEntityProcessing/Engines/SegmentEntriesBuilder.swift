//
//  SegmentEntriesBuilder.swift
//  MyTranslation
//

import Foundation

final class SegmentEntriesBuilder {

    func buildComposerEntries(
        patterns: [Glossary.SDModel.SDPattern],
        appearedTerms: [AppearedTerm],
        segmentText: String
    ) -> [GlossaryEntry] {
        var allEntries: [GlossaryEntry] = []

        for pattern in patterns {
            let usesR = pattern.sourceTemplates.contains { $0.contains("{R}") }
                || pattern.targetTemplates.contains { $0.contains("{R}") }

            if usesR {
                let pairs = matchedPairs(for: pattern, appearedTerms: appearedTerms)
                allEntries.append(contentsOf: buildEntriesFromPairs(
                    pairs: pairs,
                    pattern: pattern,
                    segmentText: segmentText
                ))
            } else {
                let lefts = matchedLeftComponents(for: pattern, appearedTerms: appearedTerms)
                allEntries.append(contentsOf: buildEntriesFromLefts(
                    lefts: lefts,
                    pattern: pattern,
                    segmentText: segmentText
                ))
            }
        }

        return allEntries
    }

    private func matchedPairs(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [(AppearedComponent, AppearedComponent)] {
        var lefts: [AppearedComponent] = []
        var rights: [AppearedComponent] = []
        var hasAnyGroup = false

        for appearedTerm in appearedTerms {
            for component in appearedTerm.components where component.pattern == pattern.name {
                let isLeft = matchesRole(component.role, required: pattern.leftRole)
                let isRight = matchesRole(component.role, required: pattern.rightRole)

                if component.groupLinks.isEmpty == false { hasAnyGroup = true }

                let appearedComponent = AppearedComponent(component: component, appearedTerm: appearedTerm)
                if isLeft { lefts.append(appearedComponent) }
                if isRight { rights.append(appearedComponent) }
            }
        }

        if hasAnyGroup == false {
            var pairs: [(AppearedComponent, AppearedComponent)] = []
            for l in lefts {
                for r in rights where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                    pairs.append((l, r))
                }
            }
            return pairs
        }

        var leftByGroup: [String: [AppearedComponent]] = [:]
        var rightByGroup: [String: [AppearedComponent]] = [:]

        for component in lefts {
            for g in component.groupLinks.map({ $0.group.uid }) {
                leftByGroup[g, default: []].append(component)
            }
        }
        for component in rights {
            for g in component.groupLinks.map({ $0.group.uid }) {
                rightByGroup[g, default: []].append(component)
            }
        }

        var pairs: [(AppearedComponent, AppearedComponent)] = []
        for g in leftByGroup.keys {
            guard let ls = leftByGroup[g], let rs = rightByGroup[g] else { continue }
            for l in ls {
                for r in rs where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                    pairs.append((l, r))
                }
            }
        }

        return pairs
    }

    private func matchedLeftComponents(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [AppearedComponent] {
        var out: [AppearedComponent] = []
        for appearedTerm in appearedTerms {
            for component in appearedTerm.components where component.pattern == pattern.name {
                if matchesRole(component.role, required: pattern.leftRole) {
                    out.append(AppearedComponent(component: component, appearedTerm: appearedTerm))
                }
            }
        }
        return out
    }

    private func buildEntriesFromPairs(
        pairs: [(AppearedComponent, AppearedComponent)],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for (lComp, rComp) in pairs {
            let leftTerm = lComp.appearedTerm
            let rightTerm = rComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? rComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? rComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}{J}{R}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L} {R}"
            let variants: [String] = Glossary.Util.renderVariants(tgtTpl, joiners: pattern.sourceJoiners, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: leftTerm.sdTerm, R: rightTerm.sdTerm)
                let tgt = Glossary.Util.renderTarget(tgtTpl, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src.composed,
                            target: tgt,
                            variants: variants,
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: leftTerm.key,
                                rightKey: rightTerm.key,
                                needPairCheck: pattern.needPairCheck
                            ),
                            componentTerms: [
                                GlossaryEntry.ComponentTerm(
                                    key: leftTerm.key,
                                    target: leftTerm.target,
                                    variants: leftTerm.variants,
                                    source: src.left
                                ),
                                GlossaryEntry.ComponentTerm(
                                    key: rightTerm.key,
                                    target: rightTerm.target,
                                    variants: rightTerm.variants,
                                    source: src.right
                                )
                            ]
                        )
                    )
                }
            }
        }

        return entries
    }

    private func buildEntriesFromLefts(
        lefts: [AppearedComponent],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for lComp in lefts {
            let term = lComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L}"
            let tgt = Glossary.Util.renderTarget(tgtTpl, L: term.sdTerm, R: nil)
            let variants = Glossary.Util.renderVariants(tgtTpl, joiners: joiners, L: term.sdTerm, R: nil)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: term.sdTerm, R: nil)

                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src.composed,
                            target: tgt,
                            variants: variants,
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: term.key,
                                rightKey: nil,
                                needPairCheck: false
                            ),
                            componentTerms: [
                                GlossaryEntry.ComponentTerm(
                                    key: term.key,
                                    target: term.target,
                                    variants: term.variants,
                                    source: src.left
                                )
                            ]
                        )
                    )
                }
            }
        }

        return entries
    }

    private func matchesRole(_ componentRole: String?, required: String?) -> Bool {
        guard
            let requiredRole = required?.trimmingCharacters(in: .whitespacesAndNewlines),
            requiredRole.isEmpty == false
        else {
            return true
        }
        guard
            let role = componentRole?.trimmingCharacters(in: .whitespacesAndNewlines),
            role.isEmpty == false
        else {
            return false
        }
        return role == requiredRole
    }
}
