//
//  Reranker.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

final class RerankerImpl: Reranker {
    func rerank(_ candidates: [TranslationResult], source: String) async throws -> [TranslationResult] {
        return candidates
    }
}
