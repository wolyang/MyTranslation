import Foundation
@testable import MyTranslation

final class MockTranslationEngine: TranslationEngine {
    let tag: EngineTag

    // Configuration
    var shouldThrowError = false
    var errorToThrow: Error?
    var translationDelay: TimeInterval = 0
    var resultsToReturn: [TranslationResult] = []
    var streamedResults: [[TranslationResult]] = []

    // Call tracking
    private(set) var translateCallCount = 0
    private(set) var lastRunID: String?
    private(set) var lastSegments: [Segment]?
    private(set) var lastOptions: TranslationOptions?

    init(tag: EngineTag) {
        self.tag = tag
    }

    func configureTo(streamResults: [[TranslationResult]]) {
        streamedResults = streamResults
    }

    func configureTo(throwError error: Error) {
        shouldThrowError = true
        errorToThrow = error
    }

    func translate(
        runID: String,
        _ segments: [Segment],
        options: TranslationOptions
    ) async throws -> AsyncThrowingStream<[TranslationResult], Error> {
        translateCallCount += 1
        lastRunID = runID
        lastSegments = segments
        lastOptions = options

        if segments.isEmpty {
            throw TranslationEngineError.emptySegments
        }
        if shouldThrowError {
            throw errorToThrow ?? TranslationEngineError.emptySegments
        }

        let batches = streamedResults.isEmpty
        ? (resultsToReturn.isEmpty ? [] : [resultsToReturn])
        : streamedResults

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try Task.checkCancellation()
                    if translationDelay > 0 {
                        try await Task.sleep(
                            nanoseconds: UInt64(translationDelay * 1_000_000_000)
                        )
                    }

                    for batch in batches where batch.isEmpty == false {
                        try Task.checkCancellation()
                        if translationDelay > 0 {
                            try await Task.sleep(
                                nanoseconds: UInt64(translationDelay * 1_000_000_000)
                            )
                        }
                        continuation.yield(batch)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
