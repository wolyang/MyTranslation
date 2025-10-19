//
//  WKContentExtractor.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import CryptoKit
import Foundation

enum ExtractorError: Error { case noHTML, noBodyText }

final class WKContentExtractor: ContentExtractor {
    public func extract(using exec: WebViewScriptExecutor, url: URL) async throws -> [Segment] {
        let snapshotScript = "window.MT && MT_COLLECT_BLOCK_SNAPSHOTS ? MT_COLLECT_BLOCK_SNAPSHOTS() : '[]';"
        let value = try await exec.runJS(snapshotScript)
        guard let data = value.data(using: .utf8) else { throw ExtractorError.noBodyText }
        let blocks = try JSONDecoder().decode([BlockSnapshot].self, from: data)
        guard blocks.isEmpty == false else { throw ExtractorError.noBodyText }

        var segments: [Segment] = []
        segments.reserveCapacity(blocks.count)
        var idx = 0
        var globalCursor = 0
        var isFirstBlock = true

        for block in blocks {
            guard block.text.isEmpty == false else { continue }

            if isFirstBlock {
                isFirstBlock = false
            } else {
                globalCursor += 1 // 블록 사이에 결합했던 개행만큼 보정
            }

            let baseOffset = globalCursor
            let slices = segmentSlices(in: block.text)
            for slice in slices {
                let globalStart = baseOffset + slice.start
                let globalEnd = baseOffset + slice.end
                guard let dom = makeDomRange(
                    for: slice,
                    map: block.map,
                    globalStart: globalStart,
                    globalEnd: globalEnd
                ) else { continue }

                let startIdx = block.text.index(block.text.startIndex, offsetBy: slice.start)
                let endIdx = block.text.index(block.text.startIndex, offsetBy: slice.end)
                let rawSubstring = block.text[startIdx..<endIdx]
                let raw = String(rawSubstring)
                guard raw.count >= 2 else { continue }
                guard raw.isPunctOnly == false else { continue }

                let normalized = normalizeForID(raw)
                let sid = sha1Hex("\(normalized)|\(url.absoluteString)#\(idx)::v1")
                let segment = Segment(
                    id: sid,
                    url: url,
                    indexInPage: idx,
                    originalText: raw,
                    normalizedText: normalized,
                    domRange: dom
                )
                segments.append(segment)
                idx += 1
            }

            globalCursor = baseOffset + block.text.count
        }
        guard segments.isEmpty == false else { throw ExtractorError.noBodyText }

        let totalChars = segments.reduce(0) { $0 + $1.originalText.count }
        let maxLen = segments.map { $0.originalText.count }.max() ?? 0
        let top5 = segments.map { $0.originalText.count }.sorted(by: >).prefix(5)
        print("[EXTRACT] url=\(url.absoluteString) segs=\(segments.count) totalChars=\(totalChars) maxLen=\(maxLen) top5=\(Array(top5))")
        return segments
    }

    private func segmentSlices(in text: String) -> [TextSlice] {
        guard text.isEmpty == false else { return [] }
        let chars = Array(text)
        let count = chars.count
        var slices: [TextSlice] = []

        func isWhitespace(_ index: Int) -> Bool {
            guard index >= 0, index < count else { return false }
            return chars[index].unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        func isSentenceTerminator(_ ch: Character) -> Bool {
            return [".", "!", "?", "。", "！", "？"].contains(ch)
        }

        let delimiters: Set<Character> = ["，", ",", "、", ";", "：", ":"]

        func emitSegment(start: Int, end: Int) {
            guard start < end else { return }
            var s = start
            var e = end
            while s < e && isWhitespace(s) { s += 1 }
            while e > s && isWhitespace(e - 1) { e -= 1 }
            guard s < e else { return }
            let startIdx = text.index(text.startIndex, offsetBy: s)
            let endIdx = text.index(text.startIndex, offsetBy: e)
            let snippet = String(text[startIdx..<endIdx])
            guard snippet.isPunctOnly == false else { return }
            slices.append(TextSlice(start: s, end: e))
        }

        func splitByLength(start: Int, end: Int) {
            var cursor = start
            while cursor < end {
                let chunkEnd = min(end, cursor + 400)
                emitSegment(start: cursor, end: chunkEnd)
                cursor = chunkEnd
            }
        }

        func emitOrSplit(start: Int, end: Int) {
            guard start < end else { return }
            if end - start > 600 {
                splitByLength(start: start, end: end)
            } else {
                emitSegment(start: start, end: end)
            }
        }

        func splitByDelimiters(start: Int, end: Int) -> Bool {
            var produced = false
            var pieceStart = start
            var i = start
            while i < end {
                let ch = chars[i]
                if delimiters.contains(ch) {
                    var pieceEnd = i + 1
                    while pieceEnd < end && isWhitespace(pieceEnd) { pieceEnd += 1 }
                    emitOrSplit(start: pieceStart, end: pieceEnd)
                    pieceStart = pieceEnd
                    produced = true
                }
                i += 1
            }
            if pieceStart < end {
                emitOrSplit(start: pieceStart, end: end)
                produced = true
            }
            return produced
        }

        func appendRange(start: Int, end: Int) {
            guard start < end else { return }
            var cursor = start
            while cursor < end {
                let clipEnd = min(end, cursor + 800)
                if clipEnd - cursor > 600 {
                    if splitByDelimiters(start: cursor, end: clipEnd) == false {
                        splitByLength(start: cursor, end: clipEnd)
                    }
                } else {
                    emitSegment(start: cursor, end: clipEnd)
                }
                cursor = clipEnd
            }
        }

        func processParagraph(start: Int, end: Int) {
            var s = start
            var e = end
            while s < e && isWhitespace(s) { s += 1 }
            while e > s && isWhitespace(e - 1) { e -= 1 }
            guard s < e else { return }

            var sentenceStart = s
            var i = s
            while i < e {
                let ch = chars[i]
                if isSentenceTerminator(ch) {
                    var next = i + 1
                    var hasWhitespace = false
                    while next < e && isWhitespace(next) {
                        hasWhitespace = true
                        next += 1
                    }
                    if hasWhitespace {
                        appendRange(start: sentenceStart, end: next)
                        sentenceStart = next
                        i = next
                        continue
                    }
                }
                i += 1
            }
            if sentenceStart < e {
                appendRange(start: sentenceStart, end: e)
            }
        }

        var cursor = 0
        while cursor < count {
            var paraEnd = cursor
            while paraEnd < count && chars[paraEnd] != "\n" { paraEnd += 1 }
            processParagraph(start: cursor, end: paraEnd)
            cursor = paraEnd + 1
        }

        return slices
    }

    private func makeDomRange(for slice: TextSlice,
                              map: [BlockSnapshot.Entry],
                              globalStart: Int,
                              globalEnd: Int) -> Segment.DOMRange? {
        guard let start = locatePosition(slice.start, in: map),
              let end = locatePosition(slice.end, in: map) else { return nil }
        return Segment.DOMRange(
            startToken: start.token,
            startOffset: start.offset,
            endToken: end.token,
            endOffset: end.offset,
            startIndex: globalStart,
            endIndex: globalEnd
        )
    }

    private func locatePosition(_ position: Int, in map: [BlockSnapshot.Entry]) -> (token: String, offset: Int)? {
        guard position >= 0 else { return nil }
        for index in 0..<map.count {
            let entry = map[index]
            if position < entry.end {
                return (entry.token, max(0, position - entry.start))
            }
            if position == entry.end {
                if index + 1 < map.count {
                    return (map[index + 1].token, 0)
                } else {
                    return (entry.token, max(0, entry.end - entry.start))
                }
            }
        }
        if let last = map.last {
            return (last.token, max(0, last.end - last.start))
        }
        return nil
    }

    private func normalizeForID(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha1Hex(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct BlockSnapshot: Decodable {
        struct Entry: Decodable {
            let token: String
            let start: Int
            let end: Int
        }
        let text: String
        let map: [Entry]
    }

    private struct TextSlice {
        let start: Int
        let end: Int
    }
}

private extension String {
    // 텍스트가 문장부호로만 이루어졌는지 확인
    var isPunctOnly: Bool {
        let punct = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return self.unicodeScalars.allSatisfy { punct.contains($0) }
    }
}
