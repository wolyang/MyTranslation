//
//  SegmentPieces.swift
//  MyTranslation
//
//  Created by Codex on 11/22/25.
//

import Foundation

/// 세그먼트 내 텍스트와 용어 조각 단위를 표현한다.
public struct SegmentPieces: Sendable {
    public let segmentID: String
    public let pieces: [Piece]

    public enum Piece: Sendable {
        case text(String)
        case term(GlossaryEntry)
    }

    /// 감지된 GlossaryEntry 전체.
    public var detectedTerms: [GlossaryEntry] {
        pieces.compactMap {
            if case .term(let entry) = $0 { return entry }
            return nil
        }
    }

    public func maskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { $0.preMask }
    }

    public func unmaskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { !$0.preMask }
    }
}
