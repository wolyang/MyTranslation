// File: SwiftDataModel.swift
import Foundation
import SwiftData

@Model
final class Term {
    @Attribute(.unique) var source: String
    var target: String
    var strict: Bool
    var variants: [String]
    var notes: String?
    var category: String?
    init(source: String, target: String, strict: Bool = true, variants: [String] = [], notes: String? = nil, category: String? = nil) {
        self.source = source
        self.target = target
        self.strict = strict
        self.variants = variants
        self.notes = notes
        self.category = category
    }
}

@Model
final class GlossaryMeta {
    var version: Int
    var langPair: String // "zh->ko" 등
    init(version: Int = 1, langPair: String = "zh->ko") {
        self.version = version
        self.langPair = langPair
    }
}

@Model
final class CacheEntry {
    @Attribute(.unique) var key: String // segment.id + engine
    var engine: String
    var inputHash: String
    var output: String
    var createdAt: Date
    init(key: String, engine: String, inputHash: String, output: String, createdAt: Date = .init()) {
        self.key = key
        self.engine = engine
        self.inputHash = inputHash
        self.output = output
        self.createdAt = createdAt
    }
}
