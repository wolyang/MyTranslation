// File: GoogleEngine.swift
import Foundation

final class GoogleEngine: TranslationEngine {
    let tag: EngineTag = .google
    public let maskPerson: Bool = true
    private let client: GoogleTranslateV2Client
    public init(client: GoogleTranslateV2Client) {
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
                    let batchSize = 100
                    var index = 0

                    while index < segments.count {
                        try Task.checkCancellation()
                        
                        let end = min(index + batchSize, segments.count)
                        let slice = Array(segments[index..<end])
                        let texts = slice.map { $0.originalText }

                        let translations = try await client.translate(
                            texts: texts,
                            target: mapTargetLanguage(options.targetLanguage),
                            source: mapSourceLanguage(options.sourceLanguage),
                            format: "html",
                            onTask: { task in
                                bag.insert { task.cancel() }
                            }
                        )
                        
                        try Task.checkCancellation()

                        guard translations.count == slice.count else {
                            throw NSError(
                                domain: "GoogleEngine",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Google returned \(translations.count) results for \(slice.count) inputs"]
                            )
                        }

                        let timestamp = Date()
                        let batch = zip(slice, translations).map { seg, trans in
                            TranslationResult(
                                id: seg.id + ":google",
                                segmentID: seg.id,
                                engine: .google,
                                text: trans.translatedText.htmlUnescaped,
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

            // runID 취소 -> worker 취소
            bag.insert {
                worker.cancel()
            }
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    /// 애플 언어 코드를 Google 번역의 대상 언어 코드로 변환한다.
    private func mapTargetLanguage(_ language: AppLanguage) -> String {
        mapLanguage(language)
    }

    /// 출발 언어가 고정된 경우 Google 번역 코드로 변환한다. 자동 감지면 nil.
    private func mapSourceLanguage(_ selection: SourceLanguageSelection) -> String? {
        guard let language = selection.resolved else { return nil }
        return mapLanguage(language)
    }

    /// Google 번역 언어 코드 매핑의 공통 로직.
    private func mapLanguage(_ language: AppLanguage) -> String {
        guard let code = language.languageCode?.lowercased() else { return language.code }
        switch code {
        case "zh":
            if language.scriptCode?.lowercased() == "hant" {
                return "zh-TW"
            }
            return "zh-CN"
        case "ko":
            return "ko"
        case "ja":
            return "ja"
        case "en":
            if let region = language.regionCode?.uppercased() {
                return "en-\(region)"
            }
            return "en"
        case "fr":
            return "fr"
        case "de":
            return "de"
        case "es":
            return "es"
        default:
            return language.languageCode ?? language.code
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
