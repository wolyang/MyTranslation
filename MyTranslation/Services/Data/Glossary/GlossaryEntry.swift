//
//  GlossaryEntry.swift
//  MyTranslation
//
//  Created by sailor.m on 10/17/25.
//

import Foundation

// MARK: - Glossary Types

public enum TermCategory: String, Codable, Sendable {
    case person
    case organization
    case term       // 기술/전문 용어, 기술명 등
    case other
    
    init(with category: String?) {
        switch category {
        case "울트라맨", "캐릭터명", "괴수, 성인":
            self = .person
        case "도구, 폼, 기술명":
            self = .term
        case "조직":
            self = .organization
        default:
            self = .other
        }
    }
}

public struct GlossaryEntry: Sendable {
    public let source: String
    public let sourceForms: [String]
    public let target: String
    public let variants: [String]
    public let category: TermCategory
    public let personId: String?
    public init(source: String,
                target: String,
                variants: [String] = [],
                category: TermCategory,
                personId: String? = nil,
                sourceForms: [String]? = nil) {
        self.source = source
        let trimmed = sourceForms?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        if trimmed.isEmpty {
            self.sourceForms = [source]
        } else {
            self.sourceForms = trimmed
        }
        self.target = target
        self.variants = variants
        self.category = category
        self.personId = personId
    }
}
