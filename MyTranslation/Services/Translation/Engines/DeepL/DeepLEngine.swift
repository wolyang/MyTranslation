// File: DeepLEngine.swift
import Foundation

final class DeepLEngine: TranslationEngine {
    let tag: EngineTag = .deepl
    struct Config { var apiKey: String? = nil }
    init(config: Config = .init()) { }
    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> [TranslationResult] { [] }
}
