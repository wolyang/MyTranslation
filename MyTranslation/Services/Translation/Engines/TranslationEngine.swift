//
//  TranslationEngine.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

protocol TranslationEngine {
    var tag: EngineTag { get }
    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> [TranslationResult]
    var maskPerson: Bool { get }
}
