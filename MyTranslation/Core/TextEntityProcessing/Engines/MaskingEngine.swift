//
//  MaskingEngine.swift
//  MyTranslation
//

import Foundation

public final class MaskingEngine {
    public var tokenSpacingBehavior: TokenSpacingBehavior = .disabled
    private var nextIndex: Int = 1

    private static let tokenRegexPattern: String = #"__(?:[^_]|_(?!_))+__"#
    private var tokenRegex: String { Self.tokenRegexPattern }
    private static let tokenNumberRegex = try? NSRegularExpression(pattern: "(?i)E#(\\d+)")

    public init() { }

    // MARK: - Token helpers

    private static func makeToken(prefix: String, index: Int) -> String {
        "__\(prefix)#\(index)__"
    }

    @inline(__always)
    private func extractTokenIDs(from locks: [String: LockInfo]) -> Set<String> {
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

    private func sortedTokensByIndex(_ locks: [String: LockInfo]) -> [String] {
        func tokenNumber(_ token: String) -> Int? {
            guard let rx = Self.tokenNumberRegex else { return nil }
            guard let r = rx.firstMatch(in: token, options: [], range: NSRange(location: 0, length: (token as NSString).length))?.range(at: 1) else {
                return nil
            }
            let nsToken = token as NSString
            return Int(nsToken.substring(with: r))
        }

        return locks.keys.sorted { lhs, rhs in
            guard let l = tokenNumber(lhs), let r = tokenNumber(rhs) else {
                return lhs < rhs
            }
            return l < r
        }
    }

    // MARK: - Masking

    public func maskFromPieces(
        pieces: SegmentPieces,
        segment: Segment
    ) -> MaskedPack {
        var out = ""
        var locks: [String: LockInfo] = [:]
        var localNextIndex = self.nextIndex
        var tokenEntries: [String: GlossaryEntry] = [:]
        var maskedRanges: [TermRange] = []

        for piece in pieces.pieces {
            switch piece {
            case .text(let str, _):
                out += str
            case .term(let entry, _):
                if entry.preMask {
                    let token = Self.makeToken(prefix: "E", index: localNextIndex)
                    localNextIndex += 1
                    let tokenStart = out.endIndex
                    out += token

                    if entry.isAppellation {
                        out = surroundTokenWithNBSP(out, token: token)
                    }

                    let (b, r) = KoreanParticleRules.hangulFinalJongInfo(entry.target)
                    locks[token] = LockInfo(
                        placeholder: token,
                        target: entry.target,
                        endsWithBatchim: b,
                        endsWithRieul: r,
                        isAppellation: entry.isAppellation
                    )
                    tokenEntries[token] = entry

                    if let range = out.range(of: token, options: .backwards) {
                        maskedRanges.append(.init(entry: entry, range: range, type: .masked))
                    } else {
                        let end = out.index(tokenStart, offsetBy: token.count)
                        maskedRanges.append(.init(entry: entry, range: tokenStart..<end, type: .masked))
                    }
                } else {
                    let start = out.endIndex
                    out += entry.source
                    let end = out.endIndex
                    maskedRanges.append(.init(entry: entry, range: start..<end, type: .normalized))
                }
            }
        }

        out = insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(out)
        self.nextIndex = localNextIndex
        return .init(
            seg: segment,
            masked: out,
            tags: [],
            locks: locks,
            tokenEntries: tokenEntries,
            maskedRanges: maskedRanges
        )
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
                     0xAC00 ... 0xD7A3:
                    return true
                default:
                    continue
                }
            }
            return false
        }

        func isLatinOrDigit(_ c: Character?) -> Bool {
            guard let c = c else { return false }
            return c.isWholeNumber || ("A"..."z").contains(c)
        }

        var out = text

        var searchStart = out.startIndex
        while let r = out.range(of: token, options: [], range: searchStart..<out.endIndex) {
            let beforeCh = (r.lowerBound > out.startIndex) ? out[out.index(before: r.lowerBound)] : nil
            let afterCh  = (r.upperBound < out.endIndex) ? out[r.upperBound] : nil

            var needLeftNBSP = false
            var needRightNBSP = false
            var forbidRightNBSP = false

            if isBoundary(beforeCh) {
                needLeftNBSP = false
            } else if isCJKCharacter(beforeCh) {
                needLeftNBSP = true
            } else if isLetterLike(beforeCh) {
                let hasPrevBoundary = sentenceBoundaryCharacters.contains(beforeCh!)
                needLeftNBSP = hasPrevBoundary
            }

            if isBoundary(afterCh) {
                needRightNBSP = false
                if sentenceBoundaryCharacters.contains(afterCh ?? " ") {
                    forbidRightNBSP = true
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
            let rest = stripRx.stringByReplacingMatches(in: p, range: NSRange(p.startIndex..., in: p), withTemplate: "")
            guard rest.isPunctOrSpaceOnly else {
                outParas.append(p)
                continue
            }

            var q = p
            q = leftRx.stringByReplacingMatches(in: q, range: NSRange(q.startIndex..., in: q), withTemplate: " $1")
            q = rightRx.stringByReplacingMatches(in: q, range: NSRange(q.startIndex..., in: q), withTemplate: "$0 ")

            outParas.append(q)
        }

        return outParas.joined(separator: "\n")
    }

    // MARK: - Unmasking

    public struct ReplacementDelta {
        public let offset: Int
        public let delta: Int
    }

    public func unlockTermsSafely(_ text: String, locks: [String: LockInfo]) -> String {
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

    public func unmaskWithOrder(
        in text: String,
        pieces: SegmentPieces,
        locksByToken: [String: LockInfo],
        tokenEntries: [String: GlossaryEntry]
    ) -> (text: String, ranges: [TermRange], deltas: [ReplacementDelta]) {
        guard text.isEmpty == false else { return (text, [], []) }
        guard locksByToken.isEmpty == false else { return (text, [], []) }

        var out = text.precomposedStringWithCompatibilityMapping
        var ranges: [TermRange] = []
        var deltas: [ReplacementDelta] = []
        let tokensInOrder = sortedTokensByIndex(locksByToken)
        var tokenCursor: Int = 0
        var lastMatchUpperBound: String.Index? = nil

        let maskedTerms: [GlossaryEntry] = pieces.pieces.compactMap { piece in
            if case .term(let entry, _) = piece, entry.preMask {
                return entry
            }
            return nil
        }

        while tokenCursor < maskedTerms.count, tokenCursor < tokensInOrder.count {
            let token = tokensInOrder[tokenCursor]
            tokenCursor += 1
            guard let lock = locksByToken[token] else { continue }

            let start = lastMatchUpperBound ?? out.startIndex
            let range = out.range(of: token, options: [], range: start..<out.endIndex)
                ?? out.range(of: token, options: [])
            guard let tokenRange = range else { continue }

            let lowerOffset = out.distance(from: out.startIndex, to: tokenRange.lowerBound)
            let oldLen = out.distance(from: tokenRange.lowerBound, to: tokenRange.upperBound)

            let result = replaceWithParticleFix(
                in: out,
                range: tokenRange,
                replacement: lock.target,
                baseHasBatchim: lock.endsWithBatchim,
                baseIsRieul: lock.endsWithRieul
            )
            out = result.text
            lastMatchUpperBound = result.nextIndex
            let newLen = out.distance(from: out.index(out.startIndex, offsetBy: lowerOffset), to: result.nextIndex)
            deltas.append(.init(offset: lowerOffset, delta: newLen - oldLen))
            if let replacedRange = result.replacedRange {
                if let entry = tokenEntries[token] ?? maskedTerms.first {
                    ranges.append(.init(entry: entry, range: replacedRange, type: .masked))
                }
            }
        }

        let processedTokens = Set(tokensInOrder.prefix(tokenCursor))
        let remainingLocks = locksByToken.filter { processedTokens.contains($0.key) == false }
        if remainingLocks.isEmpty == false {
            out = normalizeTokensAndParticles(in: out, locksByToken: remainingLocks)
        }
        return (out, ranges, deltas)
    }

    public func normalizeTokensAndParticles(
        in text: String,
        locksByToken: [String: LockInfo]
    ) -> String {
        let textNFC = text.precomposedStringWithCompatibilityMapping
        func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

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

        for r in matches.reversed() {
            let nsOut = out as NSString
            let token = nsOut.substring(with: r)
            guard let lock = locksByToken[token] else { continue }

            let canon = lock.target
            out = nsOut.replacingCharacters(in: r, with: canon)

            let canonRange = NSRange(location: r.location, length: (canon as NSString).length)
            let (fixed, _) = KoreanParticleRules.fixParticles(
                in: out,
                afterCanonical: canonRange,
                baseHasBatchim: lock.endsWithBatchim,
                baseIsRieul: lock.endsWithRieul
            )
            out = fixed
        }

        return out
    }

    public func normalizeDamagedETokens(_ text: String, locks: [String: LockInfo]) -> String {
        let validIDs = extractTokenIDs(from: locks)

        let ws = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*"
        let d  = "([0-9０-９]+)"

        let rxA = try! NSRegularExpression(pattern: "(?i)_{2}" + ws + "E" + ws + "#" + ws + d + ws + "_{2}")
        let rxB0 = try! NSRegularExpression(pattern: "(?i)(?<!_)E#" + d + "_?__?(?!_)")
        let rxB  = try! NSRegularExpression(pattern: "(?i)(?<!_)_?__?E#" + d + "_?__?(?!_)")
        let rxB1 = try! NSRegularExpression(pattern: "(?i)(?<!_)_?__?E#" + d + "(?![A-Za-z0-9_])")
        let rxB2 = try! NSRegularExpression(pattern: "(?i)(?<!_)E#" + d + "(?![A-Za-z0-9_])")

        @inline(__always)
        func halfwidth(_ s: String) -> String {
            s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        }

        var out = text

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

        return out
    }

    // MARK: - Helpers

    private func replaceWithParticleFix(
        in text: String,
        range: Range<String.Index>,
        replacement: String,
        baseHasBatchim: Bool? = nil,
        baseIsRieul: Bool? = nil
    ) -> (text: String, replacedRange: Range<String.Index>?, nextIndex: String.Index) {
        let nsRange = NSRange(range, in: text)
        let replaced = (text as NSString).replacingCharacters(in: nsRange, with: replacement)

        let canonicalRange = NSRange(location: nsRange.location, length: (replacement as NSString).length)
        let jongInfo = KoreanParticleRules.hangulFinalJongInfo(replacement)
        let (fixed, fixedRange) = KoreanParticleRules.fixParticles(
            in: replaced,
            afterCanonical: canonicalRange,
            baseHasBatchim: baseHasBatchim ?? jongInfo.hasBatchim,
            baseIsRieul: baseIsRieul ?? jongInfo.isRieul
        )

        if let swiftRange = Range(fixedRange, in: fixed) {
            return (fixed, swiftRange, swiftRange.upperBound)
        }
        return (fixed, nil, fixed.endIndex)
    }
}
