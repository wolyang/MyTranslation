// File: DeepLTranslateClient.swift
import Foundation

struct DeepLTranslation {
    let text: String
    let detectedSourceLanguage: String?
}

enum DeepLError: Error, CustomStringConvertible {
    case unauthorized
    case invalidRequest(String)
    case rateLimited
    case quotaExceeded
    case serverError(String)
    case decoding(String)
    case transport(Error)
    case unknown(Int, String)

    var description: String {
        switch self {
        case .unauthorized: return "인증에 실패했습니다. DeepL API 키를 확인하세요."
        case .invalidRequest(let message): return "잘못된 요청입니다: \(message)"
        case .rateLimited: return "요청이 너무 많습니다(429)."
        case .quotaExceeded: return "요청 한도를 초과했습니다."
        case .serverError(let message): return "DeepL 서버 오류: \(message)"
        case .decoding(let message): return "DeepL 응답 파싱 실패: \(message)"
        case .transport(let error): return "네트워크 오류: \(error.localizedDescription)"
        case .unknown(let code, let message): return "알 수 없는 오류(\(code)): \(message)"
        }
    }
}

final class DeepLTranslateClient {
    struct Config {
        let apiKey: String
        let useFreeTier: Bool
        let defaultTarget: String
        let defaultSource: String?

        init(apiKey: String, useFreeTier: Bool = false, defaultTarget: String = "KO", defaultSource: String? = "ZH") {
            self.apiKey = apiKey
            self.useFreeTier = useFreeTier
            self.defaultTarget = defaultTarget
            self.defaultSource = defaultSource
        }

        var baseURL: URL {
            if useFreeTier {
                return URL(string: "https://api-free.deepl.com/v2/translate")!
            } else {
                return URL(string: "https://api.deepl.com/v2/translate")!
            }
        }
    }

    enum Formality: String {
        case defaultTone = "default"
        case more = "more"
        case less = "less"
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func translate(
        texts: [String],
        target: String? = nil,
        source: String? = nil,
        preserveFormatting: Bool? = nil,
        formality: Formality? = nil,
        timeout: TimeInterval = 15,
        onTask: ((URLSessionTask) -> Void)? = nil
    ) async throws -> [DeepLTranslation] {
        var request = URLRequest(url: config.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var items: [URLQueryItem] = texts.map { URLQueryItem(name: "text", value: $0) }
        items.append(URLQueryItem(name: "target_lang", value: (target ?? config.defaultTarget).uppercased()))
        if let src = (source ?? config.defaultSource) {
            items.append(URLQueryItem(name: "source_lang", value: src.uppercased()))
        }
        if let preserveFormatting {
            items.append(URLQueryItem(name: "preserve_formatting", value: preserveFormatting ? "1" : "0"))
        }
        if let formality {
            items.append(URLQueryItem(name: "formality", value: formality.rawValue))
        }

        var components = URLComponents()
        components.queryItems = items
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: DeepLError.transport(error))
                    return
                }

                guard let data, let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: DeepLError.unknown(-1, "HTTP 응답이 아닙니다."))
                    return
                }

                guard (200..<300).contains(http.statusCode) else {
                    let err = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message ?? "상세 메시지 없음"
                    continuation.resume(throwing: Self.mapHTTPError(status: http.statusCode, message: err))
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(SuccessEnvelope.self, from: data)
                    let translations = decoded.translations.map {
                        DeepLTranslation(
                            text: $0.text,
                            detectedSourceLanguage: $0.detectedSourceLanguage
                        )
                    }
                    continuation.resume(returning: translations)
                } catch {
                    continuation.resume(throwing: DeepLError.decoding(error.localizedDescription))
                }
            }

            onTask?(task)
            task.resume()

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000)
                if Task.isCancelled {
                    task.cancel()
                }
            }
        }
    }

    private static func mapHTTPError(status: Int, message: String) -> DeepLError {
        switch status {
        case 400: return .invalidRequest(message)
        case 401: return .unauthorized
        case 403: return .quotaExceeded
        case 429: return .rateLimited
        case 456: return .quotaExceeded
        case 500, 502, 503, 504: return .serverError(message)
        default: return .unknown(status, message)
        }
    }

    private struct SuccessEnvelope: Decodable {
        let translations: [Translation]
        struct Translation: Decodable {
            let detectedSourceLanguage: String?
            let text: String

            private enum CodingKeys: String, CodingKey {
                case detectedSourceLanguage = "detected_source_language"
                case text
            }
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
        struct ErrorBody: Decodable {
            let message: String
        }
    }
}
