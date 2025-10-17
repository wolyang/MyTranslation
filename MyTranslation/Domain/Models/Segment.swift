//
//  Segment.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

public struct Segment: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let indexInPage: Int
    public let originalText: String
    public let normalizedText: String
}
