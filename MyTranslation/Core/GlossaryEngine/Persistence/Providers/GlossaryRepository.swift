import Foundation
import SwiftData

extension Glossary {
    /// 데이터 조회 인터페이스.
    public protocol RepositoryProviding {
        func fetchData(for pageText: String) async throws -> GlossaryData
    }

    /// SwiftData 기반 Glossary 저장소.
    public final class Repository: RepositoryProviding {
        private let context: ModelContext
        private let recallOpt: RecallOptions

        public init(context: ModelContext, recallOpt: RecallOptions = .init()) {
            self.context = context
            self.recallOpt = recallOpt
        }

        public func fetchData(for pageText: String) async throws -> GlossaryData {
            // SwiftData 접근은 MainActor에서만 수행한다.
            let lookup = try await MainActor.run { () throws -> (terms: [Glossary.SDModel.SDTerm], patterns: [Glossary.SDModel.SDPattern]) in
                let candidateKeys = try Recall.recallTermKeys(for: pageText, ctx: context, opt: recallOpt)
                guard candidateKeys.isEmpty == false else { return ([], []) }

                let candidateTerms = try Store.fetchTerms(keys: candidateKeys, ctx: context)
                let oneCharTerms = try Store.fetchOneCharTerms(ctx: context)
                let terms = Array(Set(candidateTerms + oneCharTerms))
                let patterns = try Store.fetchPatterns(ctx: context)
                return (terms, patterns)
            }

            guard lookup.terms.isEmpty == false else {
                return GlossaryData(matchedTerms: [], patterns: [], matchedSourcesByKey: [:])
            }

            // AC 구성 및 매칭은 백그라운드에서 수행
            let acBundle = Matcher.makeACBundle(from: lookup.terms)
            let hits = acBundle.ac.find(in: pageText)

            var matchedSourcesByKey: [String: Set<String>] = [:]
            var matchedTermKeys: Set<String> = []
            for h in hits {
                guard let owner = acBundle.pidToOwner[h.pid] else { continue }
                matchedSourcesByKey[owner.termKey, default: []].insert(acBundle.sources[h.pid])
                matchedTermKeys.insert(owner.termKey)
            }

            let matchedTerms = lookup.terms.filter { matchedTermKeys.contains($0.key) }

            return GlossaryData(
                matchedTerms: matchedTerms,
                patterns: lookup.patterns,
                matchedSourcesByKey: matchedSourcesByKey
            )
        }
    }
}

// Legacy aliases for compatibility during migration
extension Glossary {
    public typealias DataProvider = Repository
    public typealias DataProviding = RepositoryProviding
}

// MARK: - Store (SwiftData fetches)
extension Glossary {
    enum Store {
        typealias SDSource = Glossary.SDModel.SDSource
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDPattern = Glossary.SDModel.SDPattern

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
        static func fetchOneCharTerms(ctx: ModelContext) throws -> [SDTerm] {
            let allSources = try ctx.fetch(FetchDescriptor<SDSource>())
            let oneCharSources = allSources.filter { $0.text.count == 1 }
            let terms = oneCharSources.compactMap { $0.term }
            return Array(Set(terms))
        }
    }
}

// MARK: - Recall (Q-gram based candidate narrowing)
extension Glossary {
    enum Recall {
        typealias SDSourceIndex = Glossary.SDModel.SDSourceIndex

        @MainActor
        static func recallTermKeys(for pageText: String, ctx: ModelContext, opt: RecallOptions) throws -> [String] {
            var grams = Set(Util.qgrams(pageText, n: opt.gram))

            if opt.enableUnigramRecall {
                var freq: [Character: Int] = [:]
                for ch in pageText {
                    if Util.char(ch, isIn: opt.unigramScripts) {
                        freq[ch, default: 0] += 1
                    }
                }
                let topK = freq.sorted { $0.value > $1.value }
                    .prefix(opt.maxDistinctUnigrams)
                    .map { String($0.key) }
                grams.formUnion(topK)
            }

            guard grams.isEmpty == false else { return [] }

            let scripts = opt.allowedScripts
            let lens = opt.allowedLenBuckets

            var freq: [String: Int] = [:]

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
}

// MARK: - Matcher (AC bundle & helpers)
extension Glossary {
    enum Matcher {
        typealias SDTerm = Glossary.SDModel.SDTerm

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
            return .init(ac: AhoCorasick(patterns: sources), pidToOwner: pidToOwner, sources: sources)
        }
    }
}
