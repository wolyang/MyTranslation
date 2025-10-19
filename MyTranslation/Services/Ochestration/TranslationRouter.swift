//
//  TranslationRouter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

protocol TranslationRouter {
    @available(*, deprecated, message: "translateStream(_:options:preferredEngine:progress:)를 사용하세요.")
    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult]

    func translateStream(
        segments: [TranslationSegment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary
}
