//
//  NormalizationEngine.swift
//  MyTranslation
//

import Foundation

public struct NormalizationEngine {
    public init() { }

    // MARK: - Name glossaries

    public func makeNameGlossories(seg: Segment, entries: [GlossaryEntry]) -> [NameGlossary] {
        let original = seg.originalText
        guard !original.isEmpty else { return [] }

        let allowedEntries = filterBySourceOcc(seg, entries)

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

            let occ = original.components(separatedBy: source).count - 1
            if occ > 0 {
                expectedCountsByTarget[entry.target, default: 0] += occ
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

    public func makeNameGlossariesFromPieces(
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
                if case .term(let e, _) = $0, e.target == target {
                    return true
                }
                return false
            }.count
            expectedCountsByTarget[target, default: 0] += count

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

    // MARK: - Normalization

    public func normalizeWithOrder(
        in text: String,
        pieces: SegmentPieces,
        nameGlossaries: [NameGlossary]
    ) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange]) {
        guard text.isEmpty == false else { return (text, [], []) }
        guard nameGlossaries.isEmpty == false else { return (text, [], []) }

        let original = text.precomposedStringWithCompatibilityMapping
        var out = original
        var ranges: [TermRange] = []
        var preNormalizedRanges: [TermRange] = []
        let nameByTarget = Dictionary(nameGlossaries.map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
        let entryByTarget = Dictionary(
            pieces.unmaskedTerms().map { ($0.target, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var processed: Set<Int> = []
        var lastMatchUpperBound: String.Index? = nil
        var phase2LastMatch: String.Index? = nil
        var cumulativeDelta: Int = 0
        var matchedVariantsByTarget: [String: Set<String>] = [:]

        func recordMatchedVariant(target: String, variant: String) {
            guard variant.isEmpty == false else { return }
            matchedVariantsByTarget[target, default: []].insert(variant)
        }

        let unmaskedTerms: [(index: Int, entry: GlossaryEntry)] = pieces.pieces.enumerated().compactMap { idx, piece in
            if case .term(let entry, _) = piece, entry.preMask == false {
                return (index: idx, entry: entry)
            }
            return nil
        }

        for (index, entry) in unmaskedTerms {
            guard let name = nameByTarget[entry.target] else { continue }
            let candidates = makeCandidates(target: name.target, variants: name.variants)
            guard let matched = findNextCandidate(
                in: out,
                candidates: candidates,
                startIndex: lastMatchUpperBound ?? out.startIndex
            ) else { continue }

            recordMatchedVariant(target: entry.target, variant: matched.candidate)

            let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
            let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
            let originalLower = lowerOffset - cumulativeDelta
            if originalLower >= 0, originalLower + oldLen <= original.count {
                let lower = original.index(original.startIndex, offsetBy: originalLower)
                let upper = original.index(lower, offsetBy: oldLen)
                preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
            }

            let result = KoreanParticleRules.replaceWithParticleFix(
                in: out,
                range: matched.range,
                replacement: name.target
            )
            out = result.text
            lastMatchUpperBound = result.nextIndex
            if let range = result.replacedRange {
                ranges.append(.init(entry: entry, range: range, type: .normalized))
            }
            let newLen: Int
            if let replacedRange = result.replacedRange {
                newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
            } else {
                newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
            }
            cumulativeDelta += (newLen - oldLen)
            processed.insert(index)
        }

        for (index, entry) in unmaskedTerms where processed.contains(index) == false {
            guard let name = nameByTarget[entry.target],
                  let fallbacks = name.fallbackTerms else { continue }

            for fallback in fallbacks {
                let candidates = makeCandidates(target: fallback.target, variants: fallback.variants)
                guard let matched = findNextCandidate(
                    in: out,
                    candidates: candidates,
                    startIndex: phase2LastMatch ?? out.startIndex
                ) else { continue }

                recordMatchedVariant(target: entry.target, variant: matched.candidate)

                let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
                let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
                let originalLower = lowerOffset - cumulativeDelta
                if originalLower >= 0, originalLower + oldLen <= original.count {
                    let lower = original.index(original.startIndex, offsetBy: originalLower)
                    let upper = original.index(lower, offsetBy: oldLen)
                    preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
                }

                let result = KoreanParticleRules.replaceWithParticleFix(
                    in: out,
                    range: matched.range,
                    replacement: fallback.target
                )
                out = result.text
                phase2LastMatch = result.nextIndex
                if let range = result.replacedRange {
                    ranges.append(.init(entry: entry, range: range, type: .normalized))
                }
                let newLen: Int
                if let replacedRange = result.replacedRange {
                    newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
                } else {
                    newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
                }
                cumulativeDelta += (newLen - oldLen)
                processed.insert(index)
                break
            }
        }

        let remainingTargets = Set(
            unmaskedTerms
                .filter { processed.contains($0.index) == false }
                .map { $0.entry.target }
        )
        let remainingGlossaries = nameGlossaries.filter { remainingTargets.contains($0.target) }
        if remainingGlossaries.isEmpty == false {
            let mappedEntries = remainingGlossaries.compactMap { g -> (NameGlossary, GlossaryEntry)? in
                guard let entry = entryByTarget[g.target] else { return nil }
                return (g, entry)
            }
            if mappedEntries.isEmpty == false {
                let result = normalizeVariantsAndParticles(
                    in: out,
                    entries: mappedEntries,
                    baseText: original,
                    cumulativeDelta: cumulativeDelta
                )
                out = result.text
                ranges.append(contentsOf: result.ranges)
                preNormalizedRanges.append(contentsOf: result.preNormalizedRanges)
                for (target, variants) in result.matchedVariants {
                    for variant in variants {
                        recordMatchedVariant(target: target, variant: variant)
                    }
                }
            }
        }

        struct OffsetRange {
            let entry: GlossaryEntry
            var nsRange: NSRange
            let type: TermRange.TermType
        }

        var normalizedOffsets: [OffsetRange] = ranges.compactMap { termRange in
            let nsRange = NSRange(termRange.range, in: out)
            guard nsRange.location != NSNotFound else { return nil }
            return OffsetRange(entry: termRange.entry, nsRange: nsRange, type: termRange.type)
        }
        var protectedRanges: [NSRange] = normalizedOffsets.map { $0.nsRange }

        let processedTargetsFromOffsets = normalizedOffsets.map { $0.entry.target }
        let processedTargetsFromProcessed = processed.compactMap { idx -> String? in
            guard idx < pieces.pieces.count else { return nil }
            guard case .term(let entry, _) = pieces.pieces[idx] else { return nil }
            return entry.target
        }
        let processedTargets = Set(processedTargetsFromOffsets + processedTargetsFromProcessed)

        func overlapsProtected(_ range: NSRange) -> Bool {
            return protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        func shiftRanges(after position: Int, delta: Int) {
            guard delta != 0 else { return }
            for idx in normalizedOffsets.indices where normalizedOffsets[idx].nsRange.location >= position {
                normalizedOffsets[idx].nsRange.location += delta
            }
            for idx in protectedRanges.indices where protectedRanges[idx].location >= position {
                protectedRanges[idx].location += delta
            }
        }

        func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry) {
            let sorted = variants.sorted { $0.count > $1.count }
            for variant in sorted where variant.isEmpty == false {
                guard variant.count > 1 else { continue }
                var matches: [NSRange] = []
                var searchStart = out.startIndex

                while searchStart < out.endIndex,
                      let found = out.range(of: variant, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
                    let nsRange = NSRange(found, in: out)
                    if overlapsProtected(nsRange) == false {
                        matches.append(nsRange)
                    }
                    searchStart = found.upperBound
                }

                for r in matches.reversed() {
                    if overlapsProtected(r) { continue }
                    let nsOut = out as NSString
                    let before = nsOut.substring(to: r.location)
                    let after = nsOut.substring(from: r.location + r.length)

                    if before.contains(replacement) || processedTargets.contains(replacement) {
                        continue
                    }

                    out = nsOut.replacingCharacters(in: r, with: replacement)
                    let delta = (replacement as NSString).length - r.length
                    let newRange = NSRange(location: r.location, length: (replacement as NSString).length)
                    normalizedOffsets.append(.init(entry: entry, nsRange: newRange, type: .normalized))
                    protectedRanges.append(newRange)
                    shiftRanges(after: r.location, delta: delta)
                }
            }
        }

        for target in matchedVariantsByTarget.keys {
            guard processedTargets.contains(target),
                  let name = nameByTarget[target],
                  let entry = entryByTarget[target] else { continue }

            handleVariants(Array(matchedVariantsByTarget[target] ?? []), replacement: name.target, entry: entry)

            if let fallbacks = name.fallbackTerms {
                for fallback in fallbacks {
                    let fallbackSet = Set([fallback.target] + fallback.variants)
                    let matchedFallbacks = matchedVariantsByTarget[target]?.intersection(fallbackSet) ?? []
                    if matchedFallbacks.isEmpty == false {
                        handleVariants(Array(matchedFallbacks), replacement: fallback.target, entry: entry)
                    }
                }
            }
        }

        ranges = normalizedOffsets.compactMap { offset in
            guard let swiftRange = Range(offset.nsRange, in: out) else { return nil }
            return TermRange(entry: offset.entry, range: swiftRange, type: offset.type)
        }

        return (out, ranges, preNormalizedRanges)
    }

    public func normalizeVariantsAndParticles(
        in text: String,
        entries: [(NameGlossary, GlossaryEntry)],
        baseText: String,
        cumulativeDelta: Int
    ) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange], matchedVariants: [String: Set<String>]) {
        let textNFC = text.precomposedStringWithCompatibilityMapping
        let original = baseText.precomposedStringWithCompatibilityMapping
        func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

        var variantMap: [String: (canonical: String, entry: GlossaryEntry)] = [:]
        for (glossary, entry) in entries {
            let sortedVariants = glossary.variants.sorted { $0.count > $1.count }
            if variantMap[glossary.target] == nil { variantMap[glossary.target] = (glossary.target, entry) }
            for v in sortedVariants where !v.isEmpty {
                if variantMap[v] == nil { variantMap[v] = (glossary.target, entry) }
            }

            if let fallbacks = glossary.fallbackTerms {
                for fallback in fallbacks {
                    if variantMap[fallback.target] == nil {
                        variantMap[fallback.target] = (fallback.target, entry)
                    }
                    let sorted = fallback.variants.sorted { $0.count > $1.count }
                    for v in sorted where !v.isEmpty {
                        if variantMap[v] == nil {
                            variantMap[v] = (fallback.target, entry)
                        }
                    }
                }
            }
        }

        let allVariants = Array(variantMap.keys)
        if allVariants.isEmpty { return (text, [], [], [:]) }

        let alts = allVariants.map(esc).sorted { $0.count > $1.count }.joined(separator: "|")
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

        var ranges: [TermRange] = []
        var preNormalizedRanges: [TermRange] = []
        var matchedVariants: [String: Set<String>] = [:]
        var localDelta = cumulativeDelta

        for r in matches.reversed() {
            let nsOut = out as NSString
            let found = nsOut.substring(with: r)
            guard let mapping = variantMap[found] else { continue }
            let canon = mapping.canonical
            let entry = mapping.entry
            let (has, rieul) = KoreanParticleRules.hangulFinalJongInfo(canon)

            let originalLower = r.location - localDelta
            if originalLower >= 0, originalLower + r.length <= (original as NSString).length {
                let lower = original.index(original.startIndex, offsetBy: originalLower)
                let upper = original.index(lower, offsetBy: r.length)
                preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
            }

            out = nsOut.replacingCharacters(in: r, with: canon)

            let canonRange = NSRange(location: r.location, length: (canon as NSString).length)
            let (fixed, fixedRange) = KoreanParticleRules.fixParticles(
                in: out,
                afterCanonical: canonRange,
                baseHasBatchim: has,
                baseIsRieul: rieul
            )
            out = fixed

            if let swiftRange = Range(fixedRange, in: out) {
                ranges.append(.init(entry: entry, range: swiftRange, type: .normalized))
            }
            localDelta += (fixedRange.length - r.length)
            matchedVariants[entry.target, default: []].insert(found)
        }

        return (out, ranges, preNormalizedRanges, matchedVariants)
    }

    // MARK: - Helpers

    private func makeCandidates(target: String, variants: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in [target] + variants {
            guard candidate.isEmpty == false else { continue }
            let key: String
            if candidate.rangeOfCharacter(from: .letters) != nil {
                key = candidate.lowercased()
            } else {
                key = candidate
            }
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result.sorted { $0.count > $1.count }
    }

    private func findNextCandidate(
        in text: String,
        candidates: [String],
        startIndex: String.Index
    ) -> (candidate: String, range: Range<String.Index>)? {
        guard candidates.isEmpty == false else { return nil }

        for candidate in candidates {
            if let range = text.range(of: candidate, options: [.caseInsensitive], range: startIndex..<text.endIndex) {
                return (candidate, range)
            }
        }
        for candidate in candidates {
            if let range = text.range(of: candidate, options: [.caseInsensitive]) {
                return (candidate, range)
            }
        }
        return nil
    }

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
                return lhs.target < rhs.target
            }
            return ratioL < ratioR
        }!

        let t = chosen.target
        nameUsage[t, default: 0] += 1
        return t
    }

    private func filterBySourceOcc(_ seg: Segment, _ allowedEntries: [GlossaryEntry]) -> [GlossaryEntry] {
        let normalizedOriginal = seg.originalText
        struct SourceOcc {
            let entry: GlossaryEntry
            let normSource: String
            let length: Int
            let positions: [Int]
        }

        var occList: [SourceOcc] = []
        for e in allowedEntries {
            guard !e.target.isEmpty else { continue }
            let normSource = e.source
            let positions = allOccurrences(of: normSource, in: normalizedOriginal)
            guard !positions.isEmpty else { continue }
            occList.append(SourceOcc(entry: e, normSource: normSource, length: normSource.count, positions: positions))
        }

        guard occList.isEmpty == false else { return [] }

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
                    hasIndependentUse = true
                    break
                }
            }

            if hasIndependentUse == false {
                keepFlags[i] = false
            }
        }

        let filteredEntries: [GlossaryEntry] = occList.enumerated()
            .compactMap { idx, s in keepFlags[idx] ? s.entry : nil }
        return filteredEntries
    }

    private func allOccurrences(of needle: String, in hay: String) -> [Int] {
        guard !needle.isEmpty, !hay.isEmpty else { return [] }
        var out: [Int] = []; var from = hay.startIndex
        while from < hay.endIndex, let r = hay.range(of: needle, range: from..<hay.endIndex) {
            out.append(hay.distance(from: hay.startIndex, to: r.lowerBound))
            from = hay.index(after: r.lowerBound)
        }
        return out
    }
}
