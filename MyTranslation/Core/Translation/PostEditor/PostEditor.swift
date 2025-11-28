//
//  PostEditor.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

/// ko→ko 후편집을 배치로 수행하는 클라이언트
public protocol PostEditor: Sendable {
    /// inputs.count == outputs.count, 순서 보존
    func postEditBatch(texts: [String],
                       style: TranslationStyle) async throws -> [String]
}
