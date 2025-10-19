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
            glossary entries: [GlossaryEntry]
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

            // === 단일 한자 검증용 사전 구축 (그대로 유지)
            var fullSourcesByPid: [String: Set<String>] = [:]
            var singleSourcesByPid: [String: Set<String>] = [:]
            for e in sorted where e.category == .person {
                guard let pid = e.personId, !pid.isEmpty else { continue }
                if e.source.count >= 2 { fullSourcesByPid[pid, default: []].insert(e.source) }
                else { singleSourcesByPid[pid, default: []].insert(e.source) }
            }
            var lastMentionIndexByPid: [String: Int] = [:]

            for e in sorted {
                guard !e.source.isEmpty, out.contains(e.source) else { continue }

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
                       e.source.count == 1 {
                        // ---- 단일 한자 인물: 네거티브 → 화이트리스트 → 최근언급 → 짝검증 ----
                        if isNegativeBigram(ns: ns, matchRange: m.range, center: e.source) {
                            shouldMask = false
                        } else if (soloFamilyAllow[pid]?.contains(e.source) == true)
                            || (soloGivenAllow[pid]?.contains(e.source) == true)
                                    || (soloAliasAllow[pid]?.contains(e.source) == true) {
                            shouldMask = true
                        } else if let last = lastMentionIndexByPid[pid],
                                  (m.range.location - last) <= contextWindow {
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

    /// 토큰 주변 조사(은/는, 이/가, 을/를, 과/와, (이)라, (으)로, (아/야)) 교정
    public func fixParticlesAroundLocks(_ text: String, locks: [String: LockInfo]) -> String {
        var out = text
        for (_, info) in locks {
            out = fixAroundToken(out, token: info.placeholder, info: info)
        }
        return out
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
        "脸红", "发红", "泛红", "通红", "变红", "红色", "红了", "红的"
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

    // 조사 교정 세부
    private func fixAroundToken(_ s: String, token: String, info: LockInfo) -> String {
        // 1) 안전한 패턴 파츠
        let t = NSRegularExpression.escapedPattern(for: token)
        let ws = "(?:\\s|\\u00A0)*" // 공백 + NBSP (0개 이상)
        let B  = #"(?=$|\s|[\p{P}\p{S}])"# // 조사 뒤 경계(끝/공백/문장부호)

        var str = s
        
        // 6) (이)라
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "라" + B, token + "이라")
        } else {
            str = rxReplace(str, t + ws + "이라" + B, token + "라")
        }

        // 7) (으)로 — ㄹ 특례
        if info.endsWithBatchim {
            if info.endsWithRieul {
                str = rxReplace(str, t + ws + "으로" + B, token + "로") // ㄹ 받침이면 무조건 '로'
            } else {
                str = rxReplace(str, t + ws + "로" + B, token + "으로") // 일반 받침: '로'→'으로'
            }
        } else {
            str = rxReplace(str, t + ws + "으로" + B, token + "로") // 받침 없음: '으로'→'로'
        }

        // 2) 을/를
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "를" + B, token + "을")
        } else {
            str = rxReplace(str, t + ws + "을" + B, token + "를")
        }

        // 3) 은/는
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "는" + B, token + "은")
        } else {
            str = rxReplace(str, t + ws + "은" + B, token + "는")
        }

        // 4) 이/가
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "가" + B, token + "이")
        } else {
            str = rxReplace(str, t + ws + "이" + B, token + "가")
        }

        // 5) 과/와
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "와" + B, token + "과")
        } else {
            str = rxReplace(str, t + ws + "과" + B, token + "와")
        }

        // 8) 아/야
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "야" + B, token + "아")
        } else {
            str = rxReplace(str, t + ws + "아" + B, token + "야")
        }

        return str
    }
    
    func rxReplace(_ str: String, _ pattern: String, _ repl: String) -> String {
        do {
            let rx = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(str.startIndex..., in: str)
            return rx.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: repl)
        } catch {
            print("[JOSA][ERR] invalid regex: \(pattern) error=\(error)")
            return str
        }
    }
    
    /// 전체 텍스트를 단락(또는 세그먼트) 단위로 나눠,
    /// "토큰을 모두 제거하면 문장부호/공백만 남는" 단락에서만
    /// 토큰 양옆(문장부호 인접)에 공백을 삽입한다.
    func insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(_ text: String) -> String {
        let paras = text.components(separatedBy: "\n")
        var outParas: [String] = []
        outParas.reserveCapacity(paras.count)

        let stripRx = try! NSRegularExpression(pattern: tokenRegex)
        let leftRx  = try! NSRegularExpression(pattern: #"(?<=[\p{P}\p{S}])(__(?:[^_]|_(?!_))+__)"#)
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
