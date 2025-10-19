import Foundation

public typealias TranslationEngineID = String

public struct TranslationStreamPayload: Codable, Sendable, Equatable {
    public let segmentID: String
    public let originalText: String
    public let translatedText: String?
    public let engineID: TranslationEngineID
    public let sequence: Int

    public init(
        segmentID: String,
        originalText: String,
        translatedText: String?,
        engineID: TranslationEngineID,
        sequence: Int
    ) {
        self.segmentID = segmentID
        self.originalText = originalText
        self.translatedText = translatedText
        self.engineID = engineID
        self.sequence = sequence
    }
}

public enum TranslationStreamError: Codable, Sendable, Equatable {
    case network
    case cancelled
    case engineFailure(code: String?)
    case decoding

    private enum CodingKeys: String, CodingKey {
        case type
        case code
    }

    private enum ErrorType: String, Codable {
        case network
        case cancelled
        case engineFailure
        case decoding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ErrorType.self, forKey: .type)
        switch type {
        case .network:
            self = .network
        case .cancelled:
            self = .cancelled
        case .engineFailure:
            let code = try container.decodeIfPresent(String.self, forKey: .code)
            self = .engineFailure(code: code)
        case .decoding:
            self = .decoding
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .network:
            try container.encode(ErrorType.network, forKey: .type)
        case .cancelled:
            try container.encode(ErrorType.cancelled, forKey: .type)
        case let .engineFailure(code):
            try container.encode(ErrorType.engineFailure, forKey: .type)
            try container.encodeIfPresent(code, forKey: .code)
        case .decoding:
            try container.encode(ErrorType.decoding, forKey: .type)
        }
    }
}

public struct TranslationStreamEvent: Codable, Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        case cachedHit
        case requestScheduled
        case partial(segment: TranslationStreamPayload)
        case final(segment: TranslationStreamPayload)
        case failed(segmentID: String, error: TranslationStreamError)
        case completed
    }

    public let kind: Kind
    public let timestamp: Date

    public init(kind: Kind, timestamp: Date) {
        self.kind = kind
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case timestamp
    }

    private enum KindCodingKeys: String, CodingKey {
        case type
        case segment
        case segmentID
        case error
    }

    private enum KindType: String, Codable {
        case cachedHit
        case requestScheduled
        case partial
        case final
        case failed
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let kindContainer = try container.nestedContainer(keyedBy: KindCodingKeys.self, forKey: .kind)
        let type = try kindContainer.decode(KindType.self, forKey: .type)
        switch type {
        case .cachedHit:
            kind = .cachedHit
        case .requestScheduled:
            kind = .requestScheduled
        case .partial:
            let payload = try kindContainer.decode(TranslationStreamPayload.self, forKey: .segment)
            kind = .partial(segment: payload)
        case .final:
            let payload = try kindContainer.decode(TranslationStreamPayload.self, forKey: .segment)
            kind = .final(segment: payload)
        case .failed:
            let segmentID = try kindContainer.decode(String.self, forKey: .segmentID)
            let error = try kindContainer.decode(TranslationStreamError.self, forKey: .error)
            kind = .failed(segmentID: segmentID, error: error)
        case .completed:
            kind = .completed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        var kindContainer = container.nestedContainer(keyedBy: KindCodingKeys.self, forKey: .kind)
        switch kind {
        case .cachedHit:
            try kindContainer.encode(KindType.cachedHit, forKey: .type)
        case .requestScheduled:
            try kindContainer.encode(KindType.requestScheduled, forKey: .type)
        case let .partial(segment):
            try kindContainer.encode(KindType.partial, forKey: .type)
            try kindContainer.encode(segment, forKey: .segment)
        case let .final(segment):
            try kindContainer.encode(KindType.final, forKey: .type)
            try kindContainer.encode(segment, forKey: .segment)
        case let .failed(segmentID, error):
            try kindContainer.encode(KindType.failed, forKey: .type)
            try kindContainer.encode(segmentID, forKey: .segmentID)
            try kindContainer.encode(error, forKey: .error)
        case .completed:
            try kindContainer.encode(KindType.completed, forKey: .type)
        }
    }
}

public struct TranslationStreamSummary: Codable, Sendable, Equatable {
    public let totalCount: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let cachedCount: Int

    public init(totalCount: Int, succeededCount: Int, failedCount: Int, cachedCount: Int) {
        self.totalCount = totalCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.cachedCount = cachedCount
    }
}
