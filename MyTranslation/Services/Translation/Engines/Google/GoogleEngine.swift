// File: GoogleEngine.swift
import Foundation

final class GoogleEngine: TranslationEngine {
    let tag: EngineTag = .google
    struct Config { var credentialPath: String? = nil }
    init(config: Config = .init()) { }
    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> [TranslationResult] { [] }
}
