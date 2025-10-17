//
//  LockInfo.swift
//  MyTranslation
//
//  Created by sailor.m on 10/17/25.
//

public struct LockInfo: Sendable {
    public let placeholder: String    // "⟪T1⟫"
    public let target: String         // 최종 한국어 용어
    public let endsWithBatchim: Bool  // 받침 유무
    public let endsWithRieul: Bool    // ㄹ 받침
    public let category: TermCategory // 용어 카테고리
    public init(placeholder: String, target: String, endsWithBatchim: Bool, endsWithRieul: Bool, category: TermCategory) {
        self.placeholder = placeholder
        self.target = target
        self.endsWithBatchim = endsWithBatchim
        self.endsWithRieul = endsWithRieul
        self.category = category
    }
}
