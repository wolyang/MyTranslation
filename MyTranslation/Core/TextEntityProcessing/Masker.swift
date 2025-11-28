//
//  TermMasker.swift
//  MyTranslation
//

import Foundation

// MARK: - Term-only Masker

public final class TermMasker {
    private let termMatcher = SegmentTermMatcher()
    private let entriesBuilder = SegmentEntriesBuilder()
    private let piecesBuilder = SegmentPiecesBuilder()
    

    public init() { }

    private func makeComponentTerm(
        from appearedTerm: AppearedTerm,
        source: String
    ) -> GlossaryEntry.ComponentTerm {
        GlossaryEntry.ComponentTerm(
            key: appearedTerm.key,
            target: appearedTerm.target,
            variants: appearedTerm.variants,
            source: source
        )
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
    
    /// 주어진 entries에서 사용된 모든 Term 키를 수집한다.
    /// - Parameter entries: GlossaryEntry 배열
    /// - Returns: Entry에 포함된 모든 Term 키의 집합
    // MARK: - V2 SegmentPieces 생성 (raw matched terms)

    func buildSegmentPieces(
        segment: Segment,
        matchedTerms: [Glossary.SDModel.SDTerm],
        patterns: [Glossary.SDModel.SDPattern],
        matchedSources: [String: Set<String>]
    ) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry]) {
        let text = segment.originalText

        guard text.isEmpty == false, matchedTerms.isEmpty == false else {
            return (
                pieces: SegmentPieces(
                    segmentID: segment.id,
                    originalText: text,
                    pieces: [.text(text, range: text.startIndex..<text.endIndex)]
                ),
                glossaryEntries: []
            )
        }

        var usedTermKeys: Set<String> = []
        var sourceToEntry: [String: GlossaryEntry] = [:]

        // Phase 0: 등장 + 비활성화 필터링
        let appearedTerms: [AppearedTerm] = termMatcher.findAppearedTerms(
            segmentText: text,
            matchedTerms: matchedTerms,
            matchedSources: matchedSources
        )

        // Phase 1: Standalone Activation
        for appearedTerm in appearedTerms {
            let matchedSet = matchedSources[appearedTerm.key] ?? []
            for source in appearedTerm.appearedSources where source.prohibitStandalone == false {
                sourceToEntry[source.text] = GlossaryEntry(
                    source: source.text,
                    target: appearedTerm.target,
                    variants: appearedTerm.variants,
                    preMask: appearedTerm.preMask,
                    isAppellation: appearedTerm.isAppellation,
                    origin: .termStandalone(termKey: appearedTerm.key),
                    componentTerms: [
                        makeComponentTerm(
                            from: appearedTerm,
                            source: source.text
                        )
                    ]
                )
                usedTermKeys.insert(appearedTerm.key)
            }
        }

        // Phase 2: Term-to-Term Activation
        for appearedTerm in appearedTerms where !usedTermKeys.contains(appearedTerm.key) {
            let activatorKeys = Set(appearedTerm.activators.map { $0.key })
            guard !activatorKeys.isEmpty && !activatorKeys.isDisjoint(with: usedTermKeys) else {
                continue
            }
            
            for source in appearedTerm.appearedSources where source.prohibitStandalone {
                sourceToEntry[source.text] = GlossaryEntry(
                    source: source.text,
                    target: appearedTerm.target,
                    variants: appearedTerm.variants,
                    preMask: appearedTerm.preMask,
                    isAppellation: appearedTerm.isAppellation,
                    origin: .termStandalone(termKey: appearedTerm.key),
                    componentTerms: [
                        makeComponentTerm(
                            from: appearedTerm,
                            source: source.text
                        )
                    ]
                )
            }

            usedTermKeys.insert(appearedTerm.key)
        }

        // Phase 3: Composer Entries
        let composerEntries = entriesBuilder.buildComposerEntries(
            patterns: patterns,
            appearedTerms: appearedTerms,
            segmentText: text
        )
        for entry in composerEntries where sourceToEntry[entry.source] == nil {
            sourceToEntry[entry.source] = entry
        }

        // Phase 4: Longest-first Segmentation
        let segmentPieces = piecesBuilder.buildSegmentPieces(
            segmentText: text,
            segmentID: segment.id,
            sourceToEntry: sourceToEntry
        )

        return (pieces: segmentPieces, glossaryEntries: Array(sourceToEntry.values))
    }

    /// 원문에 등장한 인물 용어만 선별하여 정규화용 이름 정보를 생성한다.
    /// - Parameters:
    ///   - original: 용어 검사를 수행할 원문 텍스트
    ///   - entries: 용어집 엔트리 목록
    /// - Returns: 원문에 등장한 인물 용어의 target/variants 정보 배열
    func makeNameGlossaries(seg: Segment, entries: [GlossaryEntry]) -> [NameGlossary] {
        let original = seg.originalText
        guard !original.isEmpty else { return [] }

        // 단순화: 이미 활성화된 엔트리 목록을 그대로 사용
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
                if case .term(let e, _) = $0, e.target == target {
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

    // MARK: - 순서 기반 정규화/언마스킹 헬퍼

    private func makeCandidates(target: String, variants: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in [target] + variants {
            guard candidate.isEmpty == false else { continue }
            // 알파벳 variants는 대소문자 차이만 제거해 하나로 통합한다.
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

        // 1) 순서 기반 검색부터 시도
        for candidate in candidates {
            if let range = text.range(of: candidate, options: [.caseInsensitive], range: startIndex..<text.endIndex) {
                return (candidate, range)
            }
        }
        // 2) 실패 시 전체 검색으로 완화 (Phase 3 전역 검색 전에 한 번만 수행)
        for candidate in candidates {
            if let range = text.range(of: candidate, options: [.caseInsensitive]) {
                return (candidate, range)
            }
        }
        return nil
    }

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

    private static let tokenNumberRegex = try? NSRegularExpression(pattern: "(?i)E#(\\d+)")

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

    // MARK: - 순서 기반 정규화/언마스킹

    func normalizeWithOrder(
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
        var cumulativeDelta: Int = 0  // 정규화로 길이가 달라진 누적 분량을 추적
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

        // Phase 1: target + variants 순서 기반 매칭
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

            let result = replaceWithParticleFix(
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

        // Phase 2: Pattern fallback 순서 기반 매칭
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

                let result = replaceWithParticleFix(
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

        // Phase 3: 전역 검색 Fallback (기존 로직 재사용)
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

        // Phase 4: 잔여 일괄 교체 (보호 범위 포함)
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
            // 역순 교체에 기대어 location >= position 인 영역만 델타 보정한다.
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
                // 단문(1글자) 변형은 Phase 4에서 건너뛴다.
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

                // 뒤에서부터 교체해 앞선 NSRange가 무효화되지 않도록 한다.
                for nsRange in matches.reversed() {
                    guard let swiftRange = Range(nsRange, in: out) else { continue }
                    let before = out
                    let result = replaceWithParticleFix(
                        in: out,
                        range: swiftRange,
                        replacement: replacement
                    )
                    // 문자열 길이 변화를 기록해 이후 하이라이트 오프셋을 보정한다.
                    let delta = (result.text as NSString).length - (before as NSString).length
                    out = result.text
                    if delta != 0 {
                        let threshold = nsRange.location + nsRange.length
                        shiftRanges(after: threshold, delta: delta)
                    }
                    
                    if let replacedRange = result.replacedRange {
                        let nsReplaced = NSRange(replacedRange, in: out)
                        if nsReplaced.location != NSNotFound {
                            normalizedOffsets.append(.init(entry: entry, nsRange: nsReplaced, type: .normalized))
                            protectedRanges.append(nsReplaced)
                        }
                    }
                }
            }
        }

        for targetName in processedTargets {
            guard let name = nameByTarget[targetName],
                  let entry = entryByTarget[targetName] else { continue }

            handleVariants([name.target] + name.variants, replacement: name.target, entry: entry)

            if let fallbacks = name.fallbackTerms,
               let matched = matchedVariantsByTarget[targetName] {
                for fallback in fallbacks {
                    let fallbackSet = Set([fallback.target] + fallback.variants)
                    let matchedFallbacks = matched.intersection(fallbackSet)
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

// 마스킹하지 않은 용어집 정규화 + range 추적 버전
    /// 정규화 텍스트와 원본 사이 길이 차를 고려하며 변형 정규화 range를 추적한다.
    func normalizeVariantsAndParticles(
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

            // preNormalized 범위는 교체 전 원본 텍스트 기준으로 계산
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
            localDelta += (fixedRange.length - r.length) // 이후 매칭 offset 보정을 위한 누적치
            matchedVariants[entry.target, default: []].insert(found)
        }

        return (out, ranges, preNormalizedRanges, matchedVariants)
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
