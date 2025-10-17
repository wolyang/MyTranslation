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
    /// pid -> 단독 허용 성(예: ["P_Gai": ["红"]])
    public var soloFamilyAllow: [String: Set<String>] = [:]
    /// pid -> 단독 허용 이름(예: ["P_Gai": ["凯"]])
    public var soloGivenAllow: [String: Set<String>] = [:]
    /// 전역 네거티브 빅람/트라이그램(추가)
    public var extraNegativeBigrams: Set<String> = []
    /// 문맥 인식 윈도우(최근 동일 인물 언급 인식, 문자 단위)
    public var contextWindow: Int = 40

    public init(
        soloFamilyAllow: [String: Set<String>] = [:],
        soloGivenAllow: [String: Set<String>] = ["1": ["凯"]],
        extraNegativeBigrams: Set<String> = [],
        contextWindow: Int = 40
    ) {
        self.soloFamilyAllow = soloFamilyAllow
        self.soloGivenAllow = soloGivenAllow
        self.extraNegativeBigrams = extraNegativeBigrams
        self.contextWindow = contextWindow
    }

    /// 용어 사전(glossary: 원문→한국어)을 이용해 텍스트 내 용어를 토큰으로 잠그고 LockInfo를 생성한다.
    /// - 반환: masked(토큰 포함), tags(기존 라우터용), locks(조사 교정/언락용)
    public func maskWithLocks(segment: Segment, glossary entries: [GlossaryEntry]) -> (pack: MaskedPack, personQueues: [String: [String]]) {
        let text = segment.originalText
        guard !text.isEmpty, !entries.isEmpty else { return (pack: .init(seg: segment, masked: text, tags: [], locks: [:]), personQueues: [:]) }

        // 긴 키부터 치환(겹침 방지)
        let sorted = entries.sorted { $0.source.count > $1.source.count }

        var out = text
        var tags: [String] = []
        var locks: [String: LockInfo] = [:]
        var personQueues: PersonQueues = [:]
        var localNextIndex = self.nextIndex
        // ▶︎ 사람 이름 짝검증/네거티브 패턴용 인덱스(엔트리 기반 간이 구축)
        var fullSourcesByPid: [String: Set<String>] = [:] // pid -> {길이≥2 소스}
        var singleSourcesByPid: [String: Set<String>] = [:] // pid -> {길이=1 소스}
        for e in sorted where e.category == .person {
            guard let pid = e.personId, !pid.isEmpty else { continue }
            if e.source.count >= 2 { fullSourcesByPid[pid, default: []].insert(e.source) }
            else { singleSourcesByPid[pid, default: []].insert(e.source) }
        }
        // 문맥-인식: 같은 세그먼스 내 최근 언급 위치 기록(pid -> 마지막 index)
        var lastMentionIndexByPid: [String: Int] = [:]

        for e in sorted {
            guard !e.source.isEmpty, out.contains(e.source) else { continue }
            
            let prefix: String
            switch e.category {
            case .person:
                if e.personId != nil {
                    prefix = "P"
                } else {
                    prefix = "U"
                }
            case .organization: prefix = "O"
            case .term: prefix = "K"
            case .other: prefix = "X"
            }

            // === 토큰 생성 ===
            let token: String
            if e.category == .person {
                if let pid = e.personId, !pid.isEmpty {
                    token = "__PERSON_\(prefix)\(pid)__" // per-person 고정 토큰
                } else {
                    token = "__PERSON_\(prefix)\(localNextIndex)__" // fallback: 각 항목 고유
                }
            } else {
                token = "__MASK_\(prefix)\(localNextIndex)__" // 기타 카테고리: 기존 각괄호 토큰 유지
            }
            print("pid: \(String(describing: e.personId)), source: \(e.source) -> token: \(token)")
            localNextIndex += 1

            // 좌→우 모든 발생을 안전 치환 + 인물 큐 push
            let pattern = NSRegularExpression.escapedPattern(for: e.source)
            guard let rx = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = rx.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { continue }

            var newOut = String(); newOut.reserveCapacity(out.utf16.count)
            var last = 0
            for m in matches {
                if last < m.range.location {
                    newOut += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                }
                
                var shouldMask = true
                if e.category == .person, let pid = e.personId, !pid.isEmpty, e.source.count == 1 {
                    // ---- 단일 한자 인물: 네거티브 → 화이트리스트 → 최근언급 → 짝검증 ----
                    if isNegativeBigram(ns: ns, matchRange: m.range, center: e.source) {
                        shouldMask = false
                    } else if (soloFamilyAllow[pid]?.contains(e.source) == true) || (soloGivenAllow[pid]?.contains(e.source) == true) {
                        shouldMask = true
                    } else if let last = lastMentionIndexByPid[pid], (m.range.location - last) <= contextWindow {
                        shouldMask = true
                    } else {
                        // 짝검증(근접 조합): 이전 1~2자 + 현재, 현재 + 다음 1~2자가 같은 pid의 길이≥2 소스인지
                        let prev1 = Self.substringSafe(ns, m.range.location - 1, 1)
                        let prev2 = Self.substringSafe(ns, m.range.location - 2, 2)
                        let next1 = Self.substringSafe(ns, m.range.location + m.range.length, 1)
                        let next2 = Self.substringSafe(ns, m.range.location + m.range.length, 2)
                        let fulls = fullSourcesByPid[pid] ?? []
                        if fulls.contains(prev1 + e.source) || fulls.contains(prev2)
                            || fulls.contains(e.source + next1) || fulls.contains(e.source + next2)
                        {
                            shouldMask = true
                        } else {
                            shouldMask = false
                        }
                    }
                }

                if shouldMask {
                    newOut += token
                    if e.category == .person, let pid = e.personId, !pid.isEmpty {
                        var arr = personQueues[pid] ?? []
                        arr.append(e.target)
                        personQueues[pid] = arr
                        // 문맥-기억: 최근 언급 위치 갱신
                        lastMentionIndexByPid[pid] = m.range.location
                    }
                } else {
                    newOut += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length

                if e.category == .person, let pid = e.personId {
                    var arr = personQueues[pid] ?? []
                    arr.append(e.target)
                    personQueues[pid] = arr
                }
            }
            if last < ns.length { newOut += ns.substring(with: NSRange(location: last, length: ns.length - last)) }
            out = newOut
            
            // NBSP 경계 힌트
            if e.category == .person {
                out = surroundTokenWithNBSP(out, token: token)
            }

            // 라우터 호환 태그 유지
            tags.append(e.target)

            // 조사 교정용 LockInfo
            let (b, r) = hangulFinalJongInfo(e.target)
            locks[token] = LockInfo(placeholder: token, target: e.target, endsWithBatchim: b, endsWithRieul: r, category: e.category)
        }
        
        // nextIndex 업데이트(기존 의미 유지)
        self.nextIndex = localNextIndex
        
        return (.init(seg: segment, masked: out, tags: tags, locks: locks), personQueues: personQueues)
    }

    /// 토큰 주변 조사(은/는, 이/가, 을/를, 과/와, (이)라, (으)로, (아/야)) 교정
    public func fixParticlesAroundLocks(_ text: String, locks: [String: LockInfo]) -> String {
        var out = text
        for (_, info) in locks {
            out = fixAroundToken(out, token: info.placeholder, info: info)
        }
        return out
    }

    /// 토큰들을 locks 사전에 따라 정확히 복원.
    func unlockTermsSafely(
        _ text: String,
        locks: [String: LockInfo],
        personQueues: PersonQueues
    ) -> String {
        let pattern = #"(__PERSON_P([A-Za-z0-9_-]+)__)|(?:__PERSON_U\d+__)|(?:__MASK_[A-Z]\d+__)"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        
        var queues = personQueues
        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))

        var out = String()
        out.reserveCapacity(text.utf16.count)
        var last = 0

        for m in matches {
            let full = m.range(at: 0)
            if last < full.location { out += ns.substring(with: NSRange(location: last, length: full.location - last)) }
            let whole = ns.substring(with: full)
            
            if m.numberOfRanges >= 3, m.range(at: 2).location != NSNotFound {
                // __PERSON_P{pid}__ → 큐 pop
                let pid = ns.substring(with: m.range(at: 2))
                if var arr = queues[pid], !arr.isEmpty {
                    out += arr.removeFirst(); queues[pid] = arr
                } else if let lk = locks[whole] {
                    out += lk.target // 큐 고갈 대비
                } else {
                    out += whole
                }
            } else {
                // __PERSON_U{n}__ · __MASK_{n}__ → locks로 복원
                out += locks[whole]?.target ?? whole
            }
            last = full.location + full.length
        }

        // 남은 꼬리 복사
        if last < ns.length {
            out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }

        return out
    }
    
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

        var str = s

        // 2) 을/를
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "를", token + "을")
        } else {
            str = rxReplace(str, t + ws + "을", token + "를")
        }

        // 3) 은/는
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "는", token + "은")
        } else {
            str = rxReplace(str, t + ws + "은", token + "는")
        }

        // 4) 이/가
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "가", token + "이")
        } else {
            str = rxReplace(str, t + ws + "이", token + "가")
        }

        // 5) 과/와
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "와", token + "과")
        } else {
            str = rxReplace(str, t + ws + "과", token + "와")
        }

        // 6) (이)라
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "라", token + "이라")
        } else {
            str = rxReplace(str, t + ws + "이라", token + "라")
        }

        // 7) (으)로 — ㄹ 특례
        if info.endsWithBatchim {
            if info.endsWithRieul {
                str = rxReplace(str, t + ws + "으로", token + "로") // ㄹ 받침이면 무조건 '로'
            } else {
                str = rxReplace(str, t + ws + "로", token + "으로") // 일반 받침: '로'→'으로'
            }
        } else {
            str = rxReplace(str, t + ws + "으로", token + "로") // 받침 없음: '으로'→'로'
        }

        // 8) 아/야
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "야", token + "아")
        } else {
            str = rxReplace(str, t + ws + "아", token + "야")
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
