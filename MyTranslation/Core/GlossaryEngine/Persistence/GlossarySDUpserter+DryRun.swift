import Foundation
import SwiftData

extension Glossary.SDModel.GlossaryUpserter {
    // 결과 예상 시뮬레이션 함수
    func dryRun(bundle: JSBundle) throws -> Glossary.SDModel.ImportDryRunReport {
        let existingTerms = try context.fetch(FetchDescriptor<Glossary.SDModel.SDTerm>())
        let existingPatterns = try context.fetch(FetchDescriptor<Glossary.SDModel.SDPattern>())
        let metaMap = try fetchPatternMetaMap()

        let incomingTermKeys = bundle.terms.map { $0.key }
        let incomingPatternIds = bundle.patterns.map { $0.name }

        let existingTermSnapshots = Dictionary(uniqueKeysWithValues: existingTerms.map { ($0.key, termSnapshot(of: $0)) })
        let existingPatternSnapshots = Dictionary(
            uniqueKeysWithValues: existingPatterns.map { pattern in
                (pattern.name, patternSnapshot(of: pattern, meta: metaMap[pattern.name]))
            }
        )

        let incomingTerms = deduplicatedMap(bundle.terms, key: \JSTerm.key)
        let incomingPatterns = deduplicatedMap(bundle.patterns, key: \JSPattern.name)

        let termChanges = computeTermChanges(
            incoming: incomingTerms,
            existing: existingTermSnapshots
        )

        let tDel: Int
        if sync.removeMissingTerms {
            let candidates = Set(existingTermSnapshots.keys).subtracting(incomingTerms.keys)
            if let filter = sync.termDeletionFilter {
                tDel = candidates.filter { filter($0) }.count
            } else {
                tDel = candidates.count
            }
        } else {
            tDel = 0
        }

        var pNew = 0
        var pUpd = 0
        var pSame = 0
        for (name, pattern) in incomingPatterns {
            if let existing = existingPatternSnapshots[name] {
                if existing == patternSnapshot(of: pattern, meta: metaMap[name]) {
                    pSame += 1
                } else {
                    pUpd += 1
                }
            } else {
                pNew += 1
            }
        }
        let pDel: Int
        if sync.removeMissingPatterns {
            let candidates = Set(existingPatternSnapshots.keys).subtracting(incomingPatterns.keys)
            if let filter = sync.patternDeletionFilter {
                pDel = candidates.filter { filter($0) }.count
            } else {
                pDel = candidates.count
            }
        } else {
            pDel = 0
        }

        func collisions(_ arr: [String]) -> [Glossary.SDModel.ImportDryRunReport.KeyCollision] {
            var freq: [String:Int] = [:]
            for k in arr { freq[k, default: 0] += 1 }
            return freq
                .filter { $0.value > 1 }
                .map { .init(key: $0.key, count: $0.value) }
                .sorted { $0.key < $1.key }
        }

        let termCollisions = collisions(incomingTermKeys)
        let patternCollisions = collisions(incomingPatternIds)
        var warns: [String] = []
        if !termCollisions.isEmpty { warns.append("Duplicate Term keys in import: \(termCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }
        if !patternCollisions.isEmpty { warns.append("Duplicate Pattern ids in import: \(patternCollisions.map{ "\($0.key)×\($0.count)" }.joined(separator: ", "))") }

        return Glossary.SDModel.ImportDryRunReport(
            terms: .init(
                newCount: termChanges.new,
                updateCount: termChanges.updated,
                unchangedCount: termChanges.unchanged,
                deleteCount: tDel
            ),
            patterns: .init(newCount: pNew, updateCount: pUpd, unchangedCount: pSame, deleteCount: pDel),
            warnings: warns,
            termKeyCollisions: termCollisions,
            patternKeyCollisions: patternCollisions
        )
    }

    fileprivate func computeTermChanges(
        incoming: [String: JSTerm],
        existing: [String: TermSnapshot]
    ) -> (new: Int, updated: Int, unchanged: Int) {
        var newCount = 0
        var updatedCount = 0
        var unchangedCount = 0

        for (key, term) in incoming {
            if let snapshot = existing[key] {
                if snapshot == termSnapshot(of: term) {
                    unchangedCount += 1
                } else {
                    updatedCount += 1
                }
            } else {
                newCount += 1
            }
        }

        return (newCount, updatedCount, unchangedCount)
    }
}
