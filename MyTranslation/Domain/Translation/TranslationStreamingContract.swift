import Foundation

public typealias TranslationEngineID = String
public typealias TranslationSegment = Segment

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "network":
            self = .network
        case "cancelled":
            self = .cancelled
        case "engineFailure":
            let code = try container.decodeIfPresent(String.self, forKey: .code)
            self = .engineFailure(code: code)
        case "decoding":
            self = .decoding
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown TranslationStreamError type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .network:
            try container.encode("network", forKey: .type)
        case .cancelled:
            try container.encode("cancelled", forKey: .type)
        case let .engineFailure(code):
            try container.encode("engineFailure", forKey: .type)
            try container.encodeIfPresent(code, forKey: .code)
        case .decoding:
            try container.encode("decoding", forKey: .type)
        }
    }
}

public struct TranslationStreamEvent: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case cachedHit
        case requestScheduled
        case partial(segment: TranslationStreamPayload)
        case final(segment: TranslationStreamPayload)
        case failed(segmentID: String, error: TranslationStreamError)
        case completed

        private enum CodingKeys: String, CodingKey {
            case type
            case payload
            case segmentID
            case error
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "cachedHit":
                self = .cachedHit
            case "requestScheduled":
                self = .requestScheduled
            case "partial":
                let payload = try container.decode(TranslationStreamPayload.self, forKey: .payload)
                self = .partial(segment: payload)
            case "final":
                let payload = try container.decode(TranslationStreamPayload.self, forKey: .payload)
                self = .final(segment: payload)
            case "failed":
                let segmentID = try container.decode(String.self, forKey: .segmentID)
                let error = try container.decode(TranslationStreamError.self, forKey: .error)
                self = .failed(segmentID: segmentID, error: error)
            case "completed":
                self = .completed
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown TranslationStreamEvent.Kind: \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .cachedHit:
                try container.encode("cachedHit", forKey: .type)
            case .requestScheduled:
                try container.encode("requestScheduled", forKey: .type)
            case let .partial(segment):
                try container.encode("partial", forKey: .type)
                try container.encode(segment, forKey: .payload)
            case let .final(segment):
                try container.encode("final", forKey: .type)
                try container.encode(segment, forKey: .payload)
            case let .failed(segmentID, error):
                try container.encode("failed", forKey: .type)
                try container.encode(segmentID, forKey: .segmentID)
                try container.encode(error, forKey: .error)
            case .completed:
                try container.encode("completed", forKey: .type)
            }
        }
    }

    public let kind: Kind
    public let timestamp: Date

    public init(kind: Kind, timestamp: Date = Date()) {
        self.kind = kind
        self.timestamp = timestamp
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
