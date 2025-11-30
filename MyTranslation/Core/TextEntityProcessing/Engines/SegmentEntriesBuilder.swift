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
            let matched = matchedComponents(for: pattern, appearedTerms: appearedTerms)
            allEntries.append(contentsOf: buildEntriesFromTuples(tuples: matched, pattern: pattern).filter({ entry in
                segmentText.contains(entry.source)
            }))
        }

        return allEntries
    }
    
    /// "{name}{name}" 같은 role 기반 템플릿을
    /// "{name_1}{name_2}" 같은 slot 기반 템플릿으로 바꾸고,
    /// slot 순서와 slot→role 매핑을 돌려준다.
    struct SlotInfo {
        let rewrittenTemplate: String       // 예: "{name_1}{name_2}"
        let slotOrder: [String]            // 예: ["name_1", "name_2"]
        let slotToRole: [String: String]   // 예: ["name_1": "name", "name_2": "name"]
    }

    func rewriteTemplateWithSlots(_ template: String) -> SlotInfo {
        var result = ""
        var roleCounts: [String: Int] = [:]
        var slotOrder: [String] = []
        var slotToRole: [String: String] = [:]

        var inside = false
        var currentRole = ""

        for ch in template {
            if ch == "{" {
                inside = true
                currentRole = ""
                result.append("{")
            } else if ch == "}" {
                inside = false
                let role = currentRole

                let count = (roleCounts[role] ?? 0) + 1
                roleCounts[role] = count

                let slot = "\(role)_\(count)"   // name_1, name_2 같은 형태

                slotOrder.append(slot)
                slotToRole[slot] = role

                result.append(slot)
                result.append("}")
            } else if inside {
                currentRole.append(ch)
            } else {
                result.append(ch)
            }
        }

        return SlotInfo(
            rewrittenTemplate: result,
            slotOrder: slotOrder,
            slotToRole: slotToRole
        )
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

    /// role별 AppearedComponent들을, slot 정보에 맞춰
    /// [[slot: AppearedComponent]] 조합으로 펼친다.
    /// - componentsByRole: "name" 같은 role 기준으로 모인 컴포넌트들
    /// - slotOrder: ["name_1", "name_2", ...] 같은 slot 순서
    /// - slotToRole: ["name_1": "name", "name_2": "name", ...]
    /// - skipSameTerm: 같은 AppearedTerm.key를 한 튜플 안에서 중복 사용하지 않을지 여부
    /// - useGroups: true면 같은 group.uid 안에서만 조합을 만든다
    func makeTuplesWithSlots(
        componentsByRole: [String: [AppearedComponent]],
        slotOrder: [String],
        slotToRole: [String: String],
        skipSameTerm: Bool,
        useGroups: Bool
    ) -> [[String: AppearedComponent]] {

        // MARK: - 그룹을 쓰지 않는 경우: 단순 카테시안 곱
        guard useGroups else {
            var results: [[String: AppearedComponent]] = []
            var current: [String: AppearedComponent] = [:]
            var usedTermKeys: Set<String> = []

            func dfs(_ index: Int) {
                if index == slotOrder.count {
                    results.append(current)
                    return
                }

                let slot = slotOrder[index]
                guard let role = slotToRole[slot],
                      let candidates = componentsByRole[role],
                      !candidates.isEmpty else {
                    return
                }

                for comp in candidates {
                    let key = comp.appearedTerm.key
                    if skipSameTerm, usedTermKeys.contains(key) {
                        continue
                    }

                    current[slot] = comp
                    if skipSameTerm { usedTermKeys.insert(key) }

                    dfs(index + 1)

                    if skipSameTerm { usedTermKeys.remove(key) }
                    current.removeValue(forKey: slot)
                }
            }

            dfs(0)
            return results
        }

        // MARK: - 그룹을 사용하는 경우
        // groupId → (role → [AppearedComponent]) 맵을 만든다.
        typealias RoleMap = [String: [AppearedComponent]]
        var byGroup: [String: RoleMap] = [:]

        for (role, comps) in componentsByRole {
            for comp in comps {
                for link in comp.groupLinks {
                    let gid = link.group.uid
                    var roleMap = byGroup[gid] ?? [:]
                    roleMap[role, default: []].append(comp)
                    byGroup[gid] = roleMap
                }
            }
        }

        var allResults: [[String: AppearedComponent]] = []

        // 각 groupId마다 slotOrder를 기준으로 DFS
        for (_, roleMap) in byGroup {
            // 이 그룹 안에서 모든 slot이 최소 1개 이상의 후보를 가질 수 있는지 체크
            let groupCanFillAllSlots = slotOrder.allSatisfy { slot in
                guard let role = slotToRole[slot],
                      let cs = roleMap[role] else { return false }
                return !cs.isEmpty
            }
            if !groupCanFillAllSlots { continue }

            var current: [String: AppearedComponent] = [:]
            var usedTermKeys: Set<String> = []

            func dfs(_ index: Int) {
                if index == slotOrder.count {
                    allResults.append(current)
                    return
                }

                let slot = slotOrder[index]
                guard let role = slotToRole[slot],
                      let candidates = roleMap[role],
                      !candidates.isEmpty else {
                    return
                }

                for comp in candidates {
                    let key = comp.appearedTerm.key
                    if skipSameTerm, usedTermKeys.contains(key) {
                        continue
                    }

                    current[slot] = comp
                    if skipSameTerm { usedTermKeys.insert(key) }

                    dfs(index + 1)

                    if skipSameTerm { usedTermKeys.remove(key) }
                    current.removeValue(forKey: slot)
                }
            }

            dfs(0)
        }

        return allResults
    }


    
    private func collectComponentsByRole(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> (hasAnyGroup: Bool, componentsByRole: [String: [AppearedComponent]]) {
        let roles = pattern.roles
        // pattern에는 role이 최소 1개 존재해야함
        guard let firstRole = roles.first else { return (false, [:]) }
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
        
        return (hasAnyGroup, componentsByRole)
    }
    
    /// SDPattern과 appearedTerms를 바탕으로
    /// slot 기준 n항 조합 [[slot: AppearedComponent]]를 만든다.
    func matchedComponents(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [[String: AppearedComponent]] {

        // 1) role 기준으로 AppearedComponent 모으기
        //    예: "name" → [comp1, comp2, ...]
        let (hasAnyGroup, componentsByRole) = collectComponentsByRole(
            for: pattern,
            appearedTerms: appearedTerms
        )

        // role 기준 템플릿을 slot 템플릿으로 재작성해서
        // slotOrder, slotToRole 정보를 얻는다.
        let slotInfo = rewriteTemplateWithSlots(pattern.targetTemplate)
        // slotInfo:
        //  - rewrittenTemplate: "{name}{name}" → "{name_1}{name_2}"
        //  - slotOrder: ["name_1", "name_2"]
        //  - slotToRole: ["name_1": "name", "name_2": "name"]

        // 3) slot + group + skipSameTerm 규칙을 적용해서
        //    [[slot: AppearedComponent]] 튜플들을 만든다.
        let tuplesBySlot = makeTuplesWithSlots(
            componentsByRole: componentsByRole,
            slotOrder: slotInfo.slotOrder,
            slotToRole: slotInfo.slotToRole,
            skipSameTerm: pattern.skipPairsIfSameTerm,
            useGroups: hasAnyGroup
        )

        return tuplesBySlot
    }
    
    private func buildEntriesFromTuples(
        tuples: [[String: AppearedComponent]],          // slot -> AppearedComponent
        pattern: Glossary.SDModel.SDPattern
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        // canonical + variant 템플릿
        let targetTemplates: [String] = [pattern.targetTemplate] + pattern.variantTemplates

        for componentsBySlot in tuples {
            // 1) target / variants 생성
            let target = Glossary.Util.renderTarget(
                pattern.targetTemplate,
                componentsBySlot: componentsBySlot
            )

            let variants = Glossary.Util.renderVariants(
                templates: targetTemplates,
                componentsBySlot: componentsBySlot
            )

            // 2) sourceTemplates * source-variants 조합만큼 GlossaryEntry 생성
            for srcTpl in pattern.sourceTemplates {
                let renderedSources = Glossary.Util.renderSources(
                    srcTpl,
                    componentsBySlot: componentsBySlot
                )

                for rendered in renderedSources {
                    // 3) 이 entry 전용 componentTerms 생성
                    var componentTerms: [GlossaryEntry.ComponentTerm] = []

                    for (slot, comp) in componentsBySlot {
                        let term = comp.appearedTerm
                        let partSource = rendered.sourcesBySlot[slot] ?? term.appearedSources.first?.text ?? ""

                        componentTerms.append(
                            GlossaryEntry.ComponentTerm(
                                key: term.key,
                                target: term.target,
                                variants: term.variants,
                                source: partSource
                            )
                        )
                    }

                    let ordered = componentTerms.sorted { $0.key < $1.key }

                    let entry = GlossaryEntry(
                        source: rendered.composed,
                        target: target,
                        variants: variants,
                        preMask: pattern.preMask,
                        isAppellation: pattern.isAppellation,
                        origin: .composer(
                            composerId: pattern.name,
                            termKeys: ordered.map({ $0.key })
                        ),
                        componentTerms: componentTerms
                    )

                    entries.append(entry)
                }
            }
        }

        return entries
    }
}
