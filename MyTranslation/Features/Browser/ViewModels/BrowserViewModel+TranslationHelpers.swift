import Foundation
import WebKit

// 전체/부분 번역 스코프
enum TranslationScop: Sendable {
    case full
    case partial([Segment])
}

enum TranslationSessionError: Error {
    case prepareFailed
    case missingRequired
}

struct PreparedState: Sendable {
    let url: URL
    let engineID: TranslationEngineID
    let segments: [Segment]
}

func _id(_ id: UUID?) -> String { id?.uuidString ?? "nil" }
func _url(_ url: URL?) -> String { url?.absoluteString ?? "nil" }
