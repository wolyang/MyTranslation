// File: AFMEngine.swift
import Foundation

// 1) 앱 내 AFM 클라이언트 어댑터용 프로토콜
// - 실제 구현체는 사용 중인 Foundation Models 호출 래퍼에 맞춰 Adapter를 만드세요.
// - 기대 동작: inputs.count == outputs.count, 순서 보존
public protocol AFMClient {
    /// Returns translated strings in the same order as inputs
    func translateBatch(texts: [String],
                        style: TranslationStyle,
                        preserveFormatting: Bool) async throws -> [String]
}

// 2) TranslationEngine 구현
public struct AFMEngine: TranslationEngine {
    public let tag: EngineTag = .afm
    private let client: AFMClient

    public init(client: AFMClient) {
        self.client = client
    }

    public func translate(_ segments: [Segment],
                          options: TranslationOptions) async throws -> [TranslationResult] {
        guard !segments.isEmpty else { return [] }

        // 안전한 배치 크기(필요시 조정)
        let batchSize = 50
        var results: [TranslationResult] = []
        results.reserveCapacity(segments.count)
        let now = Date()

        var i = 0
        while i < segments.count {
            let end = min(i + batchSize, segments.count)
            let slice = Array(segments[i..<end])
            let texts = slice.map { $0.originalText }

            let sliceLens = slice.map { $0.originalText.count }
            let batchChars = sliceLens.reduce(0,+)
            let maxInBatch = sliceLens.max() ?? 0
//            print("[AFMEngine] batch i=\(i) count=\(slice.count) chars=\(batchChars) maxLen=\(maxInBatch)")
            
            let outs = try await client.translateBatch(
                texts: texts,
                style: options.style,
                preserveFormatting: options.preserveFormatting
            )

            // 길이 불일치 방어
            if outs.count != slice.count {
                throw NSError(domain: "AFMEngine",
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "AFMClient returned \(outs.count) results for \(slice.count) inputs"])
            }

            for (seg, out) in zip(slice, outs) {
                results.append(
                    TranslationResult(
                        id: seg.id + ":afm",
                        segmentID: seg.id,
                        engine: .afm,
                        text: out,
                        residualSourceRatio: 0.0,     // 필요 시 후처리로 계산
                        createdAt: now
                    )
                )
            }
            i = end
        }
        return results
    }
}
