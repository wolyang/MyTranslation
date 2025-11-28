//
//  GlossarySDUpserter.swift
//  MyTranslation
//
//  Created by sailor.m on 11/8/25.
//

import Foundation
import SwiftData

extension Glossary.SDModel {

    enum ImportMergePolicy { case keepExisting, overwrite }

    struct ImportDryRunReport: Sendable {
        struct Bucket: Sendable {
            let newCount: Int
            let updateCount: Int
            let unchangedCount: Int
            let deleteCount: Int
        }
        struct KeyCollision: Sendable, Hashable { let key: String; let count: Int }
        let terms: Bucket
        let patterns: Bucket
        let warnings: [String]
        let termKeyCollisions: [KeyCollision]
        let patternKeyCollisions: [KeyCollision]
    }

    struct ImportSyncPolicy: Sendable {
        var removeMissingTerms = false
        var removeMissingPatterns = false
        var termDeletionFilter: (@Sendable (String) -> Bool)? = nil
        var patternDeletionFilter: (@Sendable (String) -> Bool)? = nil
    }

    enum Defaults {
        static let groupLabel = "그룹"
    }

    @MainActor
    final class GlossaryUpserter {
        let context: ModelContext
        let merge: ImportMergePolicy
        let sync: ImportSyncPolicy

        init(context: ModelContext, merge: ImportMergePolicy, sync: ImportSyncPolicy = .init()) {
            self.context = context
            self.merge = merge
            self.sync = sync
        }

        func apply(bundle: JSBundle) throws -> ImportDryRunReport {
            let report = try dryRun(bundle: bundle)
            try upsertTerms(bundle.terms)
            try upsertPatterns(bundle.patterns)
            if sync.removeMissingTerms || sync.removeMissingPatterns {
                try deleteMissing(bundle: bundle)
                try cleanupOrphans()
            }
            try context.save()
            return report
        }
    }
}
