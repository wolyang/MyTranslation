// File: SwiftDataModel.swift
import Foundation
import SwiftData

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
