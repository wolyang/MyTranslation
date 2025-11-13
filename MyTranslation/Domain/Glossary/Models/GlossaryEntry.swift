//
//  GlossaryEntry.swift
//  MyTranslation
//
//  Created by sailor.m on 10/17/25.
//

import Foundation
import SwiftData

// MARK: - Public Models

public struct GlossaryEntry: Sendable, Hashable {
    public var source: String
    public var target: String
    public var variants: Set<String>
    public var preMask: Bool
    public var isAppellation: Bool
    public var prohibitStandalone: Bool
    public enum Origin: Sendable, Hashable { case termStandalone(termKey: String), composer(composerId: String, leftKey: String, rightKey: String?, needPairCheck: Bool), markerStandalone }
    public var origin: Origin
}

public struct GlossaryAppellationMarker: Sendable, Hashable {
    public enum Position: String, Sendable, Hashable { case prefix, suffix }
    public let source: String
    public let position: Position
    // (메타) 마커가 단독일 때의 번역 도착어 — 승격 판단에는 사용하지 않음
    public let standaloneTarget: String?
    /// (메타) 마커 자체의 단독 사용 금지 여부 — 승격 판단에는 사용하지 않음
    public let prohibitStandalone: Bool

    public init(source: String, rawPosition: String,
                standaloneTarget: String?, prohibitStandalone: Bool) {
        self.source = source
        self.position = Position(rawValue: rawPosition) ?? .suffix
        self.standaloneTarget = standaloneTarget
        self.prohibitStandalone = prohibitStandalone
    }
}

public enum ScriptKind: Int16, Sendable { case unknown=0, hangul=1, cjk=2, latin=3, mixed=4 }

public struct RecallOptions: Sendable {
    public var gram: Int = 2
    public var minHitPerTerm: Int = 1
    public var allowedScripts: Set<ScriptKind>? = nil
    public var allowedLenBuckets: Set<Int16>? = nil
    
    public var enableUnigramRecall: Bool = true           // 1-gram도 조회
    public var unigramScripts: Set<ScriptKind> = [.cjk]   // 1-gram은 CJK만
    public var maxDistinctUnigrams: Int = 256             // 과리콜 방지 상한
    public init() {}
}

// MARK: - Glossary Namespace

extension Glossary {
    // DI를 위한 인터페이스
    public protocol Providing {
        @MainActor
        func buildEntries(for pageText: String) throws -> (entries: [GlossaryEntry], markers: [GlossaryAppellationMarker])
    }

    /// Instance-based runtime that OWNS the ModelContext.
    public final class Service: Providing {
        private let context: ModelContext
        private let recallOpt: RecallOptions

        public init(context: ModelContext, recallOpt: RecallOptions = .init()) {
            self.context = context
            self.recallOpt = recallOpt
        }

        @MainActor
        public func buildEntries(for pageText: String) throws -> (entries: [GlossaryEntry], markers: [GlossaryAppellationMarker]) {
            // 1) 후보 리콜(Q-gram)
            let candidateKeys = try Recall.recallTermKeys(for: pageText, ctx: context, opt: recallOpt)
            if candidateKeys.isEmpty { return ([], []) }

            // 2) 후보 Term 로드
            let terms = try Store.fetchTerms(keys: candidateKeys, ctx: context)
            let termByKey = Dictionary(uniqueKeysWithValues: terms.map { ($0.key, $0) })

            // 3) AC 구성 및 매치 스캔
            let acBundle = Matcher.makeACBundle(from: terms)
            let hits = acBundle.ac.find(in: pageText)

            // 4) 매치 테이블 구성
            var matchedSourcesByKey: [String: Set<String>] = [:]
            var matchedStandaloneByKey: Set<String> = []
            for h in hits {
                guard let owner = acBundle.pidToOwner[h.pid] else { continue }
                matchedSourcesByKey[owner.termKey, default: []].insert(acBundle.sources[h.pid])
                /*if !owner.prohibitStandalone { */matchedStandaloneByKey.insert(owner.termKey) /*}*/
            }
            if matchedSourcesByKey.isEmpty { return ([], []) }

            // 5) 단독 엔트리
            var entries: [GlossaryEntry] = []
            for key in matchedStandaloneByKey {
                guard let t = termByKey[key] else { continue }
                for s in t.sources {
                    entries.append(GlossaryEntry(
                        source: s.text,
                        target: t.target,
                        variants: Set(t.variants),
                        preMask: t.preMask,
                        isAppellation: t.isAppellation,
                        prohibitStandalone: s.prohibitStandalone,
                        origin: .termStandalone(termKey: t.key)
                    ))
                }
            }

            // 6) 패턴 조합 엔트리
            let patterns = try Store.fetchPatterns(ctx: context)
            let composed = try Composer.composeEntriesForMatched(pageText: pageText,
                                                                 patterns: patterns,
                                                                 termsByKey: termByKey,
                                                                 matchedSourcesByKey: matchedSourcesByKey)
            entries.append(contentsOf: composed)
            
            // 7) 호칭 마커
            let sdMarkers = try Store.fetchMarkers(ctx: context)
            var markers: [GlossaryAppellationMarker] = []
            for marker in sdMarkers {
                if pageText.contains(marker.source) {
                    markers.append(GlossaryAppellationMarker(
                        source: marker.source,
                        rawPosition: marker.position,
                        standaloneTarget: marker.target,
                        prohibitStandalone: marker.prohibitStandalone
                    ))
                    if !marker.prohibitStandalone {
                        entries.append(GlossaryEntry(
                            source: marker.source,
                            target: marker.target,
                            variants: [],
                            preMask: false,
                            isAppellation: true,
                            prohibitStandalone: true,
                            origin: .markerStandalone))
                    }
                }
            }

            // 7) 병합
            return (Dedup.run(entries), markers)
        }
    }

    // MARK: - Store (SwiftData fetches)
    enum Store {
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDPattern = Glossary.SDModel.SDPattern
        typealias SDAppellationMarker = Glossary.SDModel.SDAppellationMarker
        
        @MainActor
        static func fetchTerms(keys: [String], ctx: ModelContext) throws -> [SDTerm] {
            var out: [SDTerm] = []
            out.reserveCapacity(keys.count)
            for k in keys {
                let pred = #Predicate<SDTerm> { $0.key == k }
                var desc = FetchDescriptor<SDTerm>(predicate: pred)
                desc.includePendingChanges = true
                if let t = try ctx.fetch(desc).first { out.append(t) }
            }
            return out
        }

        @MainActor
        static func fetchPatterns(ctx: ModelContext) throws -> [SDPattern] {
            try ctx.fetch(FetchDescriptor<SDPattern>())
        }

        @MainActor
        static func fetchMarkers(ctx: ModelContext) throws -> [SDAppellationMarker] {
            try ctx.fetch(FetchDescriptor<SDAppellationMarker>())
        }
    }

    // MARK: - Recall (Q-gram based candidate narrowing)
    enum Recall {
        typealias SDSourceIndex = Glossary.SDModel.SDSourceIndex
        
        @MainActor
        static func recallTermKeys(for pageText: String, ctx: ModelContext, opt: RecallOptions) throws -> [String] {
            var grams = Set(Util.qgrams(pageText, n: opt.gram))
            
            if opt.enableUnigramRecall {
                var uni: [String] = []
                uni.reserveCapacity(min(pageText.count, opt.maxDistinctUnigrams))
//                var seen: Set<Character> = []
                var freq: [Character:Int] = [:]
                for ch in pageText {
//                    if seen.contains(ch) { continue }
//                    seen.insert(ch)
                    // CJK 범위만 허용
                    if Util.char(ch, isIn: opt.unigramScripts) {
                        freq[ch, default: 0] += 1
//                        uni.append(String(ch))
//                        if uni.count >= opt.maxDistinctUnigrams { break }
                    }
                }
                let topK = freq.sorted { $0.value > $1.value }
                    .prefix(opt.maxDistinctUnigrams)
                    .map { String($0.key) }
                grams.formUnion(topK)
            }
            
            if grams.isEmpty { return [] }

            let scripts = opt.allowedScripts
            let lens = opt.allowedLenBuckets
            
            var freq: [String:Int] = [:]
            
            let all = try ctx.fetch(FetchDescriptor<SDSourceIndex>())

            for g in grams {
                let pred = #Predicate<SDSourceIndex> { idx in idx.qgram == g }
                let fetched = try ctx.fetch(FetchDescriptor<SDSourceIndex>(predicate: pred))
                for row in fetched {
                    if let scripts, !scripts.contains(ScriptKind(rawValue: row.script) ?? .unknown) { continue }
                    if let lens, !lens.contains(row.len) { continue }
                    let key = row.term.key
                    freq[key, default: 0] += 1
                }
            }
            let minHit = max(1, opt.minHitPerTerm)
            let recall = freq.filter { $0.value >= minHit }.map { $0.key }
            
            return recall
        }
    }

    // MARK: - Matcher (AC bundle & helpers)
    enum Matcher {
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDAppellationMarker = Glossary.SDModel.SDAppellationMarker
        
        struct Owner { let termKey: String; let prohibitStandalone: Bool }
        struct ACBundle { let ac: AhoCorasick; let pidToOwner: [Int: Owner]; let sources: [String] }

        static func makeACBundle(from terms: [SDTerm]) -> ACBundle {
            var sources: [String] = []
            var pidToOwner: [Int: Owner] = [:]
            var pid = 0
            for t in terms {
                for s in t.sources {
                    sources.append(s.text)
                    pidToOwner[pid] = Owner(termKey: t.key, prohibitStandalone: s.prohibitStandalone)
                    pid += 1
                }
            }
            return .init(ac: AhoCorasick(sources), pidToOwner: pidToOwner, sources: sources)
        }
    }

    // MARK: - Composer (pattern → entries)
    enum Composer {
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDPattern = Glossary.SDModel.SDPattern
        typealias SDAppellationMarker = Glossary.SDModel.SDAppellationMarker
        typealias SDComponent = Glossary.SDModel.SDComponent
        
        @MainActor
        static func composeEntriesForMatched(pageText: String,
                                             patterns: [SDPattern],
                                             termsByKey: [String: SDTerm],
                                             matchedSourcesByKey: [String: Set<String>]) throws -> [GlossaryEntry] {
            let matchedTerms: Set<String> = Set(matchedSourcesByKey.keys)
            let allTerms = termsByKey.values
            var entries: [GlossaryEntry] = []

            for pat in patterns {
                let usesR = pat.sourceTemplates.contains { $0.contains("{R}") } || pat.targetTemplates.contains { $0.contains("{R}") }
                if usesR {
                    let pairs = try matchedPairs(for: pat, terms: allTerms, matched: matchedTerms)
                    for (lComp, rComp) in pairs {
                        let leftTerm = lComp.term
                        let rightTerm = rComp.term
                        let srcTplIdx = lComp.srcTplIdx ?? 0
                        let tgtTplIdx = lComp.tgtTplIdx ?? 0
                        let srcTpl = pat.sourceTemplates[safe: srcTplIdx] ?? pat.sourceTemplates.first ?? "{L}{J}{R}"
                        let tgtTpl = pat.targetTemplates[safe: tgtTplIdx] ?? pat.targetTemplates.first ?? "{L} {R}"
                        let joiner = Util.chooseJoiner(from: pat.sourceJoiners, in: pageText)
                        let src = Util.renderSource(srcTpl, joiner: joiner, L: leftTerm, R: rightTerm)
                        let tgt = Util.renderTarget(tgtTpl, L: leftTerm, R: rightTerm)
                        entries.append(GlossaryEntry(
                            source: src,
                            target: tgt,
                            variants: Set(leftTerm.variants + rightTerm.variants),
                            preMask: pat.preMask,
                            isAppellation: pat.isAppellation,
                            prohibitStandalone: false,
                            origin: .composer(composerId: pat.name, leftKey: leftTerm.key, rightKey: rightTerm.key, needPairCheck: pat.needPairCheck)
                        ))
                    }
                } else {
                    let lefts = try matchedLeftComponents(for: pat, terms: allTerms, matched: matchedTerms)
                    for lComp in lefts {
                        let t = lComp.term
                        let srcTplIdx = lComp.srcTplIdx ?? 0
                        let tgtTplIdx = lComp.tgtTplIdx ?? 0
                        let srcTpl = pat.sourceTemplates[safe: srcTplIdx] ?? pat.sourceTemplates.first ?? "{L}"
                        let tgtTpl = pat.targetTemplates[safe: tgtTplIdx] ?? pat.targetTemplates.first ?? "{L}"
                        let joiner = Util.chooseJoiner(from: pat.sourceJoiners, in: pageText)
                        let src = Util.renderSource(srcTpl, joiner: joiner, L: t, R: nil)
                        let tgt = Util.renderTarget(tgtTpl, L: t, R: nil)
                        entries.append(GlossaryEntry(
                            source: src,
                            target: tgt,
                            variants: Set(t.variants),
                            preMask: pat.preMask,
                            isAppellation: pat.isAppellation,
                            prohibitStandalone: false,
                            origin: .composer(composerId: pat.name, leftKey: t.key, rightKey: nil, needPairCheck: false)
                        ))
                    }
                }
            }
            return entries
        }

        @MainActor
        private static func matchedLeftComponents(for pat: SDPattern, terms: any Sequence<SDTerm>, matched: Set<String>) throws -> [SDComponent] {
            var out: [SDComponent] = []
            for t in terms where matched.contains(t.key) {
                for c in t.components where c.pattern == pat.name {
                    if !pat.leftRoles.isEmpty {
                        if let roles = c.roles, !roles.isEmpty, !Set(roles).isDisjoint(with: pat.leftRoles) { out.append(c) }
                    } else { out.append(c) }
                }
            }
            return out
        }

        @MainActor
        private static func matchedPairs(for pat: SDPattern, terms: any Sequence<SDTerm>, matched: Set<String>) throws -> [(SDComponent, SDComponent)] {
            var leftByGroup: [String:[SDComponent]] = [:]
            var rightByGroup: [String:[SDComponent]] = [:]
            for t in terms where matched.contains(t.key) {
                for c in t.components where c.pattern == pat.name {
                    let groups = c.groupLinks.map { $0.group.uid }
                    let isLeft = pat.leftRoles.isEmpty ? true : !(Set(c.roles ?? []).isDisjoint(with: pat.leftRoles))
                    let isRight = pat.rightRoles.isEmpty ? true : !(Set(c.roles ?? []).isDisjoint(with: pat.rightRoles))
                    if isLeft { for g in groups { leftByGroup[g, default: []].append(c) } }
                    if isRight { for g in groups { rightByGroup[g, default: []].append(c) } }
                }
            }
            var pairs: [(SDComponent, SDComponent)] = []
            for g in leftByGroup.keys {
                guard let Ls = leftByGroup[g], let Rs = rightByGroup[g] else { continue }
                for l in Ls { for r in Rs where (!pat.skipPairsIfSameTerm || l.term.key != r.term.key) { pairs.append((l,r)) } }
            }
            return pairs
        }
    }

    // MARK: - Dedup
    enum Dedup {
        static func run(_ entries: [GlossaryEntry]) -> [GlossaryEntry] {
                struct K: Hashable {
                    let source: String
                    let target: String
                    let preMask: Bool
                    let isApp: Bool
                }
                var map: [K: GlossaryEntry] = [:]
                for e in entries {
                    let k = K(source: e.source, target: e.target, preMask: e.preMask, isApp: e.isAppellation)
                    if var exist = map[k] {
                        // 같은 (source,target,옵션) 중복만 variants 병합
                        exist.variants.formUnion(e.variants)
                        exist.prohibitStandalone =
                            exist.prohibitStandalone && e.prohibitStandalone
                        map[k] = exist
                    } else {
                        map[k] = e
                    }
                }
                return Array(map.values)
            }
    }

    // MARK: - Util (q-gram, script, rendering)
    enum Util {
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDSource = Glossary.SDModel.SDSource
        
        
        static func scriptKind(of ch: Character) -> ScriptKind {
            guard let u = ch.unicodeScalars.first else { return .unknown }
            switch u.value {
            case 0xAC00...0xD7A3: return .hangul
            case 0x4E00...0x9FFF: return .cjk
            case 0x0041...0x007A, 0x0030...0x0039: return .latin
            default: return .unknown
            }
        }
        static func char(_ ch: Character, isIn scripts: Set<ScriptKind>) -> Bool {
            scripts.contains(scriptKind(of: ch))
        }
        
        static func detectScriptKind(_ s: String) -> ScriptKind {
            var hasH=false, hasC=false, hasL=false
            for u in s.unicodeScalars {
                switch u.value {
                case 0xAC00...0xD7A3: hasH = true
                case 0x4E00...0x9FFF: hasC = true
                case 0x0041...0x007A, 0x0030...0x0039: hasL = true
                default: break
                }
            }
            let flags = (hasH ? 1:0) + (hasC ? 2:0) + (hasL ? 4:0)
            switch flags {
            case 1: return .hangul
            case 2: return .cjk
            case 4: return .latin
            case 0: return .unknown
            default: return .mixed
            }
        }

        static func lengthBucket(_ n: Int) -> Int16 {
            switch n {
            case 0...2: return 2
            case 3...4: return 4
            case 5...8: return 8
            case 9...16: return 16
            case 17...24: return 24
            default: return 32
            }
        }

        static func qgrams(_ s: String, n: Int) -> [String] {
            guard n > 0, s.count >= n else { return [] }
            var out: [String] = []
            let arr = Array(s)
            for i in 0..<(arr.count - n + 1) { out.append(String(arr[i..<(i+n)])) }
            return out
        }

        static func chooseJoiner(from joiners: [String], in pageText: String) -> String {
            if joiners.count <= 1 { return joiners.first ?? "" }
            for j in joiners where pageText.contains(j) { return j }
            return joiners.first ?? ""
        }

        static func renderSource(_ tpl: String, joiner J: String, L: SDTerm, R: SDTerm?) -> String {
            var s = tpl
            s = s.replacingOccurrences(of: "{J}", with: J)
            s = s.replacingOccurrences(of: "{L}", with: chooseBestSource(from: L.sources))
            if let R { s = s.replacingOccurrences(of: "{R}", with: chooseBestSource(from: R.sources)) }
            return s
        }

        static func renderTarget(_ tpl: String, L: SDTerm, R: SDTerm?) -> String {
            var t = tpl
            t = t.replacingOccurrences(of: "{L}", with: L.target)
            if let R { t = t.replacingOccurrences(of: "{R}", with: R.target) }
            return t
        }

        static func chooseBestSource(from sources: [SDSource]) -> String {
            if let s = sources.first(where: { !$0.prohibitStandalone }) { return s.text }
            return sources.first?.text ?? ""
        }
    }

    // MARK: - Aho-Corasick core (scoped)
    final class AhoCorasick {
        struct Node { var next: [Character:Int] = [:]; var fail: Int = 0; var out: [Int] = [] }
        private var nodes: [Node] = [Node()]
        private var patterns: [String] = []
        init(_ patterns: [String]) { build(patterns) }
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
}
