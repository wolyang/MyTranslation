// File: DeepLEngine.swift
import Foundation

final class DeepLEngine: TranslationEngine {
    let tag: EngineTag = .deepl
    public let maskPerson: Bool = true
    struct Config { var apiKey: String? = nil }
    init(config: Config = .init()) { }
    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> [TranslationResult] { [] }
}
