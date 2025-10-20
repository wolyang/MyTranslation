// File: AFMEngine.swift
import Foundation

// 1) 앱 내 AFM 클라이언트 어댑터용 프로토콜
// - 실제 구현체는 사용 중인 Foundation Models 호출 래퍼에 맞춰 Adapter를 만드세요.
// - 기대 동작: inputs.count == outputs.count, 순서 보존
public protocol AFMClient {
    struct StreamItem: Sendable {
        let segmentID: String
        let translatedText: String
    }

    /// Returns a stream of translated strings tagged by segment id.
    func translateBatch(
        segments: [Segment],
        style: TranslationStyle,
        preserveFormatting: Bool
    ) async throws -> AsyncThrowingStream<StreamItem, Error>
}

// 2) TranslationEngine 구현
public struct AFMEngine: TranslationEngine {
    public let tag: EngineTag = .afm
    private let client: AFMClient
    public let maskPerson: Bool = false

    public init(client: AFMClient) {
        self.client = client
    }

    public func translate(_ segments: [Segment],
                          options: TranslationOptions) async throws -> AsyncThrowingStream<[TranslationResult], Error> {
        guard segments.isEmpty == false else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        let batchSize = 50
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var index = 0
                    while index < segments.count {
                        let end = min(index + batchSize, segments.count)
                        let slice = Array(segments[index..<end])
                        let stream = try await client.translateBatch(
                            segments: slice,
                            style: options.style,
                            preserveFormatting: options.preserveFormatting
                        )

                        for try await item in stream {
                            guard let segment = segmentMap[item.segmentID] else { continue }
                            let result = TranslationResult(
                                id: segment.id + ":afm",
                                segmentID: segment.id,
                                engine: .afm,
                                text: item.translatedText,
                                residualSourceRatio: 0.0,
                                createdAt: Date()
                            )
                            continuation.yield([result])
                        }

                        index = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
