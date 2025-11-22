//
//  MaskedPack.swift
//  MyTranslation
//
//  Created by sailor.m on 10/17/25.
//

public struct MaskedPack: Sendable {
    public let seg: Segment
    public let masked: String
    public let tags: [String]
    public let locks: [String: LockInfo]
    /// preMask 용어 토큰 → GlossaryEntry 매핑 (range 추적용)
    public let tokenEntries: [String: GlossaryEntry]
    /// 마스킹된 텍스트에서의 용어 위치 정보
    public let maskedRanges: [TermRange]
}
