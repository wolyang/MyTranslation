//
//  NameGlossary.swift
//  MyTranslation
//

import Foundation

public struct NameGlossary: Sendable {
    public struct FallbackTerm: Sendable {
        public let termKey: String
        public let target: String
        public let variants: [String]

        public init(termKey: String, target: String, variants: [String]) {
            self.termKey = termKey
            self.target = target
            self.variants = variants
        }
    }

    public let target: String
    public let variants: [String]
    public let expectedCount: Int   // 원문에서 이 이름이 등장한 횟수
    public let fallbackTerms: [FallbackTerm]?  // Pattern fallback용

    public init(
        target: String,
        variants: [String],
        expectedCount: Int,
        fallbackTerms: [FallbackTerm]?
    ) {
        self.target = target
        self.variants = variants
        self.expectedCount = expectedCount
        self.fallbackTerms = fallbackTerms
    }
}
