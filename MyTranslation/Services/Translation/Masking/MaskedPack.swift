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
}
