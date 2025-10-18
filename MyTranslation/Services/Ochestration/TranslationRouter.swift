//
//  TranslationRouter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

protocol TranslationRouter {
    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult]
}
