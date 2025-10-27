//
//  GoogleTranslateV2Client.swift
//  MyTranslation
//
//  Created by sailor.m on 10/18/25.
//

import Foundation

final class GoogleTranslateV2Client {

    struct Config {
        let apiKey: String
        /// "text" 또는 "html"
        let defaultFormat: String
        init(apiKey: String, defaultFormat: String = "text") {
            self.apiKey = apiKey
            self.defaultFormat = defaultFormat
        }
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// texts: 최대 128개, 바이트 합 100KB 이하(권장)
    func translate(
        texts: [String],
        target: String,
        source: String? = nil,
        format: String? = nil,
        timeout: TimeInterval = 15,
        onTask: ((URLSessionTask) -> Void)? = nil
    ) async throws -> [GoogleV2Translation] {
        var components = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        components.queryItems = [ URLQueryItem(name: "key", value: config.apiKey) ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        let body = RequestBody(
            q: texts,
            target: target,
            source: source,
            format: (format ?? config.defaultFormat)
        )
        req.httpBody = try JSONEncoder().encode(body)

        // dataTask 기반으로 직접 작성
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: req) { data, resp, error in
                if let error {
                    continuation.resume(throwing: GoogleV2Error.transport(error))
                    return
                }

                guard let data, let resp = resp as? HTTPURLResponse else {
                    continuation.resume(throwing: GoogleV2Error.unknown(-1, "HTTP 응답이 아닙니다."))
                    return
                }

                guard (200..<300).contains(resp.statusCode) else {
                    let err = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
                    continuation.resume(throwing: Self.mapHTTPError(status: resp.statusCode, error: err))
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(SuccessEnvelope.self, from: data)
                    print("[Google] query batch size: \(body.q.count)")
                    let translations = decoded.data.translations.map {
                        GoogleV2Translation(
                            translatedText: $0.translatedText,
                            detectedSourceLanguage: $0.detectedSourceLanguage,
                            model: $0.model
                        )
                    }
                    continuation.resume(returning: translations)
                } catch {
                    continuation.resume(throwing: GoogleV2Error.decoding(error.localizedDescription))
                }
            }
            onTask?(task) // 엔진이 cancelBag에 태스크 등록

            // 실제 네트워크 요청 시작
            task.resume()

            // 취소 지원
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000) // 약간의 여유
                if Task.isCancelled {
                    task.cancel()
                }
            }
        }
    }


    // MARK: - Internal

    private static func mapHTTPError(status: Int, error: ErrorEnvelope?) -> GoogleV2Error {
        let message = error?.error.message ?? "상세 메시지 없음"
        switch status {
        case 400: return .invalidArgument(message)
        case 403:
            // 흔한 케이스: "The request is missing a valid API key." -> invalidAPIKey
            if let reasons = error?.error.errors?.map({ $0.reason.lowercased() }), reasons.contains("forbidden"),
               message.lowercased().contains("missing a valid api key") {
                return .invalidAPIKey
            }
            // 쿼터 초과도 403으로 내려오는 편
            if message.lowercased().contains("quota") || message.lowercased().contains("exceeded") {
                return .quotaExceeded
            }
            return .forbidden(message)
        case 404: return .notFound(message)
        case 429: return .rateLimited
        case 500, 502, 503, 504: return .serverError(message)
        default: return .unknown(status, message)
        }
    }

    // MARK: - DTO

    private struct RequestBody: Encodable {
        let q: [String]
        let target: String
        let source: String?
        let format: String?
        let model: String? = nil
    }

    private struct SuccessEnvelope: Decodable {
        let data: DataField
        struct DataField: Decodable {
            let translations: [Trans]
            struct Trans: Decodable {
                let translatedText: String
                let detectedSourceLanguage: String?
                let model: String?
            }
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let code: Int
            let message: String
            let errors: [Item]?
            struct Item: Decodable {
                let domain: String?
                let reason: String
                let message: String?
                let location: String?
            }
        }
    }
}
