//
//  TermMasker.swift
//  MyTranslation
//

import Foundation

@inline(__always)
public func hangulFinalJongInfo(_ s: String) -> (hasBatchim: Bool, isRieul: Bool) {
    guard let last = s.unicodeScalars.last else { return (false, false) }
    let v = Int(last.value)
    guard (0xAC00 ... 0xD7A3).contains(v) else { return (false, false) }
    let idx = v - 0xAC00
    let jong = idx % 28
    if jong == 0 { return (false, false) }
    return (true, jong == 8) // 8 == ㄹ
}

// MARK: - Term-only Masker

public final class TermMasker {
    // PERSON 큐 언락을 위한 타입
    public typealias PersonQueues = [String: [String]]

    /// 토큰 좌우 공백 보정을 전역적으로 전환할 수 있는 테스트용 플래그
    public static var enableTokenSpacingAdjustment: Bool = false

    private var nextIndex: Int = 1
    
    // ===== configurable guards =====
    /// pid -> 단독 허용 성(예: ["1": ["红"]])
    public var soloFamilyAllow: [String: Set<String>] = [:]
    /// pid -> 단독 허용 이름(예: ["1": ["凯"]])
    public var soloGivenAllow: [String: Set<String>] = [:]
    /// pid -> 단독 허용 별칭(예: ["2": ["伽"]])
    public var soloAliasAllow: [String: Set<String>] = [:]
    /// 전역 네거티브 빅람/트라이그램(추가)
    public var extraNegativeBigrams: Set<String> = []
    /// 문맥 인식 윈도우(최근 동일 인물 언급 인식, 문자 단위)
    public var contextWindow: Int = 40

    public init(
        soloFamilyAllow: [String: Set<String>] = [:],
        soloGivenAllow: [String: Set<String>] = ["1": ["凯"]],
        soloAliasAllow: [String: Set<String>] = ["2": ["伽"]],
        extraNegativeBigrams: Set<String> = [],
        contextWindow: Int = 40
    ) {
        self.soloFamilyAllow = soloFamilyAllow
        self.soloGivenAllow = soloGivenAllow
        self.soloAliasAllow = soloAliasAllow
        self.extraNegativeBigrams = extraNegativeBigrams
        self.contextWindow = contextWindow
    }

    /// 용어 사전(glossary: 원문→한국어)을 이용해 텍스트 내 용어를 토큰으로 잠그고 LockInfo를 생성한다.
    /// - 반환: masked(토큰 포함), tags(기존 라우터용), locks(조사 교정/언락용)
    public func maskWithLocks(
        segment: Segment,
        glossary entries: [GlossaryEntry],
        maskPerson: Bool
    ) -> MaskedPack {
        let text = segment.originalText
        guard !text.isEmpty, !entries.isEmpty else {
            return .init(seg: segment, masked: text, tags: [], locks: [:])
        }

        let sorted = entries.sorted { $0.source.count > $1.source.count }

        var out = text
        var tags: [String] = []
        var locks: [String: LockInfo] = [:]
        var localNextIndex = self.nextIndex

        // === 단일 한자 검증용 사전 구축
        var fullSourcesByPid: [String: Set<String>] = [:]
        var singleSourcesByPid: [String: Set<String>] = [:]
        for e in sorted where e.category == .person {
            guard let pid = e.personId, !pid.isEmpty else { continue }
            let sources = e.sourceForms.isEmpty ? [e.source] : e.sourceForms
            for src in sources {
                if src.count >= 2 { fullSourcesByPid[pid, default: []].insert(src) }
                else { singleSourcesByPid[pid, default: []].insert(src) }
            }
        }
        var lastMentionIndexByPid: [String: Int] = [:]

        for e in sorted {
            guard !e.source.isEmpty, out.contains(e.source) else { continue }
            // 일단 상세 인물명만 엔진에 따라 마스킹하지 않음
            if !maskPerson && e.category == .person && e.personId != nil { continue }

            // === (1) 유니크 토큰 생성 ===
            let tokenPrefix = "E"
            let token = Self.makeToken(prefix: tokenPrefix, index: localNextIndex)
            localNextIndex += 1

            let pattern = NSRegularExpression.escapedPattern(for: e.source)
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = rx.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }

            var newOut = String()
            newOut.reserveCapacity(out.utf16.count)
            var last = 0

            for m in matches {
                if last < m.range.location {
                    newOut += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                }

                var shouldMask = true
                if e.category == .person,
                   let pid = e.personId,
                   !pid.isEmpty,
                   e.source.count == 1
                {
                    // ---- 단일 한자 인물: 네거티브 → 화이트리스트 → 최근언급 → 짝검증 ----
                    if isNegativeBigram(ns: ns, matchRange: m.range, center: e.source) {
                        shouldMask = false
                    } else if (soloFamilyAllow[pid]?.contains(e.source) == true)
                        || (soloGivenAllow[pid]?.contains(e.source) == true)
                        || (soloAliasAllow[pid]?.contains(e.source) == true)
                    {
                        shouldMask = true
                    } else if let last = lastMentionIndexByPid[pid],
                              (m.range.location - last) <= contextWindow
                    {
                        shouldMask = true
                    } else {
                        let prev1 = Self.substringSafe(ns, m.range.location - 1, 1)
                        let prev2 = Self.substringSafe(ns, m.range.location - 2, 2)
                        let next1 = Self.substringSafe(ns, m.range.location + m.range.length, 1)
                        let next2 = Self.substringSafe(ns, m.range.location + m.range.length, 2)
                        let fulls = fullSourcesByPid[pid] ?? []
                        shouldMask = fulls.contains(prev1 + e.source)
                            || fulls.contains(prev2)
                            || fulls.contains(e.source + next1)
                            || fulls.contains(e.source + next2)
                    }
                }

                if shouldMask {
                    newOut += token
                    if e.category == .person, let pid = e.personId {
                        lastMentionIndexByPid[pid] = m.range.location
                    }
                } else {
                    newOut += ns.substring(with: m.range)
                }

                last = m.range.location + m.range.length
            }

            if last < ns.length {
                newOut += ns.substring(with: NSRange(location: last, length: ns.length - last))
            }
            out = newOut

            // (2) 사람일 때만 NBSP 힌트 주입
            if e.category == .person {
                out = surroundTokenWithNBSP(out, token: token)
            }

            // (3) 라우터 태그 유지
            tags.append(e.target)

            // (4) LockInfo 등록
            let (b, r) = hangulFinalJongInfo(e.target)
            locks[token] = LockInfo(
                placeholder: token,
                target: e.target,
                endsWithBatchim: b,
                endsWithRieul: r,
                category: e.category
            )
        }

        // (5) 토큰 좌우 문장부호 인접 시 공백 삽입
        out = insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(out)

        self.nextIndex = localNextIndex
        return .init(seg: segment, masked: out, tags: tags, locks: locks)
    }

    // (C) 언마스킹: 유니크 토큰으로 직접 복원
    func unlockTermsSafely(_ text: String, locks: [String: LockInfo]) -> String {
        guard let rx = try? NSRegularExpression(pattern: tokenRegex, options: []) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))

        var out = String()
        out.reserveCapacity(text.utf16.count)
        var last = 0

        for m in matches {
            let full = m.range(at: 0)
            if last < full.location {
                out += ns.substring(with: NSRange(location: last, length: full.location - last))
            }
            let whole = ns.substring(with: full)
            out += locks[whole]?.target ?? whole
            last = full.location + full.length
//            print("[UNLOCK] matched token='\(whole)' -> target='\((locks[whole]?.target ?? whole).replacingOccurrences(of: "\u{00A0}", with: "⍽"))'")
        }

        if last < ns.length {
            out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }
        
        return out
    }

    // --------------------------------------
    private static let tokenRegexPattern: String = #"__(?:[^_]|_(?!_))+__"#

    private var tokenRegex: String { Self.tokenRegexPattern }

    private static func makeToken(prefix: String, index: Int) -> String {
        return "__\(prefix)#\(index)__"
    }
    
    // - 단일 한자 인물의 오검출 방지 보조들
    private static let baseNegativeBigrams: Set<String> = [
        "脸红", "发红", "泛红", "通红", "变红", "红色", "红了", "红的", "绯红",
    ]
    private var mergedNegativeBigrams: Set<String> { Self.baseNegativeBigrams.union(extraNegativeBigrams) }
    private func isNegativeBigram(ns: NSString, matchRange r: NSRange, center: String) -> Bool {
        let prev1 = Self.substringSafe(ns, r.location - 1, 1)
        let next1 = Self.substringSafe(ns, r.location + r.length, 1)
        let prev2 = Self.substringSafe(ns, r.location - 2, 2)
        let next2 = Self.substringSafe(ns, r.location + r.length, 2)
        let neg = mergedNegativeBigrams
        if neg.contains(prev1 + center) { return true }
        if neg.contains(center + next1) { return true }
        if neg.contains(prev2) { return true }
        if neg.contains(next2) { return true }
        return false
    }

    private static func substringSafe(_ ns: NSString, _ loc: Int, _ len: Int) -> String {
        guard len > 0 else { return "" }
        if loc < 0 { return "" }
        if loc >= ns.length { return "" }
        let end = min(ns.length, loc + len)
        if end <= loc { return "" }
        return ns.substring(with: NSRange(location: loc, length: end - loc))
    }
    
    /// 전체 텍스트를 단락(또는 세그먼트) 단위로 나눠,
    /// "토큰을 모두 제거하면 문장부호/공백만 남는" 단락에서만
    /// 토큰 양옆(문장부호 인접)에 공백을 삽입한다.
    func insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(_ text: String) -> String {
        guard Self.enableTokenSpacingAdjustment else { return text }

        let paras = text.components(separatedBy: "\n")
        var outParas: [String] = []
        outParas.reserveCapacity(paras.count)

        let tokenPattern = Self.tokenRegexPattern
        let stripRx = try! NSRegularExpression(pattern: tokenPattern)
        let leftPattern = #"(?<=[\p{P}\p{S}])(\#(tokenPattern))"#
        let rightPattern = #"(\#(tokenPattern))(?=[\p{P}\p{S}])"#
        let leftRx = try! NSRegularExpression(pattern: leftPattern)
        let rightRx = try! NSRegularExpression(pattern: rightPattern)

        for p in paras {
            // 1) 단락에서 토큰을 모두 제거한 결과가 문장부호/공백 뿐인지 검사
            let rest = stripRx.stringByReplacingMatches(in: p, range: NSRange(p.startIndex..., in: p), withTemplate: "")
            guard rest.isPunctOrSpaceOnly else {
                outParas.append(p) // 조건 불충족 → 변경 없음
                continue
            }

            // 2) 조건 통과: 토큰 좌/우가 문장부호인 곳에 공백 보장 (앞뒤 모두)
            var q = p
            q = leftRx.stringByReplacingMatches(in: q, range: NSRange(q.startIndex..., in: q), withTemplate: " $1")
            q = rightRx.stringByReplacingMatches(in: q, range: NSRange(q.startIndex..., in: q), withTemplate: "$0 ")

            outParas.append(q)
        }

        return outParas.joined(separator: "\n")
    }
    
    // 공백 클래스(엔진별 NBSP/좁은 NBSP/제로폭/전각 공백까지 포함)
    private let wsClass = #"(?:\s|\u00A0|\u202F|\u2009|\u200A|\u200B|\u205F|\u3000)+"#

    /// 세그먼트가 `target`을 제외하면 '문장부호/기호/공백'만 남을 때에만,
    /// 토큰/이름 좌우의 불필요한 공백을 접는다.
    func collapseSpaces_PunctOrEdge_whenIsolatedSegment(_ s: String, target: String) -> String {
        guard !target.isEmpty else { return s }

        // 0) 세그먼트 가드: 해당 토큰/이름이 존재하고, 그것을 제거하면 나머지가 모두 부호/공백뿐이어야 함
        //    (호출부에서 "토큰 1개"를 보장하지만, 안전을 위해 내부에서도 최소한 존재 여부는 확인)
        guard s.contains(target) else { return s }
        let rest = s.replacingOccurrences(of: target, with: "")
        guard rest.isPunctOrSpaceOnly_loose else { return s }

        // 1) 이름(또는 토큰)만 캡처하고, 문장부호/공백은 lookaround로만 검사
        let name = NSRegularExpression.escapedPattern(for: target)
        var out = s

        // 양쪽 모두: [punct] + WS + name + WS + [punct] → name
        out = try! NSRegularExpression(
            pattern: #"(?<=[\p{P}\p{S}])\#(wsClass)(?<tok>\#(name))\#(wsClass)(?=[\p{P}\p{S}])"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        // 왼쪽만: [punct] + WS + name → name
        out = try! NSRegularExpression(
            pattern: #"(?<=[\p{P}\p{S}])\#(wsClass)(?<tok>\#(name))"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        // 오른쪽만: name + WS + [punct] → name
        out = try! NSRegularExpression(
            pattern: #"(?<tok>\#(name))\#(wsClass)(?=[\p{P}\p{S}])"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        // 문자열 경계 보정: ^ WS name → name, name WS $ → name
        out = try! NSRegularExpression(
            pattern: #"^\#(wsClass)(?<tok>\#(name))"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)
        out = try! NSRegularExpression(
            pattern: #"(?<tok>\#(name))\#(wsClass)$"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        return out
    }

    /// 개별 token에 대해 '필요할 때만' NBSP를 주입 (치환 후 호출)
    func surroundTokenWithNBSP(_ text: String, token: String) -> String {
//        guard Self.enableTokenSpacingAdjustment else { return text }

        let sentenceBoundaryCharacters: Set<Character> = Set("。！？；：（、“‘〈《【—\n\r!?;:()[]{}\"'".map { $0 })

        func isBoundary(_ c: Character?) -> Bool {
            guard let c = c else { return true }
            if c == "\u{00A0}" || c.isWhitespace { return true }
            if "。,!?;:()[]{}\"'、・·-—–“”‘’〈〉《》【】『』「」".contains(c) { return true }
            return false
        }

        func isLetterLike(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            for u in c.unicodeScalars {
                if CharacterSet.alphanumerics.contains(u) { return true }
                switch u.value {
                case 0x4E00 ... 0x9FFF,
                     0xAC00 ... 0xD7A3,
                     0x3040 ... 0x309F,
                     0x30A0 ... 0x30FF:
                    return true
                default: break
                }
            }
            return false
        }

        func isCJKCharacter(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            for u in c.unicodeScalars {
                switch u.value {
                case 0x3400 ... 0x4DBF,
                     0x4E00 ... 0x9FFF,
                     0xF900 ... 0xFAFF,
                     0x20000 ... 0x2A6DF,
                     0x2A700 ... 0x2B73F,
                     0x2B740 ... 0x2B81F,
                     0x2B820 ... 0x2CEAF:
                    return true
                default: break
                }
            }
            return false
        }

        func isLatinOrDigit(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            for u in c.unicodeScalars {
                switch u.value {
                case 0x30 ... 0x39,
                     0x41 ... 0x5A,
                     0x61 ... 0x7A:
                    return true
                default: break
                }
            }
            return false
        }

        func previousNonSpacingCharacter(in text: String, before index: String.Index) -> Character? {
            var idx = index
            while idx > text.startIndex {
                idx = text.index(before: idx)
                let ch = text[idx]
                if ch == "\u{00A0}" || ch.isWhitespace { continue }
                return ch
            }
            return nil
        }

        func nextNonSpacingCharacter(in text: String, after index: String.Index) -> Character? {
            var idx = index
            while idx < text.endIndex {
                let ch = text[idx]
                if ch == "\u{00A0}" || ch.isWhitespace {
                    idx = text.index(after: idx)
                    continue
                }
                return ch
            }
            return nil
        }

        var out = text
        var searchStart = out.startIndex

        while let r = out.range(of: token, range: searchStart ..< out.endIndex) {
            let beforeIdx = (r.lowerBound == out.startIndex) ? nil : out.index(before: r.lowerBound)
            let afterIdx = (r.upperBound == out.endIndex) ? nil : r.upperBound

            let beforeCh = beforeIdx.map { out[$0] }
            let afterCh = afterIdx.map { out[$0] }

            let prevNonSpacing = previousNonSpacingCharacter(in: out, before: r.lowerBound)
            let nextNonSpacing = nextNonSpacingCharacter(in: out, after: r.upperBound)

            var needLeftNBSP = false
            var needRightNBSP = false

            if let prev = beforeCh, !isBoundary(prev), isLetterLike(prev) {
                needLeftNBSP = true
            }

            let forbidRightNBSP: Bool
            if let next = nextNonSpacing, isCJKCharacter(next) {
                if let prev = prevNonSpacing {
                    forbidRightNBSP = sentenceBoundaryCharacters.contains(prev)
                } else {
                    forbidRightNBSP = true
                }
            } else {
                forbidRightNBSP = false
            }

            if !forbidRightNBSP, let next = afterCh, !isBoundary(next), isLatinOrDigit(next) {
                needRightNBSP = true
            }

            if needLeftNBSP || needRightNBSP {
                var replacement = token
                if needLeftNBSP {
                    replacement = "\u{00A0}" + replacement
                }
                if needRightNBSP {
                    replacement += "\u{00A0}"
                }

                let lowerDistance = out.distance(from: out.startIndex, to: r.lowerBound)
                out.replaceSubrange(r, with: replacement)
                let advancedDistance = lowerDistance + replacement.count
                searchStart = out.index(out.startIndex, offsetBy: advancedDistance)
            } else {
                searchStart = r.upperBound
            }
        }
        return out
    }
    
    struct NameGlossary {
        let target: String
        let variants: [String]
    }

    /// 원문에 등장한 인물 용어만 선별하여 정규화용 이름 정보를 생성한다.
    /// - Parameters:
    ///   - original: 용어 검사를 수행할 원문 텍스트
    ///   - entries: 용어집 엔트리 목록
    /// - Returns: 원문에 등장한 인물 용어의 target/variants 정보 배열
    func makeNameGlossaries(forOriginalText original: String, entries: [GlossaryEntry]) -> [NameGlossary] {
        guard !original.isEmpty else { return [] }

        let normalizedOriginal = original.precomposedStringWithCompatibilityMapping.lowercased()

        var variantsByTarget: [String: [String]] = [:]
        var seenVariantKeysByTarget: [String: Set<String>] = [:]

        for entry in entries where entry.category == .person {
            guard !entry.target.isEmpty else { continue }
            let sourceForms = entry.sourceForms.isEmpty ? [entry.source] : entry.sourceForms
            let normalizedSources = sourceForms.map { $0.precomposedStringWithCompatibilityMapping.lowercased() }
            guard normalizedSources.contains(where: { !$0.isEmpty && normalizedOriginal.contains($0) }) else { continue }

            if !entry.variants.isEmpty {
                var bucket = variantsByTarget[entry.target, default: []]
                var seen = seenVariantKeysByTarget[entry.target, default: []]
                for variant in entry.variants where !variant.isEmpty {
                    let key = normKey(variant)
                    if seen.insert(key).inserted {
                        bucket.append(variant)
                    }
                }
                variantsByTarget[entry.target] = bucket
                seenVariantKeysByTarget[entry.target] = seen
            } else if variantsByTarget[entry.target] == nil {
                variantsByTarget[entry.target] = []
            }
        }

        guard variantsByTarget.isEmpty == false else { return [] }

        return variantsByTarget.map { target, variants in
            NameGlossary(target: target, variants: variants)
        }
    }
    
    struct JosaPair {
        let noBatchim: String
        let withBatchim: String
        let rieulException: Bool     // (으)로 계열 특례
        let prefersWithBatchimWhenAuxAttached: Bool
    }

    // 최소 세트 (필요 시 확장)
    let josaPairs: [JosaPair] = [
        .init(noBatchim: "는",   withBatchim: "은",   rieulException: false, prefersWithBatchimWhenAuxAttached: true),
        .init(noBatchim: "가",   withBatchim: "이",   rieulException: false, prefersWithBatchimWhenAuxAttached: true),
        .init(noBatchim: "를",   withBatchim: "을",   rieulException: false, prefersWithBatchimWhenAuxAttached: true),
        .init(noBatchim: "와",   withBatchim: "과",   rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "랑",   withBatchim: "이랑", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "로",   withBatchim: "으로", rieulException: true,  prefersWithBatchimWhenAuxAttached: true),
        .init(noBatchim: "라",   withBatchim: "이라", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "라고", withBatchim: "이라고", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "라서", withBatchim: "이라서", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "라면", withBatchim: "이라면", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "라니", withBatchim: "이라니", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "라도", withBatchim: "이라도", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
        .init(noBatchim: "의",   withBatchim: "의",   rieulException: false, prefersWithBatchimWhenAuxAttached: false),
    ]

    private let caseSingleParticles: Set<String> = [
        "에", "에서", "에게", "에게서", "와", "과", "랑", "하고",
        "께", "께서", "보다", "처럼", "같이", "로서", "으로서",
        "로써", "으로써", "의"
    ]

    private let auxiliaryParticles: Set<String> = [
        "만", "도", "까지", "부터", "조차", "마저", "밖에", "뿐",
        "나", "이나", "나마", "이나마"
    ]

    private lazy var pairFormsByString: [String: (index: Int, isWithBatchim: Bool)] = {
        var dict: [String: (Int, Bool)] = [:]
        for (idx, pair) in josaPairs.enumerated() {
            dict[pair.noBatchim] = (idx, false)
            dict[pair.withBatchim] = (idx, true)
        }
        return dict
    }()

    private lazy var particleTokenAlternation: String = {
        var all = Set<String>()
        for pair in josaPairs {
            all.insert(pair.noBatchim)
            all.insert(pair.withBatchim)
        }
        all.formUnion(caseSingleParticles)
        all.formUnion(auxiliaryParticles)
        return all.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }()

    private lazy var particleTokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: particleTokenAlternation, options: [])
    }()

    private lazy var particleWhitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?:\\s|\\u00A0)+", options: [])
    }()

    private let cjkOrWord = "[\\p{Han}\\p{Hiragana}\\p{Katakana}ァ-ン一-龥ぁ-んA-Za-z0-9_]"
    
    /// 주어진 조사 문자열에서 보조사·격조사 조합을 분해해 대상 명사의 받침 정보를 반영한 최종 조사 표기를 결정한다.
    /// - Parameters:
    ///   - candidate: 원문에서 추출한 조사 문자열(공백 포함 가능)
    ///   - baseHasBatchim: 기준 명사의 종성이 존재하는지 여부
    ///   - baseIsRieul: 기준 명사가 ㄹ 받침인지 여부
    /// - Returns: 종성 규칙과 보조사 결합 규칙을 반영해 선택된 조사 문자열
    func chooseJosa(for candidate: String?, baseHasBatchim: Bool, baseIsRieul: Bool) -> String {
        guard let cand = candidate, !cand.isEmpty else { return "" }

        let ns = cand as NSString
        var segments: [String] = []
        var isWhitespace: [Bool] = []
        var location = 0

        while location < ns.length {
            let remaining = NSRange(location: location, length: ns.length - location)
            if let wsMatch = particleWhitespaceRegex.firstMatch(in: cand, options: [.anchored], range: remaining) {
                segments.append(ns.substring(with: wsMatch.range))
                isWhitespace.append(true)
                location += wsMatch.range.length
                continue
            }

            if let tokenMatch = particleTokenRegex.firstMatch(in: cand, options: [.anchored], range: remaining) {
                segments.append(ns.substring(with: tokenMatch.range))
                isWhitespace.append(false)
                location += tokenMatch.range.length
                continue
            }

            let range = ns.rangeOfComposedCharacterSequence(at: location)
            segments.append(ns.substring(with: range))
            isWhitespace.append(false)
            location += range.length
        }

        guard !segments.isEmpty else { return "" }

        struct TokenInfo {
            enum Kind {
                case pair(index: Int)
                case single
                case auxiliary
                case unknown
            }

            let segmentIndex: Int
            let kind: Kind
        }

        var tokens: [TokenInfo] = []
        for (idx, segment) in segments.enumerated() where !isWhitespace[idx] {
            if let form = pairFormsByString[segment] {
                tokens.append(.init(segmentIndex: idx, kind: .pair(index: form.index)))
            } else if caseSingleParticles.contains(segment) {
                tokens.append(.init(segmentIndex: idx, kind: .single))
            } else if auxiliaryParticles.contains(segment) {
                tokens.append(.init(segmentIndex: idx, kind: .auxiliary))
            } else {
                tokens.append(.init(segmentIndex: idx, kind: .unknown))
            }
        }

        guard !tokens.isEmpty else { return cand }

        var resultSegments = segments
        var changed = false
        
        func noWhitespaceBetween(_ segA: Int, _ segB: Int) -> Bool {
            let lo = min(segA, segB), hi = max(segA, segB)
            // segA와 segB 사이에 '공백 세그먼트'가 하나라도 있으면 false
            if lo+1 <= hi-1 {
                for i in (lo+1)...(hi-1) {
                    if isWhitespace.indices.contains(i), isWhitespace[i] { return false }
                }
            }
            return true
        }

        func hasAuxAdjacent(_ tokenIndex: Int) -> Bool {
            // 왼쪽 보조사
            if tokenIndex > 0 {
                let left = tokens[tokenIndex - 1]
                if case .auxiliary = left.kind,
                   noWhitespaceBetween(left.segmentIndex, tokens[tokenIndex].segmentIndex) {
                    return true
                }
            }
            // 오른쪽 보조사
            if tokenIndex + 1 < tokens.count {
                let right = tokens[tokenIndex + 1]
                if case .auxiliary = right.kind,
                   noWhitespaceBetween(tokens[tokenIndex].segmentIndex, right.segmentIndex) {
                    return true
                }
            }
            return false
        }

        for (idx, token) in tokens.enumerated() {
            guard case let .pair(pairIndex) = token.kind else { continue }
            let pair = josaPairs[pairIndex]

            let useWithBatchim: Bool
            if hasAuxAdjacent(idx) && pair.prefersWithBatchimWhenAuxAttached {
                useWithBatchim = true
            } else if pair.rieulException && baseIsRieul {
                useWithBatchim = false
            } else {
                useWithBatchim = baseHasBatchim
            }

            let replacement = useWithBatchim ? pair.withBatchim : pair.noBatchim
            if resultSegments[token.segmentIndex] != replacement {
                resultSegments[token.segmentIndex] = replacement
                changed = true
            }
        }
//        print("[CHOOSE] cand='\(String(describing: cand))' -> chosen='\(resultSegments.joined())' (hasBatchim=\(baseHasBatchim), rieul=\(baseIsRieul))")
        if !changed { return cand }
        return resultSegments.joined()
    }
    
    @inline(__always)
    private func extractTokenIDs(from locks: [String: LockInfo]) -> Set<String> {
        // "__E#123__" 또는 "E#123" 둘 다 대비
        let rx = try! NSRegularExpression(pattern: "(?:__)?E#(\\d+)(?:__)?", options: [.caseInsensitive])
        var ids = Set<String>()
        for key in locks.keys {
            let ns = key as NSString
            let ms = rx.matches(in: key, options: [], range: NSRange(location: 0, length: ns.length))
            for m in ms {
                ids.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return ids
    }
    
    func normalizeDamagedETokens(_ text: String, locks: [String: LockInfo]) -> String {
        // 이번 배치에서 실제 존재하는 토큰 id 화이트리스트
        let validIDs = extractTokenIDs(from: locks)

        // 공백/NBSP/제로폭/BOM
        let ws = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*"
        // 숫자(전각 포함)
        let d  = "([0-9０-９]+)"

        // A) 분할/띄어쓰기/전각 섞임: "__E#  31 __", "__ E #３１  __" 등
        let rxA = try! NSRegularExpression(pattern: "(?i)_{2}" + ws + "E" + ws + "#" + ws + d + ws + "_{2}")
        // B0) 앞에 언더스코어가 전혀 없는 케이스: "E#56__" → "__E#56__"
        let rxB0 = try! NSRegularExpression(pattern: "(?i)(?<!_)E#" + d + "_?__?(?!_)")
        // B) 언더스코어 과다/부족 케이스: "___E#56__", "__E#56_", "_E#56__" 등
        let rxB  = try! NSRegularExpression(pattern: "(?i)(?<!_)_?__?E#" + d + "_?__?(?!_)")

        @inline(__always)
        func halfwidth(_ s: String) -> String {
            s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        }

        var out = text

        // --- A: 분할/띄어쓰기/전각 섞임 회수 ---
        do {
            let ns = out as NSString
            let ms = rxA.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !ms.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in ms.reversed() {
                    let idRaw = ns.substring(with: m.range(at: 1))
                    let id = halfwidth(idRaw)
                    // 실제 존재하는 id일 때만 표준화
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        // --- B0 ---
        do {
            let ns = out as NSString
            let ms = rxB0.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !ms.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in ms.reversed() {
                    let idRaw = ns.substring(with: m.range(at: 1))
                    let id = idRaw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? idRaw
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        // --- B ---
        do {
            let ns = out as NSString
            let ms = rxB.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !ms.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in ms.reversed() {
                    let idRaw = ns.substring(with: m.range(at: 1))
                    let id = idRaw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? idRaw
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        // --- C: 접두 소실 복구 (화이트리스트 필수) ---

        // C1) "#31__" → "__E#31__"
        //  - 바로 앞 문자가 'E'가 아니어야 정상 토큰 내부를 건드리지 않음
        let rxC1 = try! NSRegularExpression(pattern: "(?<![EＥ])#([0-9]{1,8})__(?!_)", options: [])

        // C2) "31__"  → "__E#31__"
        //  - 숫자 앞이 해시/영숫자/언더바가 아니어야 함(경계 보장)
        let rxC2 = try! NSRegularExpression(pattern: "(?<![#A-Za-z0-9_])([0-9]{1,8})__(?!_)", options: [])

        do {
            // C1 먼저
            var ns = out as NSString
            let m1 = rxC1.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !m1.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in m1.reversed() {
                    let id = ns.substring(with: m.range(at: 1))
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }

            // C2 다음
            ns = out as NSString
            let m2 = rxC2.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !m2.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in m2.reversed() {
                    let id = ns.substring(with: m.range(at: 1))
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        return out
    }
    
    private func normKey(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
    }
    
    enum EntityMode { case tokensOnly, namesOnly, both }
    
    /// 번역 결과에 남은 토큰과 인명 변형을 canonical 표기와 맞는 조사로 치환한다.
    /// - Parameters:
    ///   - text: 정규화를 수행할 번역 텍스트
    ///   - locksByToken: 토큰 문자열 → LockInfo (토큰 복원 및 조사 재계산 시 사용)
    ///   - names: NameGlossary 배열 (언마스킹 후 이름 표기 통일용)
    ///   - mode: 처리 모드(토큰만/이름만/둘다)
    func normalizeEntitiesAndParticles(
        in text: String,
        locksByToken: [String: LockInfo],
        names: [NameGlossary],
        mode: EntityMode = .both
    ) -> String {
        // --- [0] 준비: 소스 정규화 & 엔터티/조사 alternation 구성 ---
        let textNFC = text.precomposedStringWithCompatibilityMapping
        func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

        // 엔터티 후보 (토큰 + 이름 variants/canonical), 모드에 따라 선택
        let tokenAlts: [String] = (mode == .namesOnly) ? [] :
            locksByToken.keys.map(esc)

        let nameAlts: [String] = (mode == .tokensOnly) ? [] :
            names.flatMap { [$0.target] + $0.variants }.map(esc)

        let entityAlts = (tokenAlts + nameAlts)
            .sorted { $0.count > $1.count }          // ★ 긴 것 우선
            .joined(separator: "|")

        // 엔터티가 없으면 조기 종료
        if entityAlts.isEmpty { return text }

        // 유니코드 '단어' 경계 집합: 모든 Letter/Number + '_'. (이전엔 Hangul 누락)
        let cjkBody = "\\p{L}\\p{N}_"
        let pre = "(?<![" + cjkBody + "])"
        let suf = "(?![" + cjkBody + "])"
        
        let wsZ = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*" // ← ZWSP/ZWJ/ZWNJ/BOM 추가
        let softPunct = "[\"'“”’»«》〈〉〉》」』】）\\)\\]\\}]"
        let gap = "(?:" + wsZ + "(?:" + softPunct + ")?" + wsZ + ")"  // 엔터티↔조사 사이 ‘얇은 갭’

        let particleTokenAlt = "(?:" + particleTokenAlternation + ")"

        // 조사 시퀀스에는 ‘공백 금지’(필요하면 NBSP만 0~1 허용)
        let josaJoin = ""                  // 공백 완전 금지
        // let josaJoin = "(?:\\u00A0)?"   // NBSP만 0~1 허용으로 하고 싶다면 이 줄 사용

        let josaSequence = particleTokenAlt + "(?:" + josaJoin + particleTokenAlt + ")*"

        // --- [1] 1패스: [조사 O] 패턴 (조사 ‘뒤’에서 경계 검사) ---
        let patWithJosa =
        pre +
        "(" + entityAlts + ")" +                  // grp1 entity
        "(" + gap + ")" +                          // grp2 ws between
        "(" + josaSequence + ")" +                // grp3 josa sequence
        suf                  // grp5 suffix
        let rxWithJosa = try! NSRegularExpression(
            pattern: patWithJosa,
            options: [.caseInsensitive]
        )

        var out = textNFC
        var matches1: [(whole:NSRange, g1:NSRange, g2:NSRange, g3:NSRange)] = []
        let ns1 = out as NSString
        rxWithJosa.enumerateMatches(in: out, options: [], range: NSRange(location: 0, length: ns1.length)) { m, _, _ in
            guard let m = m else { return }
            matches1.append((m.range(at: 0), m.range(at: 1), m.range(at: 2), m.range(at: 3)))
        }

        for m in matches1.reversed() {
            let ns = out as NSString
            let entity  = ns.substring(with: m.g1)
            let spacing = ns.substring(with: m.g2)
            let josa    = ns.substring(with: m.g3)

            let (canon, chosen) = resolveEntityAndJosa(
                nameText: entity, josaCandidate: josa,
                locksByToken: locksByToken, names: names, mode: mode
            )
            out = ns.replacingCharacters(in: m.whole, with: canon + spacing + chosen)
        }

        // --- [2] 2패스: [조사 X] 패턴 (엔터티 ‘바로 뒤’에서 경계 검사) ---
        let patBare =
        pre +
        "(" + entityAlts + ")" +                  // grp1 entity
        "(?=" +                       // lookahead으로 조사 존재/경계만 확인
            "$|[^" + cjkBody + "]|(?:" + gap + ")" + particleTokenAlt +
        ")"
        let rxBare = try! NSRegularExpression(
            pattern: patBare,
            options: [.caseInsensitive]
        )

        var matches2: [(whole:NSRange, g1:NSRange)] = []
        let ns2 = out as NSString
        rxBare.enumerateMatches(in: out, options: [], range: NSRange(location: 0, length: ns2.length)) { m, _, _ in
            guard let m = m else { return }
            matches2.append((m.range(at: 0), m.range(at: 1)))
        }

        for m in matches2.reversed() {
            let ns = out as NSString
            let name = ns.substring(with: m.g1)

            let (canon, chosen) = resolveEntityAndJosa(
                nameText: name, josaCandidate: nil,
                locksByToken: locksByToken, names: names, mode: mode
            )

            // prefix 캡처가 없으므로, 바로 엔티티 범위 전체를 교체
            out = ns.replacingCharacters(in: m.whole, with: canon + chosen)
        }

        return out
    }
    
    private func resolveEntityAndJosa(
        nameText: String,
        josaCandidate: String?,
        locksByToken: [String: LockInfo],
        names: [NameGlossary],
        mode: EntityMode
    ) -> (canon: String, josa: String) {
//        print("[RESOLVE] nameText='\(nameText)' josaCand='\(String(describing: josaCandidate))' mode=\(mode)")
        if mode != .namesOnly, let info = locksByToken[nameText] {
            // 토큰: 표기는 그대로, 조사만 LockInfo 기준 재계산
//            print("[RESOLVE] token lock target='\(info.target.replacingOccurrences(of: "\u{00A0}", with: "⍽"))' endsBatchim=\(info.endsWithBatchim) rieul=\(info.endsWithRieul)")
            let j = chooseJosa(for: josaCandidate, baseHasBatchim: info.endsWithBatchim, baseIsRieul: info.endsWithRieul)
            return (nameText, j)
        } else {
            // 이름: canonical 통일 + canonical 받침 기준으로 조사 재계산
            let canon = canonicalFor(nameText, entries: names)
            let (has, rieul) = hangulFinalJongInfo(canon)
//            print("[RESOLVE] canon='\(canon)' hasBatchim=\(has) rieul=\(rieul)")
            let j = chooseJosa(for: josaCandidate, baseHasBatchim: has, baseIsRieul: rieul)
            return (canon, j)
        }
    }

    // 이름 매핑
    private func canonicalFor(_ matched: String, entries: [NameGlossary]) -> String {
        let key = normKey(matched)
        for e in entries {
            if normKey(e.target) == key { return e.target }
            for v in e.variants { if normKey(v) == key { return e.target } }
        }
        return matched
    }
}

private extension String {
    var isPunctOrSpaceOnly: Bool {
        let set = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return unicodeScalars.allSatisfy { set.contains($0) }
    }
    
    var isPunctOrSpaceOnly_loose: Bool {
        // 공백 계열: 일반 공백/개행 + NBSP + narrow NBSP + thin space + hair space + zero-width space + 전각 공백
        let spaces = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{00A0}\u{202F}\u{2009}\u{200A}\u{200B}\u{205F}\u{3000}"))
        let set = CharacterSet.punctuationCharacters.union(.symbols).union(spaces)
        return unicodeScalars.allSatisfy { set.contains($0) }
    }
}
