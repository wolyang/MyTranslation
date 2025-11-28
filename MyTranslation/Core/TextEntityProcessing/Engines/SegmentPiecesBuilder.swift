//
//  SegmentPiecesBuilder.swift
//  MyTranslation
//

import Foundation

final class SegmentPiecesBuilder {

    func buildSegmentPieces(
        segmentText: String,
        segmentID: String,
        sourceToEntry: [String: GlossaryEntry]
    ) -> SegmentPieces {
        let text = segmentText
        var pieces: [SegmentPieces.Piece] = [.text(text, range: text.startIndex..<text.endIndex)]

        let sortedSources = sourceToEntry.keys.sorted { $0.count > $1.count }

        for source in sortedSources {
            guard let entry = sourceToEntry[source] else { continue }
            var newPieces: [SegmentPieces.Piece] = []

            for piece in pieces {
                switch piece {
                case .text(let str, let pieceRange):
                    guard str.contains(source) else {
                        newPieces.append(.text(str, range: pieceRange))
                        continue
                    }

                    var searchStart = str.startIndex
                    while let foundRange = str.range(of: source, range: searchStart..<str.endIndex) {
                        if foundRange.lowerBound > searchStart {
                            let prefixLower = text.index(
                                pieceRange.lowerBound,
                                offsetBy: str.distance(from: str.startIndex, to: searchStart)
                            )
                            let prefixUpper = text.index(
                                pieceRange.lowerBound,
                                offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                            )
                            let prefix = String(str[searchStart..<foundRange.lowerBound])
                            newPieces.append(.text(prefix, range: prefixLower..<prefixUpper))
                        }

                        let originalLower = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                        )
                        let originalUpper = text.index(originalLower, offsetBy: source.count)
                        newPieces.append(.term(entry, range: originalLower..<originalUpper))

                        searchStart = foundRange.upperBound
                    }

                    if searchStart < str.endIndex {
                        let suffixLower = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: searchStart)
                        )
                        let suffix = String(str[searchStart...])
                        newPieces.append(.text(suffix, range: suffixLower..<pieceRange.upperBound))
                    }
                case .term:
                    newPieces.append(piece)
                }
            }

            pieces = newPieces
        }

        return SegmentPieces(
            segmentID: segmentID,
            originalText: text,
            pieces: pieces
        )
    }
}
