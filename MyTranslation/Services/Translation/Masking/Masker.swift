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

    // MARK: - Appeared Term 모델

    struct AppearedTerm {
        let sdTerm: Glossary.SDModel.SDTerm
        let appearedSources: [Glossary.SDModel.SDSource]

        var key: String { sdTerm.key }
        var target: String { sdTerm.target }
        var variants: [String] { sdTerm.variants }
        var components: [Glossary.SDModel.SDComponent] { sdTerm.components }
        var preMask: Bool { sdTerm.preMask }
        var isAppellation: Bool { sdTerm.isAppellation }
        var activators: [Glossary.SDModel.SDTerm] { sdTerm.activators }
        var activates: [Glossary.SDModel.SDTerm] { sdTerm.activates }
    }

    struct AppearedComponent {
        let component: Glossary.SDModel.SDComponent
        let appearedTerm: AppearedTerm

        var pattern: String { component.pattern }
        var role: String? { component.role }
        var srcTplIdx: Int? { component.srcTplIdx }
        var tgtTplIdx: Int? { component.tgtTplIdx }
        var groupLinks: [Glossary.SDModel.SDComponentGroup] { component.groupLinks }
    }

    private func deactivatedContexts(of term: Glossary.SDModel.SDTerm) -> [String] {
        term.deactivatedIn
    }

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
        matchedSources: [String: Set<String>],
        termActivationFilter: TermActivationFilter
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

        var pieces: [SegmentPieces.Piece] = [.text(text, range: text.startIndex..<text.endIndex)]
        var usedTermKeys: Set<String> = []
        var sourceToEntry: [String: GlossaryEntry] = [:]

        // Phase 0: 등장 + 비활성화 필터링
        let appearedTerms: [AppearedTerm] = matchedTerms.compactMap { term in
            let matchedSourceTexts = matchedSources[term.key] ?? []
            let filteredSources = term.sources.filter { source in
                guard matchedSourceTexts.contains(source.text), text.contains(source.text) else { return false }
                return !termActivationFilter.shouldDeactivate(
                    source: source.text,
                    deactivatedIn: deactivatedContexts(of: term),
                    segmentText: text
                )
            }
            guard filteredSources.isEmpty == false else { return nil }
            return AppearedTerm(sdTerm: term, appearedSources: filteredSources)
        }

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
        let composerEntries = buildComposerEntries(
            patterns: patterns,
            appearedTerms: appearedTerms,
            segmentText: text
        )
        for entry in composerEntries where sourceToEntry[entry.source] == nil {
            sourceToEntry[entry.source] = entry
        }

        // Phase 4: Longest-first Segmentation
        let sortedSources = sourceToEntry.keys.sorted { $0.count > $1.count }

        for source in sortedSources {
            guard let entry = sourceToEntry[source] else { continue }
            var newPieces: [SegmentPieces.Piece] = []

            for piece in pieces {
                switch piece {
                case .text(let str, let pieceRange):
                    guard str.contains(source) else {
                        newPieces.append(.text(str, range: pieceRange))
                        continue
                    }

                    var searchStart = str.startIndex
                    while let foundRange = str.range(of: source, range: searchStart..<str.endIndex) {
                        if foundRange.lowerBound > searchStart {
                            let prefixLower = text.index(
                                pieceRange.lowerBound,
                                offsetBy: str.distance(from: str.startIndex, to: searchStart)
                            )
                            let prefixUpper = text.index(
                                pieceRange.lowerBound,
                                offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                            )
                            let prefix = String(str[searchStart..<foundRange.lowerBound])
                            newPieces.append(.text(prefix, range: prefixLower..<prefixUpper))
                        }

                        let originalLower = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                        )
                        let originalUpper = text.index(originalLower, offsetBy: source.count)
                        newPieces.append(.term(entry, range: originalLower..<originalUpper))

                        searchStart = foundRange.upperBound
                    }

                    if searchStart < str.endIndex {
                        let suffixLower = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: searchStart)
                        )
                        let suffix = String(str[searchStart...])
                        newPieces.append(.text(suffix, range: suffixLower..<pieceRange.upperBound))
                    }
                case .term:
                    newPieces.append(piece)
                }
            }

            pieces = newPieces
        }

        let segmentPieces = SegmentPieces(
            segmentID: segment.id,
            originalText: text,
            pieces: pieces
        )

        return (pieces: segmentPieces, glossaryEntries: Array(sourceToEntry.values))
    }

    private func buildComposerEntries(
        patterns: [Glossary.SDModel.SDPattern],
        appearedTerms: [AppearedTerm],
        segmentText: String
    ) -> [GlossaryEntry] {
        var allEntries: [GlossaryEntry] = []

        for pattern in patterns {
            let usesR = pattern.sourceTemplates.contains { $0.contains("{R}") }
                || pattern.targetTemplates.contains { $0.contains("{R}") }

            if usesR {
                let pairs = matchedPairs(for: pattern, appearedTerms: appearedTerms)
                allEntries.append(contentsOf: buildEntriesFromPairs(
                    pairs: pairs,
                    pattern: pattern,
                    segmentText: segmentText
                ))
            } else {
                let lefts = matchedLeftComponents(for: pattern, appearedTerms: appearedTerms)
                allEntries.append(contentsOf: buildEntriesFromLefts(
                    lefts: lefts,
                    pattern: pattern,
                    segmentText: segmentText
                ))
            }
        }

        return allEntries
    }

    private func matchedPairs(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [(AppearedComponent, AppearedComponent)] {
        var lefts: [AppearedComponent] = []
        var rights: [AppearedComponent] = []
        var hasAnyGroup = false

        for appearedTerm in appearedTerms {
            for component in appearedTerm.components where component.pattern == pattern.name {
                let isLeft = matchesRole(component.role, required: pattern.leftRole)
                let isRight = matchesRole(component.role, required: pattern.rightRole)

                if component.groupLinks.isEmpty == false { hasAnyGroup = true }

                let appearedComponent = AppearedComponent(component: component, appearedTerm: appearedTerm)
                if isLeft { lefts.append(appearedComponent) }
                if isRight { rights.append(appearedComponent) }
            }
        }

        if hasAnyGroup == false {
            var pairs: [(AppearedComponent, AppearedComponent)] = []
            for l in lefts {
                for r in rights where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                    pairs.append((l, r))
                }
            }
            return pairs
        }

        var leftByGroup: [String: [AppearedComponent]] = [:]
        var rightByGroup: [String: [AppearedComponent]] = [:]

        for component in lefts {
            for g in component.groupLinks.map({ $0.group.uid }) {
                leftByGroup[g, default: []].append(component)
            }
        }
        for component in rights {
            for g in component.groupLinks.map({ $0.group.uid }) {
                rightByGroup[g, default: []].append(component)
            }
        }

        var pairs: [(AppearedComponent, AppearedComponent)] = []
        for g in leftByGroup.keys {
            guard let ls = leftByGroup[g], let rs = rightByGroup[g] else { continue }
            for l in ls {
                for r in rs where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                    pairs.append((l, r))
                }
            }
        }

        return pairs
    }

    private func matchedLeftComponents(
        for pattern: Glossary.SDModel.SDPattern,
        appearedTerms: [AppearedTerm]
    ) -> [AppearedComponent] {
        var out: [AppearedComponent] = []
        for appearedTerm in appearedTerms {
            for component in appearedTerm.components where component.pattern == pattern.name {
                if matchesRole(component.role, required: pattern.leftRole) {
                    out.append(AppearedComponent(component: component, appearedTerm: appearedTerm))
                }
            }
        }
        return out
    }

    private func buildEntriesFromPairs(
        pairs: [(AppearedComponent, AppearedComponent)],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for (lComp, rComp) in pairs {
            let leftTerm = lComp.appearedTerm
            let rightTerm = rComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? rComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? rComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}{J}{R}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L} {R}"
            let variants: [String] = Glossary.Util.renderVariants(srcTpl, joiners: pattern.sourceJoiners, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: leftTerm.sdTerm, R: rightTerm.sdTerm)
                let tgt = Glossary.Util.renderTarget(tgtTpl, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src.composed,
                            target: tgt,
                            variants: variants,
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: leftTerm.key,
                                rightKey: rightTerm.key,
                                needPairCheck: pattern.needPairCheck
                            ),
                            componentTerms: [
                                makeComponentTerm(
                                    from: leftTerm,
                                    source: src.left
                                ),
                                makeComponentTerm(
                                    from: rightTerm,
                                    source: src.right
                                )
                            ]
                        )
                    )
                }
            }
        }

        return entries
    }

    private func buildEntriesFromLefts(
        lefts: [AppearedComponent],
        pattern: Glossary.SDModel.SDPattern,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for lComp in lefts {
            let term = lComp.appearedTerm

            let srcTplIdx = lComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L}"
            let tgt = Glossary.Util.renderTarget(tgtTpl, L: term.sdTerm, R: nil)
            let variants = Glossary.Util.renderVariants(srcTpl, joiners: joiners, L: term.sdTerm, R: nil)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: term.sdTerm, R: nil)

                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src.composed,
                            target: tgt,
                            variants: variants,
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: term.key,
                                rightKey: nil,
                                needPairCheck: false
                            ),
                            componentTerms: [
                                makeComponentTerm(
                                    from: term,
                                    source: src.left
                                )
                            ]
                        )
                    )
                }
            }
        }

        return entries
    }

    private func matchesRole(_ componentRole: String?, required: String?) -> Bool {
        guard
            let requiredRole = required?.trimmingCharacters(in: .whitespacesAndNewlines),
            requiredRole.isEmpty == false
        else {
            return true
        }
        guard
            let role = componentRole?.trimmingCharacters(in: .whitespacesAndNewlines),
            role.isEmpty == false
        else {
            return false
        }
        return role == requiredRole
    }

    // SegmentPieces 기반 마스킹
    func maskFromPieces(
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

                    let (b, r) = hangulFinalJongInfo(entry.target)
                    locks[token] = LockInfo(
                        placeholder: token,
                        target: entry.target,
                        endsWithBatchim: b,
                        endsWithRieul: r,
                        isAppellation: entry.isAppellation
                    )
                    tokenEntries[token] = entry

                    // NBSP 삽입 등으로 위치가 변할 수 있어 마지막 토큰 위치를 다시 계산한다.
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

            if let fallbacks = name.fallbackTerms {
                for fallback in fallbacks {
                    handleVariants(fallback.variants, replacement: fallback.target, entry: entry)
                }
            }
        }

        ranges = normalizedOffsets.compactMap { offset in
            guard let swiftRange = Range(offset.nsRange, in: out) else { return nil }
            return TermRange(entry: offset.entry, range: swiftRange, type: offset.type)
        }

        return (out, ranges, preNormalizedRanges)
    }

    /// 토큰 → 실제 용어 교체 시 길이 변화 추적용.
    struct ReplacementDelta {
        let offset: Int   // 교체 전 lowerBound 오프셋
        let delta: Int    // 길이 변화 (new - old)
    }

    func unmaskWithOrder(
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

            // 원본 위치/길이 기반으로 델타를 계산해 이후 range 보정에 활용한다.
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

        // 토큰 순서가 어긋난 경우 전역 검색으로 재시도 (아직 처리되지 않은 토큰만)
        let processedTokens = Set(tokensInOrder.prefix(tokenCursor))
        let remainingLocks = locksByToken.filter { processedTokens.contains($0.key) == false }
        if remainingLocks.isEmpty == false {
            out = normalizeTokensAndParticles(in: out, locksByToken: remainingLocks)
        }
        return (out, ranges, deltas)
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
    
    // 마스킹하지 않은 용어집 정규화 + range 추적 버전
    /// 정규화 텍스트와 원본 사이 길이 차를 고려하며 변형 정규화 range를 추적한다.
    func normalizeVariantsAndParticles(
        in text: String,
        entries: [(NameGlossary, GlossaryEntry)],
        baseText: String,
        cumulativeDelta: Int
    ) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange]) {
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
        if allVariants.isEmpty { return (text, [], []) }

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
        var localDelta = cumulativeDelta

        for r in matches.reversed() {
            let nsOut = out as NSString
            let found = nsOut.substring(with: r)
            guard let mapping = variantMap[found] else { continue }
            let canon = mapping.canonical
            let entry = mapping.entry
            let (has, rieul) = hangulFinalJongInfo(canon)

            // preNormalized 범위는 교체 전 원본 텍스트 기준으로 계산
            let originalLower = r.location - localDelta
            if originalLower >= 0, originalLower + r.length <= (original as NSString).length {
                let lower = original.index(original.startIndex, offsetBy: originalLower)
                let upper = original.index(lower, offsetBy: r.length)
                preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
            }

            out = nsOut.replacingCharacters(in: r, with: canon)

            let canonRange = NSRange(location: r.location, length: (canon as NSString).length)
            let (fixed, fixedRange) = fixParticles(
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
        }

        return (out, ranges, preNormalizedRanges)
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

            // "이"가 부사/대명사 등의 일부인 경우(예: "이렇게", "이것")에는 조사를 교정하지 않는다.
            // josaRange는 조사 후보 전체를 포함하므로, 다음 문자가 단어 본문으로 이어지면 조사로 보지 않는다.
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
