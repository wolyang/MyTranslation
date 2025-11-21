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

    /// 번역 대상 언어에 맞춰 토큰 주변 공백 삽입 정책을 제어한다.
    public var tokenSpacingBehavior: TokenSpacingBehavior = .disabled
    
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
    
    // ---- 유틸
    func allOccurrences(of needle: String, in hay: String) -> [Int] {
        guard !needle.isEmpty, !hay.isEmpty else { return [] }
        var out: [Int] = []; var from = hay.startIndex
        while from < hay.endIndex, let r = hay.range(of: needle, range: from..<hay.endIndex) {
            out.append(hay.distance(from: hay.startIndex, to: r.lowerBound))
            from = hay.index(after: r.lowerBound) // 겹치기 허용
        }
        return out
    }
    
    /// 이번 세그먼트에서 예외적으로 허용해야 하는 GlossaryEntry 배열을 리턴한다.
    public func promoteProhibitedEntries(
        in segmentText: String,
        entries: [GlossaryEntry]
    ) -> [GlossaryEntry] {
        func slice(_ s: String, start: Int, len: Int) -> Substring {
            let st = max(0, min(start, s.count))
            let en = max(st, min(st + len, s.count))
            let a = s.index(s.startIndex, offsetBy: st)
            let b = s.index(s.startIndex, offsetBy: en)
            return s[a..<b]
        }
        
        // 1) composer 엔트리에서 (leftId,rightId) 쌍 수집
        struct Pair { let left: String; let right: String }
            var composerPairs: [Pair] = []
            for e in entries {
                if case let .composer(_, leftId, rightId, needPairCheck) = e.origin {
                    if needPairCheck, let rightId {
                        composerPairs.append(.init(left: leftId, right: rightId))
                    }
                }
            }
            guard !composerPairs.isEmpty else { return [] }
        
        // 2) termId -> prohibited 단독 GlossaryEntry 목록
        var prohibTerms: [String: [GlossaryEntry]] = [:]
        for e in entries where e.prohibitStandalone {
            if case let .termStandalone(termId) = e.origin {
                prohibTerms[termId, default: []].append(e)
            }
        }
        
        var promoted: [GlossaryEntry] = []
        
        if !composerPairs.isEmpty && !prohibTerms.isEmpty {
            // 3) termId -> source 출현 오프셋 목록
            var occ: [String: [Int]] = [:]
            for (tid, termEntries) in prohibTerms {
                var offsets: [Int] = []
                for e in termEntries {
                    offsets += allOccurrences(of: e.source, in: segmentText)
                }
                if !offsets.isEmpty { occ[tid] = offsets.sorted() }
            }
            if occ.isEmpty { return [] }
            
            // 4) composer 쌍마다 거리 판정, 짝 성립 시 두 Term 엔트리를 승격 목록에 추가
            for p in composerPairs {
                guard let lOcc = occ[p.left], let rOcc = occ[p.right] else { continue }
                var ok = false
                for lp in lOcc {
                    for rp in rOcc where abs(lp - rp) <= contextWindow {
                        ok = true; break
                    }
                    if ok { break }
                }
                if ok {
                    if let lefts = prohibTerms[p.left] { promoted.append(contentsOf: lefts) }
                    if let rights = prohibTerms[p.right] { promoted.append(contentsOf: rights) }
                }
            }
        }

        return promoted
    }

    /// 주어진 entries에서 사용된 모든 Term 키를 수집한다.
    /// - Parameter entries: GlossaryEntry 배열
    /// - Returns: Entry에 포함된 모든 Term 키의 집합
    func collectUsedTermKeys(from entries: [GlossaryEntry]) -> Set<String> {
        var used: Set<String> = []
        for entry in entries {
            switch entry.origin {
            case let .termStandalone(termId):
                used.insert(termId)
            case let .composer(composerId, leftId, rightId, _):
                used.insert(composerId)
                used.insert(leftId)
                if let rightId = rightId {
                    used.insert(rightId)
                }
            }
        }
        return used
    }

    /// usedKeys에 의해 활성화되는 Term 키들을 수집한다.
    /// - Parameters:
    ///   - entries: 모든 GlossaryEntry 배열
    ///   - usedKeys: 현재 Segment에서 사용된 Term 키들
    /// - Returns: 활성화되는 Term 키의 집합
    func collectActivatedTermKeys(from entries: [GlossaryEntry], usedKeys: Set<String>) -> Set<String> {
        var activated: Set<String> = []
        for entry in entries {
            // entry.activatorKeys와 usedKeys가 교집합이 있으면, 이 entry의 key를 활성화
            if !entry.activatorKeys.isEmpty, !entry.activatorKeys.isDisjoint(with: usedKeys) {
                switch entry.origin {
                case let .termStandalone(termId):
                    activated.insert(termId)
                case let .composer(composerId, _, _, _):
                    activated.insert(composerId)
                }
            }
        }
        return activated
    }

    /// Term-to-Term 활성화를 통해 승격되는 entries를 추출한다.
    /// - Parameters:
    ///   - allEntries: 모든 GlossaryEntry 배열
    ///   - standaloneEntries: prohibitStandalone이 아닌 Entry 배열
    ///   - normalizedOriginal: 정규화된 원문 텍스트
    /// - Returns: 활성화된 Entry 배열
    func promoteActivatedEntries(
        from allEntries: [GlossaryEntry],
        standaloneEntries: [GlossaryEntry],
        original: String
    ) -> [GlossaryEntry] {
        // 1. 원문에 등장하는 standalone entries만 필터링
        let standaloneEntriesInText = standaloneEntries.filter { entry in
            let source = entry.source
            return original.contains(source)
        }

        // 2. usedKeys 수집
        let usedKeys = collectUsedTermKeys(from: standaloneEntriesInText)

        // 3. activatedKeys 수집
        let activatedKeys = collectActivatedTermKeys(from: allEntries, usedKeys: usedKeys)

        // 4. activatedKeys에 해당하는 termStandalone entries 반환
        return allEntries.filter {
            guard case let .termStandalone(termId) = $0.origin else { return false }
            return activatedKeys.contains(termId)
        }
    }

    // MARK: - SegmentPieces 생성

    private func splitTextBySource(_ text: String, source: String) -> [String] {
        var parts: [String] = []
        var remaining = text

        while let range = remaining.range(of: source) {
            if range.lowerBound > remaining.startIndex {
                parts.append(String(remaining[remaining.startIndex..<range.lowerBound]))
            }
            parts.append(source)
            remaining = String(remaining[range.upperBound...])
        }

        if !remaining.isEmpty {
            parts.append(remaining)
        }

        return parts
    }

    func buildSegmentPieces(
        segment: Segment,
        glossary allEntries: [GlossaryEntry]
    ) -> (pieces: SegmentPieces, activatedEntries: [GlossaryEntry]) {
        let text = segment.originalText
        guard !text.isEmpty, !allEntries.isEmpty else {
            return (
                pieces: SegmentPieces(segmentID: segment.id, pieces: [.text(text)]),
                activatedEntries: []
            )
        }

        // 1) 기본 활성화 (단독 허용)
        let standaloneEntries = allEntries.filter { !$0.prohibitStandalone }

        // 2) Pattern 기반 활성화
        let patternPromoted = promoteProhibitedEntries(in: text, entries: allEntries)

        // 3) Term-to-Term 활성화
        let termPromoted = promoteActivatedEntries(
            from: allEntries,
            standaloneEntries: standaloneEntries,
            original: text
        )

        // 4) 활성화 엔트리 합치기 (source 기준 중복 제거)
        var combined = standaloneEntries
        combined.append(contentsOf: patternPromoted)
        combined.append(contentsOf: termPromoted)

        var seenSource: Set<String> = []
        var allowedEntries: [GlossaryEntry] = []
        for entry in combined {
            if seenSource.insert(entry.source).inserted {
                allowedEntries.append(entry)
            }
        }

        // 5) 긴 용어가 덮는 짧은 용어 제외
        allowedEntries = filterBySourceOcc(segment, allowedEntries)

        // 6) Longest-first 분할
        let sorted = allowedEntries.sorted { $0.source.count > $1.source.count }
        var pieces: [SegmentPieces.Piece] = [.text(text)]

        for entry in sorted {
            guard !entry.source.isEmpty else { continue }
            var newPieces: [SegmentPieces.Piece] = []

            for piece in pieces {
                switch piece {
                case .text(let str):
                    if str.contains(entry.source) {
                        let parts = splitTextBySource(str, source: entry.source)
                        for part in parts {
                            if part == entry.source {
                                newPieces.append(.term(entry))
                            } else {
                                newPieces.append(.text(part))
                            }
                        }
                    } else {
                        newPieces.append(.text(str))
                    }
                case .term:
                    newPieces.append(piece)
                }
            }

            pieces = newPieces
        }

        return (
            pieces: SegmentPieces(segmentID: segment.id, pieces: pieces),
            activatedEntries: allowedEntries
        )
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

        for e in sorted {
            guard !e.source.isEmpty, out.contains(e.source) else { continue }
            // 호칭, 인물명 등은 마스킹하지 않음
            if !e.preMask { continue }

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
                newOut += token
                last = m.range.location + m.range.length
            }

            if last < ns.length {
                newOut += ns.substring(with: NSRange(location: last, length: ns.length - last))
            }
            out = newOut

            // (2) 사람일 때만 NBSP 힌트 주입
            if e.isAppellation {
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
                isAppellation: e.isAppellation
            )
        }

        // (5) 토큰 좌우 문장부호 인접 시 공백 삽입
        out = insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(out)

        self.nextIndex = localNextIndex
        return .init(seg: segment, masked: out, tags: tags, locks: locks)
    }

    // SegmentPieces 기반 마스킹
    func maskFromPieces(
        pieces: SegmentPieces,
        segment: Segment
    ) -> MaskedPack {
        var out = ""
        var locks: [String: LockInfo] = [:]
        var localNextIndex = self.nextIndex

        for piece in pieces.pieces {
            switch piece {
            case .text(let str):
                out += str
            case .term(let entry):
                if entry.preMask {
                    let token = Self.makeToken(prefix: "E", index: localNextIndex)
                    localNextIndex += 1
                    out += token

                    if entry.isAppellation {
                        out = surroundTokenWithNBSP(out, token: token)
                    }

                    let (b, r) = hangulFinalJongInfo(entry.target)
                    locks[token] = LockInfo(
                        placeholder: token,
                        target: entry.target,
                        endsWithBatchim: b,
                        endsWithRieul: r,
                        isAppellation: entry.isAppellation
                    )
                } else {
                    out += entry.source
                }
            }
        }

        out = insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(out)
        self.nextIndex = localNextIndex
        return .init(seg: segment, masked: out, tags: [], locks: locks)
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
        guard tokenSpacingBehavior == .isolatedSegments else { return text }

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
        struct FallbackTerm: Sendable {
            let termKey: String
            let target: String
            let variants: [String]
        }

        let target: String
        let variants: [String]
        let expectedCount: Int   // 원문에서 이 이름이 등장한 횟수
        let fallbackTerms: [FallbackTerm]?  // Pattern fallback용
    }

    /// 원문에 등장한 인물 용어만 선별하여 정규화용 이름 정보를 생성한다.
    /// - Parameters:
    ///   - original: 용어 검사를 수행할 원문 텍스트
    ///   - entries: 용어집 엔트리 목록
    /// - Returns: 원문에 등장한 인물 용어의 target/variants 정보 배열
    func makeNameGlossaries(seg: Segment, entries: [GlossaryEntry]) -> [NameGlossary] {
        let original = seg.originalText
        guard !original.isEmpty else { return [] }

        // 1) 기본: prohibitStandalone이 아닌 엔트리
        let standaloneEntries = entries.filter { !$0.prohibitStandalone }

        // 2) Pattern 기반 활성화: promoteProhibitedEntries 통합
        let patternPromoted = promoteProhibitedEntries(in: original, entries: entries)

        // 3) Term-to-Term 활성화
        let termPromoted = promoteActivatedEntries(
            from: entries,
            standaloneEntries: standaloneEntries,
            original: original
        )

        // 4) 모든 허용 엔트리 합치기 (중복 제거)
        var combined = standaloneEntries
        combined.append(contentsOf: patternPromoted)
        combined.append(contentsOf: termPromoted)

        // 중복 제거
        var seenSource: Set<String> = []
        var allowedEntries: [GlossaryEntry] = []
        for entry in combined {
            let source = entry.source
            if seenSource.insert(source).inserted {
                allowedEntries.append(entry)
            }
        }

        allowedEntries = filterBySourceOcc(seg, allowedEntries)
        
        var variantsByTarget: [String: [String]] = [:]
        var seenVariantKeysByTarget: [String: Set<String>] = [:]
        var expectedCountsByTarget: [String: Int] = [:]

        for entry in allowedEntries {
            guard !entry.target.isEmpty else { continue }
            let source = entry.source
            guard original.contains(source) else { continue }

            if !entry.variants.isEmpty {
                var bucket = variantsByTarget[entry.target, default: []]
                var seen = seenVariantKeysByTarget[entry.target, default: []]
                for variant in entry.variants where !variant.isEmpty {
                    if seen.insert(variant).inserted {
                        bucket.append(variant)
                    }
                }
                variantsByTarget[entry.target] = bucket
                seenVariantKeysByTarget[entry.target] = seen
            } else if variantsByTarget[entry.target] == nil {
                variantsByTarget[entry.target] = []
            }
            
            if original.contains(source) {
                let occ = original.components(separatedBy: source).count - 1
                if occ > 0 {
                    expectedCountsByTarget[entry.target, default: 0] += occ
                }
            }
        }

        guard variantsByTarget.isEmpty == false else { return [] }

        return variantsByTarget.map { target, variants in
            (target: target, variants: variants, count: expectedCountsByTarget[target] ?? 0)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.target < rhs.target
        }.map { NameGlossary(target: $0.target, variants: $0.variants, expectedCount: $0.count, fallbackTerms: nil) }
    }

    /// SegmentPieces 기반 정규화용 NameGlossary 생성
    func makeNameGlossariesFromPieces(
        pieces: SegmentPieces,
        allEntries: [GlossaryEntry]
    ) -> [NameGlossary] {
        let unmaskedEntries = pieces.detectedTerms.filter { !$0.preMask }
        guard !unmaskedEntries.isEmpty else { return [] }

        var variantsByTarget: [String: [String]] = [:]
        var seenVariantKeysByTarget: [String: Set<String>] = [:]
        var expectedCountsByTarget: [String: Int] = [:]
        var fallbackByTarget: [String: [NameGlossary.FallbackTerm]] = [:]

        for entry in unmaskedEntries {
            let target = entry.target
            guard target.isEmpty == false else { continue }

            if variantsByTarget[target] == nil {
                variantsByTarget[target] = []
            }

            if !entry.variants.isEmpty {
                var bucket = variantsByTarget[target] ?? []
                var seen = seenVariantKeysByTarget[target, default: []]
                for variant in entry.variants where !variant.isEmpty {
                    if seen.insert(variant).inserted {
                        bucket.append(variant)
                    }
                }
                variantsByTarget[target] = bucket
                seenVariantKeysByTarget[target] = seen
            }

            let count = pieces.pieces.filter {
                if case .term(let e) = $0, e.target == target {
                    return true
                }
                return false
            }.count
            expectedCountsByTarget[target, default: 0] += count

            // Pattern fallback 구성 (origin에서 구성 Term 키를 추출)
            if case let .composer(_, leftKey, rightKey, _) = entry.origin {
                var termKeys: [String] = [leftKey]
                if let r = rightKey { termKeys.append(r) }

                var fallbacks: [NameGlossary.FallbackTerm] = []
                for key in termKeys {
                    guard let fallbackEntry = allEntries.first(where: {
                        if case let .termStandalone(termKey) = $0.origin { return termKey == key }
                        return false
                    }) else { continue }
                    fallbacks.append(
                        .init(termKey: key, target: fallbackEntry.target, variants: Array(fallbackEntry.variants))
                    )
                }
                if fallbacks.isEmpty == false {
                    fallbackByTarget[target, default: []].append(contentsOf: fallbacks)
                }
            }
        }

        guard variantsByTarget.isEmpty == false else { return [] }

        return variantsByTarget.map { target, variants in
            (
                target: target,
                variants: variants,
                count: expectedCountsByTarget[target] ?? 0,
                fallbackTerms: fallbackByTarget[target]
            )
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.target < rhs.target
        }.map { NameGlossary(target: $0.target, variants: $0.variants, expectedCount: $0.count, fallbackTerms: $0.fallbackTerms) }
    }
    
    /// 실제 등장 위치를 기준으로, 긴 용어에 완전히 덮이는 짧은 용어는 이 세그먼트에선 제외
    private func filterBySourceOcc(_ seg: Segment, _ allowedEntries: [GlossaryEntry]) -> [GlossaryEntry] {
        let normalizedOriginal = seg.originalText
        struct SourceOcc {
            let entry: GlossaryEntry
            let normSource: String
            let length: Int
            let positions: [Int]
        }

        // 1) 이 세그먼트에서 실제로 등장한 용어만 모으기
        var occList: [SourceOcc] = []
        for e in allowedEntries {
            guard !e.target.isEmpty else { continue }
            let normSource = e.source
            let positions = allOccurrences(of: normSource, in: normalizedOriginal)
            guard !positions.isEmpty else { continue }   // 이 세그먼트엔 안 나옴
            occList.append(SourceOcc(entry: e, normSource: normSource, length: normSource.count, positions: positions))
        }

        guard occList.isEmpty == false else { return [] }

        // 2) 각 용어가 “독립적으로”도 쓰였는지 검사
        var keepFlags = Array(repeating: true, count: occList.count)

        for i in 0..<occList.count {
            let short = occList[i]
            var hasIndependentUse = false

            for p in short.positions {
                let start = p
                let end   = p + short.length

                var coveredByLonger = false
                for j in 0..<occList.count where j != i {
                    let long = occList[j]
                    guard long.length > short.length else { continue }

                    for q in long.positions {
                        let longStart = q
                        let longEnd   = q + long.length
                        if longStart <= start && end <= longEnd {
                            coveredByLonger = true
                            break
                        }
                    }
                    if coveredByLonger { break }
                }

                if coveredByLonger == false {
                    // 이 위치는 어떤 더 긴 용어에도 완전히 포함되지 않음 → 독립적 사용 있음
                    hasIndependentUse = true
                    break
                }
            }

            if hasIndependentUse == false {
                // 모든 등장 위치가 항상 더 긴 용어 안에만 있음 → 이 세그먼트에서는 제외
                keepFlags[i] = false
            }
        }

        // 3) 최종적으로 이 세그먼트에서 사용할 엔트리 집합
        let filteredEntries: [GlossaryEntry] = occList.enumerated()
            .compactMap { idx, s in keepFlags[idx] ? s.entry : nil }
        return filteredEntries
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
        .init(noBatchim: "였",   withBatchim: "이었", rieulException: false, prefersWithBatchimWhenAuxAttached: false),
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
        // B1) 뒤쪽 언더스코어가 아예 없는 케이스: "__E#56" → "__E#56__"
        let rxB1 = try! NSRegularExpression(pattern: "(?i)(?<!_)_?__?E#" + d + "(?![A-Za-z0-9_])")
        // B2) 앞뒤 언더스코어가 모두 없는 케이스: "E#56" → "__E#56__"
        let rxB2 = try! NSRegularExpression(pattern: "(?i)(?<!_)E#" + d + "(?![A-Za-z0-9_])")

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
                    let id = halfwidth(idRaw)
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
                    let id = halfwidth(idRaw)
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        // --- B1 ---
        do {
            let ns = out as NSString
            let ms = rxB1.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !ms.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in ms.reversed() {
                    let idRaw = ns.substring(with: m.range(at: 1))
                    let id = halfwidth(idRaw)
                    if validIDs.contains(id) {
                        tmp = tmpNS.replacingCharacters(in: m.range(at: 0), with: "__E#\(id)__")
                        tmpNS = tmp as NSString
                    }
                }
                out = tmp
            }
        }

        // --- B2 ---
        do {
            let ns = out as NSString
            let ms = rxB2.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            if !ms.isEmpty {
                var tmp = out
                var tmpNS = tmp as NSString
                for m in ms.reversed() {
                    let idRaw = ns.substring(with: m.range(at: 1))
                    let id = halfwidth(idRaw)
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
    
    enum EntityMode { case tokensOnly, namesOnly, both }
    
    // 토큰 언마스킹
    func normalizeTokensAndParticles(
        in text: String,
        locksByToken: [String: LockInfo]
    ) -> String {
        let textNFC = text.precomposedStringWithCompatibilityMapping
        func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
        
        // 1) 토큰 문자열 alternation
        let tokenAlts = locksByToken.keys.map(esc).sorted { $0.count > $1.count }.joined(separator: "|")
        guard !tokenAlts.isEmpty else { return text }

        let pattern = "(" + tokenAlts + ")"
        let rx = try! NSRegularExpression(pattern: pattern)

        var out = textNFC
        var matches: [NSRange] = []
        let ns = out as NSString

        rx.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range(at: 1) else { return }
            matches.append(r)
        }

        // 2) 뒤에서부터 교체
        for r in matches.reversed() {
            let nsOut = out as NSString
            let token = nsOut.substring(with: r)
            guard let lock = locksByToken[token] else { continue }

            // (a) 토큰이 교체될 canonical 텍스트
            let canon = lock.target

            // (b) 토큰 → canonical로 교체
            out = nsOut.replacingCharacters(in: r, with: canon)

            // (c) 교체된 canonical의 NSRange 다시 계산
            let canonRange = NSRange(location: r.location, length: (canon as NSString).length)

            // (d) canonical 뒤 조사 보정 (particleHint는 LockInfo에서 꺼낼 수 있으면 전달)
            let (fixed, _) = fixParticles(
                in: out,
                afterCanonical: canonRange,
                baseHasBatchim: lock.endsWithBatchim,
                baseIsRieul: lock.endsWithRieul
            )
            out = fixed
        }

        return out
    }
    
    // 마스킹하지 않은 용어집의 변형 정규화
    func normalizeVariantsAndParticles(
        in text: String,
        entries: [NameGlossary]
    ) -> String {
        let textNFC = text.precomposedStringWithCompatibilityMapping
        func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

        // 1) variant → canonical target 매핑 준비
        //    target 자신도 포함 (canonical이 이미 쓰인 경우에도 usage 카운트 등 맞추려면)
        var variantMap: [String: String] = [:]
        for e in entries {
            let sortedVariants = e.variants.sorted { $0.count > $1.count }
            if variantMap[e.target] == nil { variantMap[e.target] = e.target }
            for v in sortedVariants where !v.isEmpty {
                if variantMap[v] == nil { variantMap[v] = e.target }
            }
        }

        // Pattern Fallback variants는 2순위로 추가 (기존 매핑을 덮지 않음)
        for e in entries {
            guard let fallbackTerms = e.fallbackTerms else { continue }
            for fallback in fallbackTerms {
                if variantMap[fallback.target] == nil { variantMap[fallback.target] = fallback.target }
                let sortedVariants = fallback.variants.sorted { $0.count > $1.count }
                for v in sortedVariants where !v.isEmpty {
                    if variantMap[v] == nil { variantMap[v] = fallback.target }
                }
            }
        }

        let allVariants = Array(variantMap.keys)
        if allVariants.isEmpty { return text }

        // 2) alternation 생성 (긴 것 우선)
        let alts = allVariants.map(esc).sorted { $0.count > $1.count }.joined(separator: "|")

        //    이름은 “조사 유무 무관, 조사 검사 안 함”이니까,
        //    최소한 왼쪽 단어 경계만 체크하는 정도로 완화
        let cjkBody = "\\p{L}\\p{N}_"
        let pre = "(?<![" + cjkBody + "])"

        let pattern = pre + "(" + alts + ")"
        let rx = try! NSRegularExpression(pattern: pattern)

        var out = textNFC
        var matches: [NSRange] = []
        let ns = out as NSString
        rx.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let r = m?.range(at: 1) else { return }
            matches.append(r)
        }

        // 3) 뒤에서부터 정규화 + 조사 보정
        for r in matches.reversed() {
            let nsOut = out as NSString
            let found = nsOut.substring(with: r)
            guard let canon = variantMap[found] else { continue }
            let (has, rieul) = hangulFinalJongInfo(canon)

            // (a) variant/target → target으로 통일
            out = nsOut.replacingCharacters(in: r, with: canon)

            // (b) canonical range 재계산
            let canonRange = NSRange(location: r.location, length: (canon as NSString).length)

            // (c) canonical 뒤 조사 보정
            let (fixed, _) = fixParticles(
                in: out,
                afterCanonical: canonRange,
                baseHasBatchim: has,
                baseIsRieul: rieul
            )
            out = fixed
        }

        return out
    }

    // 언마스킹된 토큰 / 정규화된 용어의 조사 보정
    func fixParticles(
        in text: String,
        afterCanonical canonRange: NSRange,
        baseHasBatchim: Bool,
        baseIsRieul: Bool
    ) -> (String, NSRange) {
        var out = text
            let ns = out as NSString

            // canonical 뒤에 더 문자가 없으면 할 일 없음
            let canonEnd = canonRange.location + canonRange.length
            guard canonEnd < ns.length else {
                return (out, canonRange)
            }

            let tailRange = NSRange(location: canonEnd, length: ns.length - canonEnd)

            // --- 기존 normalizeEntitiesAndParticles에서 쓰던 gap + josaSequence 로직 재사용 ---
            let wsZ = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*"
            let softPunct = "[\"'“”’»«》〈〉〉》」』】）\\)\\]\\}]"
            let gap = "(?:" + wsZ + "(?:" + softPunct + ")?" + wsZ + ")"

            let particleTokenAlt = "(?:" + particleTokenAlternation + ")"
            let josaJoin = "" // 공백 없음 (필요 시 NBSP 허용 로직으로 변경 가능)
            let josaSequence = particleTokenAlt + "(?:" + josaJoin + particleTokenAlt + ")*"

            // tail의 맨 앞에서만 gap + josaSequence를 찾는다
            let pattern = "^(" + gap + ")(" + josaSequence + ")"

            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else {
                return (out, canonRange)
            }

            // .anchored: tailRange의 시작에서만 매치 시도
            guard let m = rx.firstMatch(in: out, options: [.anchored], range: tailRange) else {
                // canonical 뒤에 gap+조사 패턴이 없으면 그대로 반환
                return (out, canonRange)
            }

            // grp1: gap, grp2: josa sequence
            let gapRange = m.range(at: 1) // 현재는 사용하지 않지만, 필요하면 gap도 참고 가능
            let josaRange = m.range(at: 2)

            guard josaRange.location != NSNotFound, josaRange.length > 0 else {
                return (out, canonRange)
            }

            let oldJosa = ns.substring(with: josaRange)
            let josaCandidate: String? = oldJosa.isEmpty ? nil : oldJosa

            // 기존 chooseJosa 로직을 그대로 사용
            let newJosa = chooseJosa(
                for: josaCandidate,
                baseHasBatchim: baseHasBatchim,
                baseIsRieul: baseIsRieul
            )

            // 변경 필요 없으면 그대로
            if newJosa == oldJosa {
                return (out, canonRange)
            }

            // gap은 유지하고, 조사 구간만 교체
            let ns2 = out as NSString
            out = ns2.replacingCharacters(in: josaRange, with: newJosa)

            // canonical 앞쪽은 건드리지 않았으므로 canonRange는 그대로 유효
            return (out, canonRange)
    }

    // 이름 매핑
    private func canonicalFor(_ matched: String, entries: [NameGlossary], nameUsage: inout [String: Int]) -> String {
        if let direct = entries.first(where: { $0.target == matched }) {
            let t = direct.target
            nameUsage[t, default: 0] += 1
            return t
        }
        
        var candidates: [NameGlossary] = []
        for e in entries {
            for v in e.variants {
                if v == matched {
                    candidates.append(e)
                    break
                }
            }
        }
        
        guard !candidates.isEmpty else { return matched }
        
        if candidates.count == 1 {
            let t = candidates[0].target
            nameUsage[t, default: 0] += 1
            return t
        }
        
        let chosen = candidates.min { lhs, rhs in
            let usedL = nameUsage[lhs.target] ?? 0
            let usedR = nameUsage[rhs.target] ?? 0
            let expL = max(lhs.expectedCount, 1)
            let expR = max(rhs.expectedCount, 1)

            let ratioL = Double(usedL) / Double(expL)
            let ratioR = Double(usedR) / Double(expR)
            
            if ratioL == ratioR {
                // 비율이 같으면 target 문자열 사전순으로 안정화
                return lhs.target < rhs.target
            }
            return ratioL < ratioR
        }!
        
        let t = chosen.target
        nameUsage[t, default: 0] += 1
        return t
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
