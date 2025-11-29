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
                || [pattern.targetTemplate].contains { $0.contains("{R}") } // FIXME: Pattern 리팩토링 임시 처리

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

    /// 공통: roles 순서대로 cartesian product를 만들어 [[role: AppearedComponent]] 반환
    private func cartesianTuples(
        roles: [String],
        componentsByRole: [String: [AppearedComponent]],
        skipIfSameTerm: Bool
    ) -> [[String: AppearedComponent]] {
        var results: [[String: AppearedComponent]] = []
        var current: [String: AppearedComponent] = [:]
        var usedTermKeys: Set<String> = []

        func dfs(_ index: Int) {
            if index == roles.count {
                results.append(current)
                return
            }

            let role = roles[index]
            guard let candidates = componentsByRole[role], !candidates.isEmpty else {
                // 이 role을 채울 수 없으면 이 브랜치는 버림
                return
            }

            for comp in candidates {
                let key = comp.appearedTerm.key
                if skipIfSameTerm, usedTermKeys.contains(key) {
                    continue
                }

                current[role] = comp
                if skipIfSameTerm {
                    usedTermKeys.insert(key)
                }

                dfs(index + 1)

                if skipIfSameTerm {
                    usedTermKeys.remove(key)
                }
                current.removeValue(forKey: role)
            }
        }

        dfs(0)
        return results
    }

    /// n항 패턴 조합 생성 (그룹 없음 + 그룹 있음 통합)
    ///
    /// - componentsByRole: role → 해당 role에 속한 AppearedComponent 리스트
    /// - roles: 패턴이 요구하는 role 순서 (예: ["prefix", "name", "suffix"])
    /// - skipIfSameTerm: 한 조합 안에 같은 appearedTerm.key가 두 번 이상 나오지 않게 할지 여부
    /// - useGroups: 이 패턴이 group 기반 매칭을 사용하는지 여부
    func makeComponentTuples(
        componentsByRole: [String: [AppearedComponent]],
        roles: [String],
        skipIfSameTerm: Bool,
        useGroups: Bool
    ) -> [[String: AppearedComponent]] {
        // 그룹을 사용하지 않는 패턴: 그냥 cartesian product
        guard useGroups else {
            return cartesianTuples(
                roles: roles,
                componentsByRole: componentsByRole,
                skipIfSameTerm: skipIfSameTerm
            )
        }

        // 그룹을 사용하는 패턴: groupId별로 role → [AppearedComponent] 를 만들고,
        // 각 group에 대해 cartesianTuples를 돌린 뒤 전부 합친다.
        typealias RoleMap = [String: [AppearedComponent]]
        var byGroup: [String: RoleMap] = [:]

        for (role, comps) in componentsByRole {
            for comp in comps {
                for gid in comp.groupLinks.map({ $0.group.uid }) {
                    var roleMap = byGroup[gid] ?? [:]
                    roleMap[role, default: []].append(comp)
                    byGroup[gid] = roleMap
                }
            }
        }

        var allResults: [[String: AppearedComponent]] = []

        for (_, roleMap) in byGroup {
            // 이 그룹에서 모든 roles를 채울 수 없는 경우는 스킵
            let hasAllRoles = roles.allSatisfy { roleMap[$0]?.isEmpty == false }
            if !hasAllRoles {
                continue
            }

            let tuples = cartesianTuples(
                roles: roles,
                componentsByRole: roleMap,
                skipIfSameTerm: skipIfSameTerm
            )
            allResults.append(contentsOf: tuples)
        }

        return allResults
    }

    
    private func matchedComponents(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [[String: AppearedComponent]] {
        let roles = pattern.roles
        // pattern에는 role이 최소 1개 존재해야함
        guard let firstRole = roles.first else { return [] }
        let isSoloPattern = roles.count == 1
        
        var componentsByRole: [String: [AppearedComponent]] = [:]
        var hasAnyGroup = false
        for appearedTerm in appearedTerms {
            for component in appearedTerm.components where component.pattern == pattern.name {
                var role: String?
                if isSoloPattern {
                    // 단항 패턴
                    role = firstRole
                } else {
                    // 다항 패턴
                    role = component.role
                }
                if let role {
                    var components = componentsByRole[role] ?? []
                    components.append(AppearedComponent(component: component, appearedTerm: appearedTerm))
                    componentsByRole[role] = components
                }
                
                if !component.groupLinks.isEmpty { hasAnyGroup = true }
            }
        }
        
        return makeComponentTuples(componentsByRole: componentsByRole, roles: roles, skipIfSameTerm: pattern.skipPairsIfSameTerm, useGroups: hasAnyGroup)
    }

//    private func matchedPairs(
//        for pattern: Glossary.SDModel.SDPattern,
//        appearedTerms: [AppearedTerm]
//    ) -> [(AppearedComponent, AppearedComponent)] {
//        var lefts: [AppearedComponent] = []
//        var rights: [AppearedComponent] = []
//        var hasAnyGroup = false
//
//        for appearedTerm in appearedTerms {
//            for component in appearedTerm.components where component.pattern == pattern.name {
//                // FIXME: Pattern 리팩토링 임시 처리
//                let isLeft = true//matchesRole(component.role, required: pattern.leftRole)
//                let isRight = true//matchesRole(component.role, required: pattern.rightRole)
//
//                if component.groupLinks.isEmpty == false { hasAnyGroup = true }
//
//                let appearedComponent = AppearedComponent(component: component, appearedTerm: appearedTerm)
//                if isLeft { lefts.append(appearedComponent) }
//                if isRight { rights.append(appearedComponent) }
//            }
//        }
//
//        if hasAnyGroup == false {
//            var pairs: [(AppearedComponent, AppearedComponent)] = []
//            for l in lefts {
//                for r in rights where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
//                    pairs.append((l, r))
//                }
//            }
//            return pairs
//        }
//
//        var leftByGroup: [String: [AppearedComponent]] = [:]
//        var rightByGroup: [String: [AppearedComponent]] = [:]
//
//        for component in lefts {
//            for g in component.groupLinks.map({ $0.group.uid }) {
//                leftByGroup[g, default: []].append(component)
//            }
//        }
//        for component in rights {
//            for g in component.groupLinks.map({ $0.group.uid }) {
//                rightByGroup[g, default: []].append(component)
//            }
//        }
//
//        var pairs: [(AppearedComponent, AppearedComponent)] = []
//        for g in leftByGroup.keys {
//            guard let ls = leftByGroup[g], let rs = rightByGroup[g] else { continue }
//            for l in ls {
//                for r in rs where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
//                    pairs.append((l, r))
//                }
//            }
//        }
//
//        return pairs
//    }
//
//    private func matchedLeftComponents(
//        for pattern: Glossary.SDModel.SDPattern,
//        appearedTerms: [AppearedTerm]
//    ) -> [AppearedComponent] {
//        var out: [AppearedComponent] = []
//        for appearedTerm in appearedTerms {
//            for component in appearedTerm.components where component.pattern == pattern.name {
//                // FIXME: Pattern 리팩토링 임시 처리
//                if let role = component.role, pattern.roles.contains(role) /*matchesRole(component.role, required: pattern.leftRole)*/ {
//                    out.append(AppearedComponent(component: component, appearedTerm: appearedTerm))
//                }
//            }
//        }
//        return out
//    }
    
    private func buildEntriesFromTuples(
        tuples: [[String: AppearedComponent]],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        for tuple in tuples {
            let sourceTemplates = pattern.sourceTemplates
            for sourceTemplate in sourceTemplates {
                let src = 
            }
        }
    }

    private func buildEntriesFromPairs(
        pairs: [(AppearedComponent, AppearedComponent)],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        // FIXME: Pattern 리팩토링 임시 처리
        let joiners = [""]//Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for (lComp, rComp) in pairs {
            let leftTerm = lComp.appearedTerm
            let rightTerm = rComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? rComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? rComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}{J}{R}"
            // FIXME: Pattern 리팩토링 임시 처리
            let tgtTpl = pattern.targetTemplate/*s[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L} {R}"*/
            let variants: [String] = Glossary.Util.renderVariants(tgtTpl, joiners: [""], L: leftTerm.sdTerm, R: rightTerm.sdTerm)

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
                                needPairCheck: false //pattern.needPairCheck // FIXME: Pattern 리팩토링 임시 처리
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
        let joiners = Glossary.Util.filterJoiners(from: [""]/*pattern.sourceJoiners*/, in: segmentText) // FIXME: Pattern 리팩토링 임시 처리

        for lComp in lefts {
            let term = lComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}"
            let tgtTpl = pattern.targetTemplate/*s[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L}"*/ // FIXME: Pattern 리팩토링 임시 처리
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
