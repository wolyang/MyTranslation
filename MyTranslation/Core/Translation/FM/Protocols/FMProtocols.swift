//
//  FMProtocols.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

/// 교차엔진 결과 대조용 (존재하면 사용, 없으면 스킵)
public protocol ResultComparer: Sendable {
    func compare(_ candidates: [TranslationResult], source: String) async throws -> TranslationResult?
}

/// 의미/유창성 재랭킹 (Minimum Bayes Risk 유사)
public protocol Reranker: Sendable {
    func rerank(_ candidates: [TranslationResult], source: String) async throws -> [TranslationResult]
}
