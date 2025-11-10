//
//  GlossaryJSONParser.swift
//  MyTranslation
//
//  Created by sailor.m on 11/8/25.
//

import Foundation

// MARK: - DSL Helpers
struct SelectorParseResult {
    var roles: [String]? = nil
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
            let roles = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            result.roles = roles.isEmpty ? nil : roles
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

func makeTermKey(sheetName: String, target: String, used: inout Set<String>) -> String {
    let sheetSlug = latinSlug(sheetName).prefix(5)
    var base = String(sheetSlug) + ":" + latinSlug(target)
    if base.isEmpty { base = String(sheetSlug) + ":TERM" }
    var key = base
    var i = 2
    while used.contains(key) {
        key = base + "-\(i)"; i += 1
    }
    used.insert(key)
    return key
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
    let sourcesOK: String
    let sourcesProhibit: String
    let target: String
    let variants: String
    let tags: String
    let components: String
    let isAppellation: Bool
    let preMask: Bool
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
    let variants: String // 세미콜론 분리(선택)
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

    // Components DSL: pattern[:role][-group1|group2][#sN][#tM]; ...
    let components: [JSComponent] = splitSemi(row.components).map { token in
        var pattern = ""
        var roles: [String]? = nil
        var groups: [String]? = nil
        var srcIdx: Int? = nil
        var tgtIdx: Int? = nil

        var core = token
        // extract #sN / #tM
        let parts = core.split(separator: "#").map(String.init)
        if let head = parts.first { core = head }
        for p in parts.dropFirst() {
            if p.hasPrefix("s"), let v = Int(p.dropFirst()) { srcIdx = v }
            else if p.hasPrefix("t"), let v = Int(p.dropFirst()) { tgtIdx = v }
        }
        // pattern[:role][-groups]
        let roleSplit = core.split(separator: ":", maxSplits: 1).map(String.init)
        let pg = roleSplit[0]
        pattern = pg.split(separator: "-", maxSplits: 1).map(String.init)[0]
        if pg.contains("-") {
            let g = String(pg.split(separator: "-", maxSplits: 1).map(String.init)[1])
            groups = g.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if roleSplit.count == 2 {
            let rolePart = roleSplit[1].split(separator: "-", maxSplits: 1).map(String.init)[0]
            roles = [rolePart]
        }
        return JSComponent(pattern: pattern, roles: roles, groups: groups, srcTplIdx: srcIdx, tgtTplIdx: tgtIdx)
    }

    var keySet = used
    let key = makeTermKey(sheetName: sheetName, target: row.target, used: &keySet)
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
        preMask: row.preMask
    )
}

func parsePatternRow(_ row: PatternRow, resolve: (String) -> String?) -> JSPattern {
    func splitPipes(_ s: String) -> [String] { s.split(separator: "||").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func splitSemi(_ s: String) -> [String] { s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    let leftDSL = parseSelectorDSL(row.left)
    let rightDSL = parseSelectorDSL(row.right)

    func toSelector(_ dsl: SelectorParseResult) -> JSTermSelector? {
        if dsl.roles == nil, dsl.tagsAll == nil, dsl.tagsAny == nil, dsl.includeRefs.isEmpty, dsl.excludeRefs.isEmpty { return nil }
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
            roles: dsl.roles,
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
        sourceJoiners: splitPipes(row.sourceJoiners),
        sourceTemplates: splitPipes(row.sourceTemplates),
        targetTemplates: splitPipes(row.targetTemplates),
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
    patterns: [PatternRow],
    markers: [AppellationRow]
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

    // 3) AppellationMarkers (시트 → 평탄화)
    var allMarkers: [JSAppellationMarker] = []
    for r in markers {
        let baseSources = [r.source] + r.variants.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pos = JSAppellationMarker.Position(rawValue: r.position) ?? .prefix
        for s in baseSources {
            allMarkers.append(JSAppellationMarker(source: s, target: r.target, position: pos, prohibitStandalone: r.prohibit))
        }
    }

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

    let bundle = JSBundle(terms: allTerms, patterns: allPatterns, markers: allMarkers)
//    let data = try JSONEncoder().encode(bundle)
    return bundle
}
