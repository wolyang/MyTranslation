// File: AFMTranslationService.swift
import Foundation
import Translation

final class AFMTranslationService: AFMClient {
    private weak var session: TranslationSession?
    private var prepared = false

    init() { }

    @MainActor
    func attach(session: TranslationSession) {
        self.session = session
        self.prepared = false
    }

    @MainActor
    func translateBatch(
        segments: [Segment],
        style: TranslationStyle,
        preserveFormatting: Bool
    ) async throws -> AsyncThrowingStream<AFMClient.StreamItem, Error> {
        guard segments.isEmpty == false else {
            throw TranslationEngineError.emptySegments
        }

        guard let session else {
            throw NSError(
                domain: "AFMTranslationService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "TranslationSession not attached"]
            )
        }
        if prepared == false {
            do {
                try await session.prepareTranslation()
                prepared = true
            } catch {
                // 원인 파악 위한 로깅 강화
                print("AFM prepareTranslation failed:", (error as NSError).domain, (error as NSError).code, (error as NSError).localizedDescription)
                throw error
            }
        }

        let requests: [TranslationSession.Request] = segments.map { segment in
            TranslationSession.Request(
                text: segment.originalText,
                clientIdentifier: segment.id
            )
        }

        let batch = try session.translate(batch: requests)

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var iterator = batch.makeAsyncIterator()
                do {
                    while let response = try await iterator.next() {
                        guard let identifier = response.clientIdentifier else { continue }
                        let translated = response.targetText
                        print("[AFM][stream] id=\(identifier) => \(translated)")
                        continuation.yield(.init(segmentID: identifier, translatedText: translated))
                    }
                    continuation.finish()
                } catch {
                    let ns = error as NSError
                    print("[AFM][ERR][stream] domain=\(ns.domain) code=\(ns.code) msg=\(ns.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
