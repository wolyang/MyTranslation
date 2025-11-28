// File: AFMEngine.swift
import Foundation

// 1) 앱 내 AFM 클라이언트 어댑터용 프로토콜
// - 실제 구현체는 사용 중인 Foundation Models 호출 래퍼에 맞춰 Adapter를 만드세요.
// - 기대 동작: inputs.count == outputs.count, 순서 보존
public protocol AFMClient {
    /// Returns a stream of translated strings tagged by segment id.
    func translateBatch(
        segments: [Segment],
        style: TranslationStyle,
        preserveFormatting: Bool
    ) async throws -> AsyncThrowingStream<(segmentID: String, translatedText: String), Error>
}

// 2) TranslationEngine 구현
public struct AFMEngine: TranslationEngine {
    public let tag: EngineTag = .afm
    private let client: AFMClient
    public let maskPerson: Bool = false

    public init(client: AFMClient) {
        self.client = client
    }

    public func translate(runID: String,
                          _ segments: [Segment],
                          options: TranslationOptions) async throws -> AsyncThrowingStream<[TranslationResult], Error> {
        guard segments.isEmpty == false else {
            throw TranslationEngineError.emptySegments
        }

        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let bag = RouterCancellationCenter.shared.bag(for: runID)

        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let batchSize = 50
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
                            try Task.checkCancellation()
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
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            // runID 취소 -> worker.cancel()
            bag.insert { worker.cancel() }
            
            // 스트림 종료 시 안전 해제
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }
}
