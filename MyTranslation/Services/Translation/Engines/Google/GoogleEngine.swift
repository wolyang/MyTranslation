// File: GoogleEngine.swift
import Foundation

final class GoogleEngine: TranslationEngine {
    let tag: EngineTag = .google
    private let client: GoogleTranslateV2Client
    public init(client: GoogleTranslateV2Client) {
        self.client = client
    }

    func translate(_ segments: [Segment], options: TranslationOptions) async throws -> [TranslationResult] {
        guard !segments.isEmpty else { return [] }

        let batchSize = 100 // v2는 q 최대 128개
        var results: [TranslationResult] = []
        results.reserveCapacity(segments.count)
        let now = Date()

        var i = 0
        while i < segments.count {
            let end = min(i + batchSize, segments.count)
            let slice = Array(segments[i ..< end])
            let texts = slice.map { $0.originalText }

            print("[GoogleEngine] batch i=\(i) count=\(slice.count)")

            // 실제 API 호출
            let translations = try await client.translate(
                texts: texts,
                target: "ko",
                source: "zh-CN",
                format: "html"
            )

            // 개수 불일치 방어
            guard translations.count == slice.count else {
                throw NSError(
                    domain: "GoogleEngine",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Google returned \(translations.count) results for \(slice.count) inputs"]
                )
            }

            for (seg, trans) in zip(slice, translations) {
                results.append(
                    TranslationResult(
                        id: seg.id + ":google",
                        segmentID: seg.id,
                        engine: .google,
                        text: trans.translatedText.htmlUnescaped,
                        residualSourceRatio: 0.0, // 필요시 후처리로 계산
                        createdAt: now
                    )
                )
            }
            i = end
        }

        return results
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
