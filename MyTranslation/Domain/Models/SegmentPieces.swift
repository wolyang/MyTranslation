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
    public let originalText: String
    public let pieces: [Piece]

    public enum Piece: Sendable {
        case text(String, range: Range<String.Index>)
        case term(GlossaryEntry, range: Range<String.Index>)
    }

    /// 감지된 GlossaryEntry 전체.
    public var detectedTerms: [GlossaryEntry] {
        pieces.compactMap {
            if case .term(let entry, _) = $0 { return entry }
            return nil
        }
    }

    public func maskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { $0.preMask }
    }

    public func unmaskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { !$0.preMask }
    }

    /// preMask 여부로 필터링된 용어 range 목록을 반환한다.
    public func termRanges(preMask: Bool? = nil) -> [(entry: GlossaryEntry, range: Range<String.Index>)] {
        pieces.compactMap { piece in
            guard case let .term(entry, range) = piece else { return nil }
            if let filter = preMask, entry.preMask != filter {
                return nil
            }
            return (entry, range)
        }
    }
}
