//
//  TranslationEngine.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

protocol TranslationEngine {
    var tag: EngineTag { get }
    func translate(runID: String, _ segments: [Segment], options: TranslationOptions) async throws -> AsyncThrowingStream<[TranslationResult], Error>
}

enum TranslationEngineError: Error {
    case emptySegments
}
