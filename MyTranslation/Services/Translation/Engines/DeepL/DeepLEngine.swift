// File: DeepLEngine.swift
import Foundation

final class DeepLEngine: TranslationEngine {
    let tag: EngineTag = .deepl
    public let maskPerson: Bool = true

    private let client: DeepLTranslateClient

    init(client: DeepLTranslateClient) {
        self.client = client
    }

    func translate(runID: String, _ segments: [Segment], options: TranslationOptions) async throws -> AsyncThrowingStream<[TranslationResult], Error> {
        guard segments.isEmpty == false else {
            throw TranslationEngineError.emptySegments
        }

        let bag = RouterCancellationCenter.shared.bag(for: runID)

        return AsyncThrowingStream { continuation in
            let lock = NSLock()
            var finished = false
            let finishOnce: (Result<Void, Error>) -> Void = { result in
                lock.lock(); defer { lock.unlock() }
                guard finished == false else { return }
                finished = true
                switch result {
                case .success: continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            }

            let worker = Task {
                do {
                    let batchSize = 40
                    var index = 0
                    while index < segments.count {
                        try Task.checkCancellation()

                        let end = min(index + batchSize, segments.count)
                        let slice = Array(segments[index..<end])
                        let texts = slice.map { $0.originalText }

                        let translations = try await client.translate(
                            texts: texts,
                            preserveFormatting: options.preserveFormatting,
                            formality: mapFormality(style: options.style),
                            onTask: { task in
                                bag.insert { task.cancel() }
                            }
                        )

                        try Task.checkCancellation()

                        guard translations.count == slice.count else {
                            throw NSError(
                                domain: "DeepLEngine",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "DeepL returned \(translations.count) results for \(slice.count) inputs"]
                            )
                        }

                        let timestamp = Date()
                        let batch = zip(slice, translations).map { segment, translation in
                            TranslationResult(
                                id: segment.id + ":deepl",
                                segmentID: segment.id,
                                engine: .deepl,
                                text: translation.text,
                                residualSourceRatio: 0.0,
                                createdAt: timestamp
                            )
                        }

                        continuation.yield(batch)
                        index = end
                    }
                    finishOnce(.success(()))
                } catch {
                    finishOnce(.failure(error))
                }
            }

            bag.insert {
                worker.cancel()
            }
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    private func mapFormality(style: TranslationStyle) -> DeepLTranslateClient.Formality? {
        switch style {
        case .colloquialKo:
            return .less
        case .neutralDictionaryTone:
            return .defaultTone
        }
    }
}
