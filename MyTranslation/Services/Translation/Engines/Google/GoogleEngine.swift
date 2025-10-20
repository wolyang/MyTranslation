// File: GoogleEngine.swift
import Foundation

final class GoogleEngine: TranslationEngine {
    let tag: EngineTag = .google
    public let maskPerson: Bool = true
    private let client: GoogleTranslateV2Client
    public init(client: GoogleTranslateV2Client) {
        self.client = client
    }

    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> AsyncThrowingStream<TranslationResult, Error> {
        guard segments.isEmpty == false else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        let batchSize = 100 // v2는 q 최대 128개

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var index = 0
                    while index < segments.count {
                        let end = min(index + batchSize, segments.count)
                        let slice = Array(segments[index ..< end])
                        let texts = slice.map { $0.originalText }

                        let translations = try await client.translate(
                            texts: texts,
                            target: "ko",
                            source: "zh-CN",
                            format: "html"
                        )

                        guard translations.count == slice.count else {
                            throw NSError(
                                domain: "GoogleEngine",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Google returned \(translations.count) results for \(slice.count) inputs"]
                            )
                        }

                        for (seg, trans) in zip(slice, translations) {
                            let result = TranslationResult(
                                id: seg.id + ":google",
                                segmentID: seg.id,
                                engine: .google,
                                text: trans.translatedText.htmlUnescaped,
                                residualSourceRatio: 0.0,
                                createdAt: Date()
                            )
                            continuation.yield(result)
                        }

                        index = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

extension String {
    /// Google v2 응답용: HTML 엔티티 언이스케이프 (&quot;, &#39; 등)
    var htmlUnescaped: String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        } else {
            return self
        }
    }
}
