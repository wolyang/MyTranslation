//
//  FMQueryService.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import Foundation

public struct FMAnswer: Sendable {
    public let improvedText: String?
    public let explanation: String?

    public init(improvedText: String?, explanation: String?) {
        self.improvedText = improvedText
        self.explanation = explanation
    }
}

public protocol FMQueryService: Sendable {
    /// 사용자가 선택한 문장에 대해서만 FM 질의
    func ask(for segment: Segment, currentTranslation: String?, context: FMContext) async throws -> FMAnswer
}

public struct NopQueryService: FMQueryService {
    public func ask(for segment: Segment, currentTranslation: String?, context: FMContext) async throws -> FMAnswer {
        return .init(improvedText: nil, explanation: nil)
    }
}

public struct FMContext: Sendable {
    /// 타겟 문장 앞뒤 문맥 (원문 기준)
    public let previous: [String]
    public let next: [String]
    public init(previous: [String] = [], next: [String] = []) {
        self.previous = previous
        self.next = next
    }
}
