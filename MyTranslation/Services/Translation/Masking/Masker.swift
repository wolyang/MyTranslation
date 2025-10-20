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
            let token = "__ENT#\(localNextIndex)__"
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
        }

        if last < ns.length {
            out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }
        
        return out
    }

    // --------------------------------------
    private let tokenRegex = #"__(?:[^_]|_(?!_))+__"#
    
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
        let paras = text.components(separatedBy: "\n")
        var outParas: [String] = []
        outParas.reserveCapacity(paras.count)

        let stripRx = try! NSRegularExpression(pattern: tokenRegex)
        let leftRx = try! NSRegularExpression(pattern: #"(?<=[\p{P}\p{S}])(__(?:[^_]|_(?!_))+__)"#)
        let rightRx = try! NSRegularExpression(pattern: #"(__(?:[^_]|_(?!_))+__)(?=[\p{P}\p{S}])"#)

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
        // 경계 판단
        func isBoundary(_ c: Character?) -> Bool {
            guard let c = c else { return true }
            if c == "\u{00A0}" || c.isWhitespace { return true }
            // 흔한 구두점
            if ".,!?;:()[]{}\"'、。・·-—–".contains(c) { return true }
            return false
        }
        // 문자(단어 본체) 판단: 한글/한자/가나/라틴/숫자 등
        func isLetterLike(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            for u in c.unicodeScalars {
                if CharacterSet.alphanumerics.contains(u) { return true }
                switch u.value {
                case 0x4E00 ... 0x9FFF, // CJK
                     0xAC00 ... 0xD7A3, // Hangul
                     0x3040 ... 0x309F, // Hiragana
                     0x30A0 ... 0x30FF: // Katakana
                    return true
                default: break
                }
            }
            return false
        }

        var out = text
        var searchStart = out.startIndex

        while let r = out.range(of: token, range: searchStart ..< out.endIndex) {
            let beforeIdx = (r.lowerBound == out.startIndex) ? nil : out.index(before: r.lowerBound)
            let afterIdx = (r.upperBound == out.endIndex) ? nil : r.upperBound

            let beforeCh = beforeIdx.map { out[$0] }
            let afterCh = afterIdx.map { out[$0] }

            // 양옆이 '단어 문자'에 붙어 있으면 주입, 이미 경계면 스킵
            let needNBSP = (!isBoundary(beforeCh) && isLetterLike(beforeCh))
                || (!isBoundary(afterCh) && isLetterLike(afterCh))

            if needNBSP {
                // 중복 주입 방지: 이미 NBSP/공백이면 주입 안 함
                let leftOK = isBoundary(beforeCh)
                let rightOK = isBoundary(afterCh)

                var replacement = token
                if !leftOK { replacement = "\u{00A0}" + replacement }
                if !rightOK { replacement = replacement + "\u{00A0}" }

                out.replaceSubrange(r, with: replacement)

                // 치환 후 다음 탐색 시작점 보정
                let advancedBy = replacement.count
                searchStart = out.index(r.lowerBound, offsetBy: advancedBy)
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
    }

    // 최소 세트 (필요 시 확장)
    let josaPairs: [JosaPair] = [
        .init(noBatchim: "는",   withBatchim: "은",   rieulException: false),
        .init(noBatchim: "가",   withBatchim: "이",   rieulException: false),
        .init(noBatchim: "를",   withBatchim: "을",   rieulException: false),
        .init(noBatchim: "와",   withBatchim: "과",   rieulException: false),
        .init(noBatchim: "랑",   withBatchim: "이랑", rieulException: false),
        .init(noBatchim: "로",   withBatchim: "으로", rieulException: true),
        .init(noBatchim: "라",   withBatchim: "이라", rieulException: false),
        .init(noBatchim: "라고", withBatchim: "이라고", rieulException: false),
        .init(noBatchim: "라서", withBatchim: "이라서", rieulException: false),
        .init(noBatchim: "라면", withBatchim: "이라면", rieulException: false),
        .init(noBatchim: "라니", withBatchim: "이라니", rieulException: false),
        .init(noBatchim: "라도", withBatchim: "이라도", rieulException: false),
    ]
    
    private let cjkOrWord = "[\\p{Han}\\p{Hiragana}\\p{Katakana}ァ-ン一-龥ぁ-んA-Za-z0-9_]"
    private lazy var josaAlternation: String = {
        let all = Set(josaPairs.flatMap { [$0.noBatchim, $0.withBatchim] })
        return all.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
    }()
    
    private func chooseJosa(for candidate: String?, baseHasBatchim: Bool, baseIsRieul: Bool) -> String {
        guard let cand = candidate, !cand.isEmpty else { return "" }
        if let pair = josaPairs.first(where: { $0.noBatchim == cand || $0.withBatchim == cand }) {
            if pair.rieulException && baseIsRieul { return pair.noBatchim } // ㄹ받침 → '로'
            return baseHasBatchim ? pair.withBatchim : pair.noBatchim
        }
        return cand
    }
    
    private func normKey(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased()
    }
    
    enum EntityMode { case tokensOnly, namesOnly, both }
    
    /// 토큰/이름을 한 번에 처리.
    /// - Parameters:
    ///   - text: 번역 텍스트
    ///   - locksByToken: 토큰 문자열 → LockInfo (언마스킹 전에도 후에도 사용 가능)
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

        // 조사 alternation (긴 것 우선, 중복 제거)
        let josaAlt = Set(josaPairs.flatMap { [$0.noBatchim, $0.withBatchim] })
            .sorted { $0.count > $1.count }
            .map(esc)
            .joined(separator: "|")

        // 유니코드 '단어' 경계 집합: 모든 Letter/Number + '_'. (이전엔 Hangul 누락)
        let cjkBody = "\\p{L}\\p{N}_"
        let ws = "(?:\\s|\\u00A0)*"

        // --- [1] 1패스: [조사 O] 패턴 (조사 ‘뒤’에서 경계 검사) ---
        let patWithJosa =
        "(^|[^" + cjkBody + "])" +                // grp1 prefix
        "(" + entityAlts + ")" +                  // grp2 entity
        ws +
        "(" + josaAlt + ")" +                     // grp3 josa
        "($|[^" + cjkBody + "])"                  // grp4 suffix
        let rxWithJosa = try! NSRegularExpression(
            pattern: patWithJosa,           // 주석 없는 버전
            options: [.caseInsensitive]
        )

        var out = textNFC
        var matches1: [(whole:NSRange, g1:NSRange, g2:NSRange, g3:NSRange, g4:NSRange)] = []
        let ns1 = out as NSString
        rxWithJosa.enumerateMatches(in: out, options: [], range: NSRange(location: 0, length: ns1.length)) { m, _, _ in
            guard let m = m else { return }
            matches1.append((m.range(at: 0), m.range(at: 1), m.range(at: 2), m.range(at: 3), m.range(at: 4)))
        }

        for m in matches1.reversed() {
            let ns = out as NSString
            let prefix = ns.substring(with: m.g1)
            let name   = ns.substring(with: m.g2)
            let josa   = ns.substring(with: m.g3)
            let suffix = ns.substring(with: m.g4)

            let (canon, chosen) = resolveEntityAndJosa(nameText: name, josaCandidate: josa,
                                                       locksByToken: locksByToken, names: names, mode: mode)
            out = ns.replacingCharacters(in: m.whole, with: prefix + canon + chosen + suffix)
        }

        // --- [2] 2패스: [조사 X] 패턴 (엔터티 ‘바로 뒤’에서 경계 검사) ---
        let patBare =
        "(^|[^" + cjkBody + "])" +                // grp1 prefix
        "(" + entityAlts + ")" +                  // grp2 entity
        "($|[^" + cjkBody + "])"                  // grp3 suffix
        let rxBare = try! NSRegularExpression(
            pattern: patBare,               // 주석 없는 버전
            options: [.caseInsensitive]
        )

        var matches2: [(whole:NSRange, g1:NSRange, g2:NSRange, g3:NSRange)] = []
        let ns2 = out as NSString
        rxBare.enumerateMatches(in: out, options: [], range: NSRange(location: 0, length: ns2.length)) { m, _, _ in
            guard let m = m else { return }
            matches2.append((m.range(at: 0), m.range(at: 1), m.range(at: 2), m.range(at: 3)))
        }

        for m in matches2.reversed() {
            let ns = out as NSString
            let prefix = ns.substring(with: m.g1)
            let name   = ns.substring(with: m.g2)
            let suffix = ns.substring(with: m.g3)

            let (canon, chosen) = resolveEntityAndJosa(nameText: name, josaCandidate: nil,
                                                       locksByToken: locksByToken, names: names, mode: mode)
            out = ns.replacingCharacters(in: m.whole, with: prefix + canon + chosen + suffix)
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
        if mode != .namesOnly, let info = locksByToken[nameText] {
            // 토큰: 표기는 그대로, 조사만 LockInfo 기준 재계산
            let j = chooseJosa(for: josaCandidate, baseHasBatchim: info.endsWithBatchim, baseIsRieul: info.endsWithRieul)
            return (nameText, j)
        } else {
            // 이름: canonical 통일 + canonical 받침 기준으로 조사 재계산
            let canon = canonicalFor(nameText, entries: names)
            let (has, rieul) = hangulFinalJongInfo(canon)
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
