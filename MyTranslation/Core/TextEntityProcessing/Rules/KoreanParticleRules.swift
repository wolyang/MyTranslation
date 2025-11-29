//
//  KoreanParticleRules.swift
//  MyTranslation
//

import Foundation

public enum KoreanParticleRules {
    public struct JosaPair {
        public let noBatchim: String
        public let withBatchim: String
        public let rieulException: Bool
        public let prefersWithBatchimWhenAuxAttached: Bool

        public init(
            noBatchim: String,
            withBatchim: String,
            rieulException: Bool,
            prefersWithBatchimWhenAuxAttached: Bool
        ) {
            self.noBatchim = noBatchim
            self.withBatchim = withBatchim
            self.rieulException = rieulException
            self.prefersWithBatchimWhenAuxAttached = prefersWithBatchimWhenAuxAttached
        }
    }

    // 최소 세트 (필요 시 확장)
    private static let josaPairs: [JosaPair] = [
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

    private static let caseSingleParticles: Set<String> = [
        "에", "에서", "에게", "에게서", "와", "과", "랑", "하고",
        "께", "께서", "보다", "처럼", "같이", "로서", "으로서",
        "로써", "으로써", "의"
    ]

    private static let auxiliaryParticles: Set<String> = [
        "만", "도", "까지", "부터", "조차", "마저", "밖에", "뿐",
        "나", "이나", "나마", "이나마"
    ]

    private static let pairFormsByString: [String: (index: Int, isWithBatchim: Bool)] = {
        var dict: [String: (Int, Bool)] = [:]
        for (idx, pair) in josaPairs.enumerated() {
            dict[pair.noBatchim] = (idx, false)
            dict[pair.withBatchim] = (idx, true)
        }
        return dict
    }()

    private static let particleTokenAlternation: String = {
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

    private static let particleTokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: particleTokenAlternation, options: [])
    }()

    private static let particleWhitespaceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "(?:\\s|\\u00A0)+", options: [])
    }()

    private static let cjkOrWord = "[\\p{Han}\\p{Hiragana}\\p{Katakana}ァ-ン一-龥ぁ-んA-Za-z0-9_]"
    private static let wsClass = #"(?:\s|\u00A0|\u202F|\u2009|\u200A|\u200B|\u205F|\u3000)+"#

    @inline(__always)
    public static func hangulFinalJongInfo(_ s: String) -> (hasBatchim: Bool, isRieul: Bool) {
        guard let last = s.unicodeScalars.last else { return (false, false) }
        let v = Int(last.value)
        guard (0xAC00 ... 0xD7A3).contains(v) else { return (false, false) }
        let idx = v - 0xAC00
        let jong = idx % 28
        if jong == 0 { return (false, false) }
        return (true, jong == 8)
    }

    public static func chooseJosa(for candidate: String?, baseHasBatchim: Bool, baseIsRieul: Bool) -> String {
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
            if lo+1 <= hi-1 {
                for i in (lo+1)...(hi-1) {
                    if isWhitespace.indices.contains(i), isWhitespace[i] { return false }
                }
            }
            return true
        }

        func hasAuxAdjacent(_ tokenIndex: Int) -> Bool {
            if tokenIndex > 0 {
                let left = tokens[tokenIndex - 1]
                if case .auxiliary = left.kind,
                   noWhitespaceBetween(left.segmentIndex, tokens[tokenIndex].segmentIndex) {
                    return true
                }
            }
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

        if !changed { return cand }
        return resultSegments.joined()
    }

    public static func chooseJosa(basedOn base: String, pair: JosaPair) -> String {
        let info = hangulFinalJongInfo(base)
        if pair.rieulException && info.isRieul {
            return pair.noBatchim
        }
        return info.hasBatchim ? pair.withBatchim : pair.noBatchim
    }

    public static func fixParticles(
        in text: String,
        afterCanonical canonRange: NSRange,
        baseHasBatchim: Bool,
        baseIsRieul: Bool
    ) -> (String, NSRange) {
        var out = text
        let ns = out as NSString

        let canonEnd = canonRange.location + canonRange.length
        guard canonEnd < ns.length else {
            return (out, canonRange)
        }

        let tailRange = NSRange(location: canonEnd, length: ns.length - canonEnd)

        let wsZ = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*"
        let softPunct = "[\"'“”’»«》〈〉〉》」』】）\\)\\]\\}]"
        let gap = "(?:" + wsZ + "(?:" + softPunct + ")?" + wsZ + ")"

        let particleTokenAlt = "(?:" + particleTokenAlternation + ")"
        let josaJoin = ""
        let josaSequence = particleTokenAlt + "(?:" + josaJoin + particleTokenAlt + ")*"

        let pattern = "^(" + gap + ")(" + josaSequence + ")"

        guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (out, canonRange)
        }

        guard let m = rx.firstMatch(in: out, options: [.anchored], range: tailRange) else {
            return (out, canonRange)
        }

        let josaRange = m.range(at: 2)

        guard josaRange.location != NSNotFound, josaRange.length > 0 else {
            return (out, canonRange)
        }

        let oldJosa = ns.substring(with: josaRange)
        let josaCandidate: String? = oldJosa.isEmpty ? nil : oldJosa

        if josaRange.length == 1, oldJosa == "이" {
            let afterJosaIndex = josaRange.location + josaRange.length
            if afterJosaIndex < ns.length {
                let nextRange = ns.rangeOfComposedCharacterSequence(at: afterJosaIndex)
                let next = ns.substring(with: nextRange)
                let hangulSet = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
                let nextIsHangul = next.unicodeScalars.contains { hangulSet.contains($0) }
                if next.range(of: cjkOrWord, options: .regularExpression) != nil || nextIsHangul {
                    return (out, canonRange)
                }
            }
        }

        let newJosa = chooseJosa(
            for: josaCandidate,
            baseHasBatchim: baseHasBatchim,
            baseIsRieul: baseIsRieul
        )

        if newJosa == oldJosa {
            return (out, canonRange)
        }

        let ns2 = out as NSString
        out = ns2.replacingCharacters(in: josaRange, with: newJosa)

        return (out, canonRange)
    }

    public static func collapseSpaces_PunctOrEdge_whenIsolatedSegment(_ s: String, target: String) -> String {
        guard !target.isEmpty else { return s }

        guard s.contains(target) else { return s }
        let rest = s.replacingOccurrences(of: target, with: "")
        guard rest.isPunctOrSpaceOnly_loose else { return s }

        let name = NSRegularExpression.escapedPattern(for: target)
        var out = s

        out = try! NSRegularExpression(
            pattern: #"(?<=[\p{P}\p{S}])\#(wsClass)(?<tok>\#(name))\#(wsClass)(?=[\p{P}\p{S}])"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        out = try! NSRegularExpression(
            pattern: #"(?<=[\p{P}\p{S}])\#(wsClass)(?<tok>\#(name))"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        out = try! NSRegularExpression(
            pattern: #"(?<tok>\#(name))\#(wsClass)(?=[\p{P}\p{S}])"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        out = try! NSRegularExpression(
            pattern: #"^\#(wsClass)(?<tok>\#(name))"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)
        out = try! NSRegularExpression(
            pattern: #"(?<tok>\#(name))\#(wsClass)$"#
        ).stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: target)

        return out
    }

    public static func replaceWithParticleFix(
        in text: String,
        range: Range<String.Index>,
        replacement: String,
        baseHasBatchim: Bool? = nil,
        baseIsRieul: Bool? = nil
    ) -> (text: String, replacedRange: Range<String.Index>?, nextIndex: String.Index) {
        let nsRange = NSRange(range, in: text)
        let replaced = (text as NSString).replacingCharacters(in: nsRange, with: replacement)

        let canonicalRange = NSRange(location: nsRange.location, length: (replacement as NSString).length)
        let jongInfo = hangulFinalJongInfo(replacement)
        let (fixed, fixedRange) = fixParticles(
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

extension String {
    var isPunctOrSpaceOnly: Bool {
        let set = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return unicodeScalars.allSatisfy { set.contains($0) }
    }

    var isPunctOrSpaceOnly_loose: Bool {
        let spaces = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{00A0}\u{202F}\u{2009}\u{200A}\u{200B}\u{205F}\u{3000}"))
        let set = CharacterSet.punctuationCharacters.union(.symbols).union(spaces)
        return unicodeScalars.allSatisfy { set.contains($0) }
    }
}
