//
//  TranslationRouter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

protocol TranslationRouter {
    func translateStream(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary
}

struct TranslationStreamSummary {
    let engineID: EngineTag
    let totalSegments: Int
    let succeededSegmentIDs: [String]
    let failedSegmentIDs: [String]
    let startedAt: Date
    let finishedAt: Date

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

struct TranslationStreamPayload: Codable, Equatable {
    let segmentID: String
    let originalText: String
    let translatedText: String
    let engineID: EngineTag
    let sequence: Int
}

struct TranslationStreamEvent {
    enum Kind {
        case cachedHit
        case requestScheduled
        case partial
        case final
        case failed
        case completed
    }

    let kind: Kind
    let payload: TranslationStreamPayload?
    let segmentID: String?
    let summary: TranslationStreamSummary?
    let error: Error?

    static func cached(payload: TranslationStreamPayload) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .cachedHit, payload: payload, segmentID: payload.segmentID, summary: nil, error: nil)
    }

    static func scheduled(segmentID: String) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .requestScheduled, payload: nil, segmentID: segmentID, summary: nil, error: nil)
    }

    static func partial(_ payload: TranslationStreamPayload) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .partial, payload: payload, segmentID: payload.segmentID, summary: nil, error: nil)
    }

    static func final(_ payload: TranslationStreamPayload) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .final, payload: payload, segmentID: payload.segmentID, summary: nil, error: nil)
    }

    static func failure(segmentID: String, error: Error?) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .failed, payload: nil, segmentID: segmentID, summary: nil, error: error)
    }

    static func completed(_ summary: TranslationStreamSummary) -> TranslationStreamEvent {
        TranslationStreamEvent(kind: .completed, payload: nil, segmentID: nil, summary: summary, error: nil)
    }
}
