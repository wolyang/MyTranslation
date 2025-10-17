//
//  GooglePublicModels.swift
//  MyTranslation
//
//  Created by sailor.m on 10/18/25.
//

import Foundation

struct GoogleV2Translation {
    let translatedText: String
    let detectedSourceLanguage: String?
    let model: String?
}

enum GoogleV2Error: Error, CustomStringConvertible {
    case invalidAPIKey              // 403 forbidden + "missing a valid API key"
    case quotaExceeded              // 403 quota exceeded
    case rateLimited                // 429
    case invalidArgument(String)    // 400
    case forbidden(String)          // 403 (기타)
    case notFound(String)           // 404
    case serverError(String)        // 5xx
    case decoding(String)           // JSON 파싱 실패
    case transport(Error)           // 네트워크 계층
    case unknown(Int, String)

    var description: String {
        switch self {
        case .invalidAPIKey: return "API 키가 유효하지 않거나 허용되지 않았습니다."
        case .quotaExceeded: return "프로젝트 할당량을 초과했습니다."
        case .rateLimited:   return "요청이 너무 많습니다(429)."
        case .invalidArgument(let m): return "잘못된 요청(400): \(m)"
        case .forbidden(let m):      return "허용되지 않음(403): \(m)"
        case .notFound(let m):       return "리소스를 찾을 수 없음(404): \(m)"
        case .serverError(let m):    return "서버 오류(5xx): \(m)"
        case .decoding(let m):       return "응답 파싱 실패: \(m)"
        case .transport(let e):      return "네트워크 오류: \(e)"
        case .unknown(let c, let m): return "알 수 없는 오류(\(c)): \(m)"
        }
    }
}
