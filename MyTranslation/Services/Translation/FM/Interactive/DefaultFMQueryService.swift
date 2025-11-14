//
//  DefaultFMQueryService.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import Foundation

public actor DefaultFMQueryService: FMQueryService {
    private let fm: FMModelManaging
    public init(fm: FMModelManaging) { self.fm = fm }

    public func ask(for segment: Segment,
                    currentTranslation: String?,
                    context: FMContext) async throws -> FMAnswer {

        // FM 사용가능 아니면 폴백: 개선안 없이 종료
        guard await fm.isAvailable else {
            return FMAnswer(improvedText: nil, explanation: "On-device AI unavailable.")
        }

        // 문맥을 간단히 패킹
        let prev = context.previous.joined(separator: " ")
        let next = context.next.joined(separator: " ")
        let current = currentTranslation ?? "(없음)"

        let prompt = """
        다음은 한 문단의 일부 문장들입니다.

        [이전 문맥]
        \(prev)

        [타겟 문장 원문]
        \(segment.originalText)

        [다음 문맥]
        \(next)

        [현재 타겟 번역]
        \(current)

        요청:
        1) 위 문맥을 반영하여 '타겟 문장'의 한국어 번역 1줄만 제시
        2) (선택) 간단한 이유 1줄
        출력 양식(정확히 지키시오):
        - 번역: <텍스트>
        - 이유: <텍스트 또는 빈칸>
        """

        let raw: String = try await fm.complete(prompt: prompt)
        // 매우 보수적인 파서
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        func extract(_ key: String) -> String? {
            guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) }) else { return nil }
            let s = line.replacingOccurrences(of: key, with: "")
            return s.trimmingCharacters(in: .whitespaces)
        }
        let improved = extract("- 번역:")?.nilIfEmpty
        let reason = extract("- 이유:")?.nilIfEmpty

        return FMAnswer(improvedText: improved, explanation: reason)
    }
}
