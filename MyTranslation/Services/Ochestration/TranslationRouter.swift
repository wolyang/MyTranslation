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
        preferredEngine: EngineTag
    ) -> AsyncThrowingStream<TranslationStreamEvent, Error>
}

enum TranslationStreamEvent {
    case segments([Segment])
    case result(segment: Segment, result: TranslationResult)
    case finished
}

extension TranslationRouter {
    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult] {
        var results: [TranslationResult] = []
        for try await event in translateStream(segments: segments, options: options, preferredEngine: preferredEngine) {
            if case let .result(_, result) = event {
                results.append(result)
            }
        }
        return results
    }
}
