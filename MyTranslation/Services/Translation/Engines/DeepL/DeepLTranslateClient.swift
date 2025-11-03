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
        let defaultTarget: String?
        let defaultSource: String?

        init(apiKey: String, useFreeTier: Bool = true, defaultTarget: String? = nil, defaultSource: String? = nil) {
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
        case preferMore = "prefer_more"
        case preferLess = "prefer_less"
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(config.apiKey)", forHTTPHeaderField: "Authorization")

        struct Payload: Encodable {
            let text: [String]
            let target_lang: String
            let source_lang: String?
            let preserve_formatting: Bool?
            let formality: String?
        }

        let payload = Payload(
            text: texts,
            target_lang: (target ?? config.defaultTarget ?? "").uppercased(),
            source_lang: (source ?? config.defaultSource)?.uppercased(),
            preserve_formatting: preserveFormatting,
            formality: formality?.rawValue
        )

        request.httpBody = try JSONEncoder().encode(payload)
        
        func logRequest(_ req: URLRequest) {
            let method = req.httpMethod ?? "GET"
            let url = req.url?.absoluteString ?? "nil"
            print("➡️ \(method) \(url)")
            print("➡️ headers:", req.allHTTPHeaderFields ?? [:])

            if let body = req.httpBody {
                // JSON 시도 → 실패하면 일반 문자열
                if let json = try? JSONSerialization.jsonObject(with: body),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
                   let s = String(data: pretty, encoding: .utf8) {
                    print("➡️ body(json):\n\(s)")
                } else {
                    print("➡️ body(raw):", String(data: body, encoding: .utf8) ?? "<non-utf8 \(body.count) bytes>")
                }
            } else if let stream = req.httpBodyStream {
                print("➡️ body: httpBodyStream(\(stream))  // stream은 여기선 덤프 어려움")
            } else {
                print("➡️ body: <nil>")
            }
        }
        logRequest(request)

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
                    if let decodedError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                        let errMsg = decodedError.error?.message ?? decodedError.message ?? "상세 메시지 없음"
                        continuation.resume(throwing: Self.mapHTTPError(status: http.statusCode, message: errMsg))
                    } else {
                        continuation.resume(throwing: Self.mapHTTPError(status: http.statusCode, message: "에러 디코딩 실패"))
                    }
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
        let error: ErrorBody?
        struct ErrorBody: Decodable {
            let message: String
        }
        let message: String?
    }
}
