//
//  Segment.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

public struct Segment: Identifiable, Hashable, Sendable {
    public struct DOMRange: Hashable, Codable, Sendable {
        public let startToken: String
        public let startOffset: Int
        public let endToken: String
        public let endOffset: Int
        public let startIndex: Int
        public let endIndex: Int

        public init(startToken: String,
                    startOffset: Int,
                    endToken: String,
                    endOffset: Int,
                    startIndex: Int,
                    endIndex: Int) {
            self.startToken = startToken
            self.startOffset = startOffset
            self.endToken = endToken
            self.endOffset = endOffset
            self.startIndex = startIndex
            self.endIndex = endIndex
        }
    }

    public let id: String
    public let url: URL
    public let indexInPage: Int
    public let originalText: String
    public let normalizedText: String
    public let domRange: DOMRange?

    public init(id: String,
                url: URL,
                indexInPage: Int,
                originalText: String,
                normalizedText: String,
                domRange: DOMRange?) {
        self.id = id
        self.url = url
        self.indexInPage = indexInPage
        self.originalText = originalText
        self.normalizedText = normalizedText
        self.domRange = domRange
    }
}
