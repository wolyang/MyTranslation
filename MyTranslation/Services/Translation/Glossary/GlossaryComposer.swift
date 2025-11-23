import Foundation

/// 용어집 데이터로부터 GlossaryEntry를 생성하는 서비스.
public final class GlossaryComposer {
    public init() { }

    /// 세그먼트별 엔트리 생성 (메인 구현).
    public func buildEntriesForSegment(
        from data: GlossaryData,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        let standaloneEntries = buildStandaloneEntries(
            from: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey,
            targetText: segmentText
        )
        entries.append(contentsOf: standaloneEntries)

        let composedEntries = buildComposedEntriesForSegment(
            from: data.patterns,
            terms: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey,
            segmentText: segmentText
        )

        let standaloneSourceSet = Set(standaloneEntries.map { $0.source })
        let filteredComposed = composedEntries.filter { !standaloneSourceSet.contains($0.source) }
        entries.append(contentsOf: filteredComposed)

        return Deduplicator.deduplicate(entries)
    }

    /// 페이지 전체 엔트리 생성 (레거시 호환).
    public func buildEntries(
        from data: GlossaryData,
        pageText: String
    ) -> [GlossaryEntry] {
        buildEntriesForSegment(from: data, segmentText: pageText)
    }

    // MARK: - Private Helpers

    private func buildStandaloneEntries(
        from terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>],
        targetText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        for term in terms {
            guard let matchedSourcesForTerm = matchedSources[term.key] else { continue }

            let activatorKeys = Set(term.activators.map { $0.key })
            let activatesKeys = Set(term.activates.map { $0.key })

            for source in term.sources {
                guard matchedSourcesForTerm.contains(source.text) else { continue }

                // 세그먼트에 실제로 나타나는지 확인
                guard targetText.contains(source.text) else { continue }

                entries.append(
                    GlossaryEntry(
                        source: source.text,
                        target: term.target,
                        variants: Set(term.variants),
                        preMask: term.preMask,
                        isAppellation: term.isAppellation,
                        prohibitStandalone: source.prohibitStandalone,
                        origin: .termStandalone(termKey: term.key),
                        componentTerms: [
                            GlossaryEntry.ComponentTerm.make(
                                from: term,
                                matchedSources: matchedSourcesForTerm
                            )
                        ],
                        activatorKeys: activatorKeys,
                        activatesKeys: activatesKeys
                    )
                )
            }
        }

        return entries
    }

    private func buildComposedEntriesForSegment(
        from patterns: [Glossary.SDModel.SDPattern],
        terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>],
        segmentText: String
    ) -> [GlossaryEntry] {
        let matchedTermKeys = Set(matchedSources.keys)
        var candidateEntries: [GlossaryEntry] = []

        for pattern in patterns {
            let usesR = pattern.sourceTemplates.contains { $0.contains("{R}") }
                || pattern.targetTemplates.contains { $0.contains("{R}") }

            if usesR {
                let pairs = matchedPairs(
                    for: pattern,
                    terms: terms,
                    matched: matchedTermKeys
                )
                candidateEntries.append(
                    contentsOf: buildEntriesFromPairs(
                        pairs: pairs,
                        pattern: pattern,
                        matchedSources: matchedSources,
                        segmentText: segmentText
                    )
                )
            } else {
                let lefts = matchedLeftComponents(
                    for: pattern,
                    terms: terms,
                    matched: matchedTermKeys
                )
                candidateEntries.append(
                    contentsOf: buildEntriesFromLefts(
                        lefts: lefts,
                        pattern: pattern,
                        matchedSources: matchedSources,
                        segmentText: segmentText
                    )
                )
            }
        }

        let acBundle = makeACBundleForEntries(candidateEntries)
        let hits = acBundle.ac.find(in: segmentText)
        let matchedSourcesInSegment = Set(hits.map { acBundle.sources[$0.pid] })

        return candidateEntries.filter { matchedSourcesInSegment.contains($0.source) }
    }

    private func makeACBundleForEntries(
        _ entries: [GlossaryEntry]
    ) -> (ac: AhoCorasick, sources: [String]) {
        let sources = entries.map { $0.source }
        let ac = AhoCorasick(patterns: sources)
        return (ac, sources)
    }

    private func buildEntriesFromPairs(
        pairs: [(Glossary.SDModel.SDComponent, Glossary.SDModel.SDComponent)],
        pattern: Glossary.SDModel.SDPattern,
        matchedSources: [String: Set<String>],
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for (lComp, rComp) in pairs {
            let leftTerm = lComp.term
            let rightTerm = rComp.term

            // composer의 activates는 L과 R의 activates 합집합
            var composerActivatesKeys = Set<String>()
            composerActivatesKeys.formUnion(leftTerm.activates.map { $0.key })
            composerActivatesKeys.formUnion(rightTerm.activates.map { $0.key })

            let srcTplIdx = lComp.srcTplIdx ?? rComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? rComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}{J}{R}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L} {R}"
            let variants: [String] = Glossary.Util.renderVariants(srcTpl, joiners: pattern.sourceJoiners, L: leftTerm, R: rightTerm)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: leftTerm, R: rightTerm)
                let tgt = Glossary.Util.renderTarget(tgtTpl, L: leftTerm, R: rightTerm)
                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src,
                            target: tgt,
                            variants: Set(variants),
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            prohibitStandalone: false,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: leftTerm.key,
                                rightKey: rightTerm.key,
                                needPairCheck: pattern.needPairCheck
                            ),
                            componentTerms: [
                                GlossaryEntry.ComponentTerm.make(
                                    from: leftTerm,
                                    matchedSources: matchedSources[leftTerm.key] ?? []
                                ),
                                GlossaryEntry.ComponentTerm.make(
                                    from: rightTerm,
                                    matchedSources: matchedSources[rightTerm.key] ?? []
                                )
                            ],
                            activatorKeys: [],
                            activatesKeys: composerActivatesKeys
                        )
                    )
                }
            }
        }

        return entries
    }

    private func buildEntriesFromLefts(
        lefts: [Glossary.SDModel.SDComponent],
        pattern: Glossary.SDModel.SDPattern,
        matchedSources: [String: Set<String>],
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

        for lComp in lefts {
            let term = lComp.term

            let composerActivatesKeys = Set(term.activates.map { $0.key })

            let srcTplIdx = lComp.srcTplIdx ?? 0
            let tgtTplIdx = lComp.tgtTplIdx ?? 0
            let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}"
            let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L}"
            let tgt = Glossary.Util.renderTarget(tgtTpl, L: term, R: nil)
            let variants = Glossary.Util.renderVariants(srcTpl, joiners: joiners, L: term, R: nil)

            for joiner in joiners {
                let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: term, R: nil)
                for src in srcs {
                    entries.append(
                        GlossaryEntry(
                            source: src,
                            target: tgt,
                            variants: Set(variants),
                            preMask: pattern.preMask,
                            isAppellation: pattern.isAppellation,
                            prohibitStandalone: false,
                            origin: .composer(
                                composerId: pattern.name,
                                leftKey: term.key,
                                rightKey: nil,
                                needPairCheck: false
                            ),
                            componentTerms: [
                                GlossaryEntry.ComponentTerm.make(
                                    from: term,
                                    matchedSources: matchedSources[term.key] ?? []
                                )
                            ],
                            activatorKeys: [],
                            activatesKeys: composerActivatesKeys
                        )
                    )
                }
            }
        }

        return entries
    }

    private func matchedLeftComponents(
        for pattern: Glossary.SDModel.SDPattern,
        terms: any Sequence<Glossary.SDModel.SDTerm>,
        matched: Set<String>
    ) -> [Glossary.SDModel.SDComponent] {
        var out: [Glossary.SDModel.SDComponent] = []
        for term in terms where matched.contains(term.key) {
            for component in term.components where component.pattern == pattern.name {
                if matchesRole(component.role, required: pattern.leftRole) { out.append(component) }
            }
        }
        return out
    }

    private func matchedPairs(
        for pattern: Glossary.SDModel.SDPattern,
        terms: any Sequence<Glossary.SDModel.SDTerm>,
        matched: Set<String>
    ) -> [(Glossary.SDModel.SDComponent, Glossary.SDModel.SDComponent)] {
        var lefts: [Glossary.SDModel.SDComponent] = []
        var rights: [Glossary.SDModel.SDComponent] = []
        var hasAnyGroup = false

        for term in terms where matched.contains(term.key) {
            for component in term.components where component.pattern == pattern.name {
                let isLeft = matchesRole(component.role, required: pattern.leftRole)
                let isRight = matchesRole(component.role, required: pattern.rightRole)

                if !component.groupLinks.isEmpty { hasAnyGroup = true }

                if isLeft { lefts.append(component) }
                if isRight { rights.append(component) }
            }
        }

        if !hasAnyGroup {
            var pairs: [(Glossary.SDModel.SDComponent, Glossary.SDModel.SDComponent)] = []
            for l in lefts {
                for r in rights where (!pattern.skipPairsIfSameTerm || l.term.key != r.term.key) {
                    pairs.append((l, r))
                }
            }
            return pairs
        }

        var leftByGroup: [String: [Glossary.SDModel.SDComponent]] = [:]
        var rightByGroup: [String: [Glossary.SDModel.SDComponent]] = [:]

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

        var pairs: [(Glossary.SDModel.SDComponent, Glossary.SDModel.SDComponent)] = []
        for g in leftByGroup.keys {
            guard let ls = leftByGroup[g], let rs = rightByGroup[g] else { continue }
            for l in ls {
                for r in rs where (!pattern.skipPairsIfSameTerm || l.term.key != r.term.key) {
                    pairs.append((l, r))
                }
            }
        }

        return pairs
    }

    private func matchesRole(_ componentRole: String?, required: String?) -> Bool {
        guard
            let requiredRole = required?.trimmingCharacters(in: .whitespacesAndNewlines),
            !requiredRole.isEmpty
        else {
            return true
        }
        guard
            let role = componentRole?.trimmingCharacters(in: .whitespacesAndNewlines),
            !role.isEmpty
        else {
            return false
        }
        return role == requiredRole
    }
}

private extension GlossaryEntry.ComponentTerm {
    static func make(
        from term: Glossary.SDModel.SDTerm,
        matchedSources: Set<String>
    ) -> GlossaryEntry.ComponentTerm {
        let sources = term.sources.map {
            GlossaryEntry.ComponentTerm.Source(
                text: $0.text,
                prohibitStandalone: $0.prohibitStandalone
            )
        }
        return GlossaryEntry.ComponentTerm(
            key: term.key,
            target: term.target,
            variants: Set(term.variants),
            sources: sources,
            matchedSources: matchedSources,
            preMask: term.preMask,
            isAppellation: term.isAppellation,
            activatorKeys: Set(term.activators.map { $0.key }),
            activatesKeys: Set(term.activates.map { $0.key })
        )
    }
}

// MARK: - Aho-Corasick core (scoped)
private final class AhoCorasick {
    struct Node { var next: [Character:Int] = [:]; var fail: Int = 0; var out: [Int] = [] }
    private var nodes: [Node] = [Node()]
    private var patterns: [String] = []
    init(patterns: [String]) { build(patterns) }
    private func build(_ pats: [String]) {
        self.patterns = pats
        nodes = [Node()]
        for (pid, pat) in pats.enumerated() {
            var s = 0
            for ch in pat {
                if let to = nodes[s].next[ch] { s = to }
                else { nodes[s].next[ch] = nodes.count; nodes.append(Node()); s = nodes.count-1 }
            }
            nodes[s].out.append(pid)
        }
        var q: [Int] = []
        for (_, to) in nodes[0].next { nodes[to].fail = 0; q.append(to) }
        var qi = 0
        while qi < q.count {
            let v = q[qi]; qi += 1
            for (ch, to) in nodes[v].next {
                q.append(to)
                var f = nodes[v].fail
                while f != 0 && nodes[f].next[ch] == nil { f = nodes[f].fail }
                nodes[to].fail = nodes[f].next[ch] ?? 0
                nodes[to].out += nodes[nodes[to].fail].out
            }
        }
    }
    struct Hit { let start: Int; let end: Int; let pid: Int }
    func find(in text: String) -> [Hit] {
        var res: [Hit] = []
        var s = 0
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            while s != 0 && nodes[s].next[ch] == nil { s = nodes[s].fail }
            s = nodes[s].next[ch] ?? 0
            if !nodes[s].out.isEmpty {
                for pid in nodes[s].out {
                    let m = patterns[pid].count
                    res.append(Hit(start: i - m + 1, end: i + 1, pid: pid))
                }
            }
        }
        return res
    }
}
