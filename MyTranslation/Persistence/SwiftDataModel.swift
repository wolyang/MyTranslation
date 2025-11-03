// File: SwiftDataModel.swift
import Foundation
import SwiftData

@Model
final class Term {
    @Attribute(.unique) var source: String
    var target: String
    var category: String
    var variants: [String]
    var isEnabled: Bool = true
    init(source: String,
         target: String,
         category: String,
         variants: [String] = [],
         isEnabled: Bool = true) {
        self.source = source
        self.target = target
        self.category = category
        self.variants = variants
        self.isEnabled = isEnabled
    }
}

@Model
final class Person {
    @Attribute(.unique) var personId: String
    var familySources: [String]
    var familyTarget: String?
    var familyVariants: [String]
    var givenSources:  [String]
    var givenTarget:   String?
    var givenVariants: [String]

    // 이명/별칭 (동일 target 아래 여러 source를 묶음)
    @Relationship(deleteRule: .cascade, inverse: \Alias.person)
    var aliases: [Alias]

    init(personId: String,
         familySources: [String] = [],
         familyTarget: String? = nil,
         familyVariants: [String] = [],
         givenSources: [String] = [],
         givenTarget: String? = nil,
         givenVariants: [String] = [],
         aliases: [Alias] = []) {
        self.personId = personId
        self.familySources = familySources
        self.familyTarget  = familyTarget
        self.familyVariants = familyVariants
        self.givenSources  = givenSources
        self.givenTarget   = givenTarget
        self.givenVariants = givenVariants
        self.aliases       = aliases
    }
}

@Model
final class Alias {
    var sources: [String]
    var target:  String?
    var variants: [String]
    @Relationship var person: Person?

    init(sources: [String], target: String?, variants: [String] = [], person: Person? = nil) {
        self.sources = sources
        self.target  = target
        self.variants = variants
        self.person  = person
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
