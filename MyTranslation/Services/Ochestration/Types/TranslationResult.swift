//
//  TranslationResult.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

public struct TranslationResult: Identifiable {
    public let id: String
    public let segmentID: String
    public let engine: EngineTag
    public let text: String
    public let residualSourceRatio: Double // 잔여 한자 비율 등
    public let createdAt: Date
}
