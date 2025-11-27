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
    let grouping: String
    let groupLabel: String
    let sourceJoiners: String
    let sourceTemplates: String
    let targetTemplates: String
    let left: String
    let right: String
    let skipSame: Bool
    let isAppellation: Bool
    let preMask: Bool
    let defProhibit: Bool
    let defIsAppellation: Bool
    let defPreMask: Bool
    let needPairCheck: Bool
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
        var srcIdx: Int? = nil
        var tgtIdx: Int? = nil

        var core = token.trimmingCharacters(in: .whitespaces)
        // extract #sN / #tM / #N
        let parts = core.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        if let head = parts.first { core = head }
        for fragment in parts.dropFirst() {
            let trimmed = fragment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("s"), let value = Int(trimmed.dropFirst()) {
                srcIdx = value
            } else if trimmed.hasPrefix("t"), let value = Int(trimmed.dropFirst()) {
                tgtIdx = value
            } else if let value = Int(trimmed) {
                srcIdx = value
                tgtIdx = value
            }
        }
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
        return JSComponent(pattern: pattern, role: role, groups: groups, srcTplIdx: srcIdx, tgtTplIdx: tgtIdx)
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

func parsePatternRow(_ row: PatternRow, resolve: (String) -> String?) -> JSPattern {
    func splitSemi(_ s: String) -> [String] { s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func splitJoiners(_ s: String) -> [String] {
        s.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)   // 트리밍 안 함, 빈 문자열도 그대로 둠
    }

    let leftDSL = parseSelectorDSL(row.left)
    let rightDSL = parseSelectorDSL(row.right)

    func toSelector(_ dsl: SelectorParseResult) -> JSTermSelector? {
        if dsl.role == nil, dsl.tagsAll == nil, dsl.tagsAny == nil, dsl.includeRefs.isEmpty, dsl.excludeRefs.isEmpty { return nil }
        let includeKeys = dsl.includeRefs.compactMap { tok -> String? in
            if tok.lowercased().hasPrefix("ref:") {
                return resolve(tok)
            } else {
                return tok // 이미 key로 간주
            }
        }
        let excludeKeys = dsl.excludeRefs.compactMap { tok -> String? in
            if tok.lowercased().hasPrefix("ref:") {
                return resolve(tok)
            } else {
                return tok
            }
        }
        return JSTermSelector(
            role: dsl.role,
            tagsAll: dsl.tagsAll,
            tagsAny: dsl.tagsAny,
            includeTermKeys: includeKeys.isEmpty ? nil : includeKeys,
            excludeTermKeys: excludeKeys.isEmpty ? nil : excludeKeys
        )
    }

    let grouping = JSGrouping(rawValue: row.grouping) ?? .required
    
    return JSPattern(
        name: row.name,
        left: toSelector(leftDSL),
        right: toSelector(rightDSL),
        skipPairsIfSameTerm: row.skipSame,
        sourceJoiners: splitJoiners(row.sourceJoiners),
        sourceTemplates: splitSemi(row.sourceTemplates),
        targetTemplates: splitSemi(row.targetTemplates),
        isAppellation: row.isAppellation,
        preMask: row.preMask,
        displayName: row.displayName,
            roles: splitSemi(row.roles),
        grouping: grouping,
        groupLabel: row.groupLabel,
        defaultProhibitStandalone: row.defProhibit,
        defaultIsAppellation: row.defIsAppellation,
        defaultPreMask: row.defPreMask,
        needPairCheck: row.needPairCheck
    )
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

    // 2) Patterns (ref 해석 클로저)
    let resolve: (String) -> String? = { ref in
        if let k = refIndex.refToKey[ref] { return k }
        if ref.lowercased().hasPrefix("ref:") {
            // ref:Sheet:Target → 미해결 (오타 가능) → nil 반환
            return nil
        }
        return ref // 이미 key일 수 있음
    }
    let allPatterns = patterns.map { parsePatternRow($0, resolve: resolve) }

    // 4) 드라이런 경고(간단): 미해결 ref 수집
    var unresolvedRefs: [String] = []
    func collectUnresolved(from dsl: SelectorParseResult) {
        for tok in dsl.includeRefs + dsl.excludeRefs where tok.lowercased().hasPrefix("ref:") {
            if resolve(tok) == nil { unresolvedRefs.append(tok) }
        }
    }
    // 재파싱으로 수집
    for p in patterns {
        collectUnresolved(from: parseSelectorDSL(p.left))
        collectUnresolved(from: parseSelectorDSL(p.right))
    }
    if !unresolvedRefs.isEmpty {
        print("[Import][Warn] Unresolved refs: \(Set(unresolvedRefs))")
    }

    let bundle = JSBundle(terms: allTerms, patterns: allPatterns)
    return bundle
}
