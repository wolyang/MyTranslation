// Services/Translation/FM/Consistency/CrossEngineComparer.swift
// Services/Translation/FM/Consistency/CrossEngineComparer.swift
import Foundation
import FoundationModels

@Generable
struct Pick {
    @Guide(description: "선택된 후보의 인덱스", .minimum(0))
    var index: Int
}

public final class CrossEngineComparer: ResultComparer {
    private let fm: FMModelManaging
    public init(fm: FMModelManaging) { self.fm = fm }

    public func compare(_ candidates: [TranslationResult], source: String) async throws -> TranslationResult? {
        guard candidates.count >= 2 else { return candidates.first }
        let list = candidates.enumerated()
            .map { "\($0.offset): " + $0.element.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")

        let prompt = """
        원문과 가장 의미가 정확히 일치하는 번역 후보의 인덱스를 고르라.
        동률이면 더 자연스러운 한국어를 선택하라.

        원문:
        \(source)

        후보들:
        \(list)
        """
        let pick: Pick = try await fm.generate(prompt: prompt)
        return candidates.indices.contains(pick.index) ? candidates[pick.index] : candidates.first
    }
}
