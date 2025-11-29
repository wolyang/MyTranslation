//
//  GlossaryJSONParser.swift
//  MyTranslation
//
//  Created by sailor.m on 11/8/25.
//

import Foundation

// MARK: - DSL Helpers
struct SelectorParseResult {
    var role: String? = nil
    var tagsAll: [String]? = nil
    var tagsAny: [String]? = nil
    var includeRefs: [String] = [] // ref 또는 key 문자열 (원본)
    var excludeRefs: [String] = []
}

func parseSelectorDSL(_ s: String?) -> SelectorParseResult {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .init() }
    var result = SelectorParseResult()
    for token in s.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
        guard let sep = token.firstIndex(of: ":") else { continue }
        let key = token[..<sep].trimmingCharacters(in: .whitespaces)
        let val = token[token.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        switch key.lowercased() {
        case "role":
            let role = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            result.role = role
        case "tags":
            let tags = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            result.tagsAll = tags.isEmpty ? nil : tags
        case "tagsany":
            let tags = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            result.tagsAny = tags.isEmpty ? nil : tags
        case "include":
            result.includeRefs.append(contentsOf: val.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        case "exclude":
            result.excludeRefs.append(contentsOf: val.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        default:
            continue
        }
    }
    return result
}

// MARK: - Slug / Key
func latinSlug(_ s: String) -> String {
    let transformed = s.applyingTransform(.toLatin, reverse: false) ?? s
    let alnum = transformed.uppercased().map { ch -> Character in
        if ("A" ... "Z").contains(ch) || ("0" ... "9").contains(ch) { return ch }
        return "_"
    }
    let squashed = String(alnum).replacingOccurrences(of: "_+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return squashed
}

// MARK: - Ref Resolver
struct RefIndex {
    // ref(원문) → key(해석)
    var refToKey: [String: String] = [:]
    // target 인덱스 (시트명 + target → key)
    var bySheetTarget: [String: String] = [:]
}

func refToken(sheet: String, target: String) -> String { "ref:\(sheet):\(target)" }

// MARK: - Row Adapters
struct TermRow {
    let key: String
    let sourcesOK: String
    let sourcesProhibit: String
    let target: String
    let variants: String
    let tags: String
    let components: String
    let isAppellation: Bool
    let preMask: Bool
    let activatedBy: String
    let deactivatedIn: String
}

struct PatternRow {
    let name: String
    let displayName: String
    let roles: String
    let role_combinations: String
    let grouping: String
    let groupLabel: String
    let sourceTemplates: String
    let targetTemplate: String
    let variantTemplates: String
    let skipSame: Bool
    let isAppellation: Bool
    let preMask: Bool
    let defProhibit: Bool
    let defIsAppellation: Bool
    let defPreMask: Bool
}

struct AppellationRow {
    let source: String
    let target: String
    let variants: String // 세미콜론 분리
    let position: String // prefix|suffix
    let prohibit: Bool
}

// MARK: - Parsers
func parseTermRow(sheetName: String, row: TermRow, used: inout Set<String>, refIndex: inout RefIndex) -> JSTerm {
    func splitSemi(_ s: String) -> [String] { s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    let ok = splitSemi(row.sourcesOK).map { JSSource(source: $0, prohibitStandalone: false) }
    let ng = splitSemi(row.sourcesProhibit).map { JSSource(source: $0, prohibitStandalone: true) }
    let sources = ok + ng

    let variants = splitSemi(row.variants)
    let tags = splitSemi(row.tags)
    let deactivatedIn = splitSemi(row.deactivatedIn)

    // activatedBy 파싱: 쉼표 또는 세미콜론으로 분리, 공백 trim
    let activatedByKeys = row.activatedBy
        .split(whereSeparator: { $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // Components DSL: pattern[:role][-group1|group2][#sN][#tM]; ...
    let components: [JSComponent] = splitSemi(row.components).map { token in
        var pattern = ""
        var role: String? = nil
        var groups: [String]? = nil

        var core = token.trimmingCharacters(in: .whitespaces)
        
        // pattern[:role][-groups]
        let roleSplit = core.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let patternSegment = roleSplit[0]
        let patternParts = patternSegment.split(separator: "-", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        pattern = patternParts.first ?? ""
        var parsedGroups: [String] = []
        if patternParts.count == 2 {
            parsedGroups.append(contentsOf: patternParts[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if roleSplit.count == 2 {
            let roleSection = roleSplit[1]
            let roleParts = roleSection.split(separator: "-", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if let roleName = roleParts.first, !roleName.isEmpty {
                role = roleName
            }
            if roleParts.count == 2 {
                parsedGroups.append(contentsOf: roleParts[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        }
        if !parsedGroups.isEmpty {
            var seen: Set<String> = []
            var ordered: [String] = []
            for name in parsedGroups where !name.isEmpty {
                if seen.insert(name).inserted { ordered.append(name) }
            }
            groups = ordered
        }
        return JSComponent(pattern: pattern, role: role, groups: groups)
    }

    var keySet = used
    let key = row.key
    used = keySet

    // ref 인덱스 등록
    let ref = refToken(sheet: sheetName, target: row.target)
    refIndex.refToKey[ref] = key
    refIndex.bySheetTarget[ref] = key

    return JSTerm(
        key: key,
        sources: sources,
        target: row.target,
        variants: variants,
        tags: tags,
        components: components,
        isAppellation: row.isAppellation,
        preMask: row.preMask,
        deactivatedIn: deactivatedIn,
        activatedByKeys: activatedByKeys.isEmpty ? nil : activatedByKeys
    )
}

func parsePatternRow(_ row: PatternRow) -> [JSPattern] {
    func splitSemi(_ s: String) -> [String] { s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    // roleCombinations에서 role의 집합을 계산
    func parseRoleCombination(_ text: String) -> [String] {
        text.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    // template에서 role의 집합을 계산
    func extractRoles(from template: String) -> Set<String> {
        var roles: Set<String> = []
        var current: String = ""
        var inside = false
        
        for ch in template {
            if ch == "{" {
                inside = true
                current = ""
            } else if ch == "}" {
                inside = false
                if !current.isEmpty {
                    roles.insert(current)
                }
            } else if inside {
                current.append(ch)
            }
        }
        return roles
    }

    let grouping = JSGrouping(rawValue: row.grouping) ?? .required
    
    let roleCombinations = splitSemi(row.role_combinations)
    if roleCombinations.count > 1 {
        var patterns: [JSPattern] = []
        for (i, combination) in roleCombinations.enumerated() {
            let roles = parseRoleCombination(combination)
            let combiName = combination.replacingOccurrences(of: "+", with: "_")
            let sourceTemplates = splitSemi(row.sourceTemplates)
            let matchedSourceTemplates = sourceTemplates.filter({ extractRoles(from: $0) == Set(roles) })
            let targetTemplate = splitSemi(row.targetTemplate)[safe: i] ?? row.targetTemplate
            let variantTemplates = splitSemi(row.variantTemplates)
            let matchedVariantTemplates = variantTemplates.filter({ extractRoles(from: $0) == Set(roles) })
            
            patterns.append(JSPattern(
                name: row.name + "_" + combiName,
                skipPairsIfSameTerm: row.skipSame,
                sourceTemplates: matchedSourceTemplates,
                targetTemplate: targetTemplate,
                variantTemplates: matchedVariantTemplates,
                isAppellation: row.isAppellation,
                preMask: row.preMask,
                displayName: row.displayName,
                roles: roles,
                grouping: grouping,
                groupLabel: row.groupLabel,
                defaultProhibitStandalone: row.defProhibit,
                defaultIsAppellation: row.defIsAppellation,
                defaultPreMask: row.defPreMask
            ))
        }
        return patterns
    } else {
        return [
            JSPattern(
                name: row.name,
                skipPairsIfSameTerm: row.skipSame,
                sourceTemplates: splitSemi(row.sourceTemplates),
                targetTemplate: row.targetTemplate,
                variantTemplates: splitSemi(row.variantTemplates),
                isAppellation: row.isAppellation,
                preMask: row.preMask,
                displayName: row.displayName,
                roles: splitSemi(row.roles),
                grouping: grouping,
                groupLabel: row.groupLabel,
                defaultProhibitStandalone: row.defProhibit,
                defaultIsAppellation: row.defIsAppellation,
                defaultPreMask: row.defPreMask
            )
        ]
    }
    
}

// MARK: - 전체 변환 함수

func buildGlossaryJSON(
    termsBySheet: [String: [TermRow]],
    patterns: [PatternRow]
) throws -> JSBundle {
    var usedKeys: Set<String> = []
    var refIndex = RefIndex()

    // 1) Terms
    var allTerms: [JSTerm] = []
    for (sheet, rows) in termsBySheet {
        for r in rows {
            allTerms.append(parseTermRow(sheetName: sheet, row: r, used: &usedKeys, refIndex: &refIndex))
        }
    }

    // 2) Patterns
    let allPatterns = patterns.flatMap { parsePatternRow($0) }

    let bundle = JSBundle(terms: allTerms, patterns: allPatterns)
    return bundle
}
