//
//  LockInfo.swift
//  MyTranslation
//
//  Created by sailor.m on 10/17/25.
//

public struct LockInfo: Sendable {
    public let placeholder: String    // 토큰
    public let target: String         // 최종 한국어 용어
    public let endsWithBatchim: Bool  // 받침 유무
    public let endsWithRieul: Bool    // ㄹ 받침
    public let isAppellation: Bool    // 호칭 여부
    public init(placeholder: String, target: String, endsWithBatchim: Bool, endsWithRieul: Bool, isAppellation: Bool) {
        self.placeholder = placeholder
        self.target = target
        self.endsWithBatchim = endsWithBatchim
        self.endsWithRieul = endsWithRieul
        self.isAppellation = isAppellation
    }
}
