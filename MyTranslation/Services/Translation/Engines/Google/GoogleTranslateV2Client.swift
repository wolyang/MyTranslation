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
        timeout: TimeInterval = 15
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

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw GoogleV2Error.unknown(-1, "HTTP 응답이 아닙니다.")
            }
            if (200..<300).contains(http.statusCode) {
                do {
                    let decoded = try JSONDecoder().decode(SuccessEnvelope.self, from: data)
                    return decoded.data.translations.map {
                        GoogleV2Translation(
                            translatedText: $0.translatedText,
                            detectedSourceLanguage: $0.detectedSourceLanguage,
                            model: $0.model
                        )
                    }
                } catch {
                    throw GoogleV2Error.decoding(error.localizedDescription)
                }
            } else {
                // 에러 바디 파싱해서 매핑
                let err = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
                throw mapHTTPError(status: http.statusCode, error: err)
            }
        } catch {
            throw GoogleV2Error.transport(error)
        }
    }

    // MARK: - Internal

    private func mapHTTPError(status: Int, error: ErrorEnvelope?) -> GoogleV2Error {
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
