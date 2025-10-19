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
        let js = "(function(){var t=document.body?document.body.innerText:document.documentElement.innerText;return t||'';})()"
        let value = try await exec.runJS(js)
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractorError.noBodyText }

        let paras = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        var out: [Segment] = []
        var idx = 0
        for p in paras {
            let chunks = p.split(usingRegex: #"(?<=[\.!?。！？])\s+"#)
            for ch in chunks {
                let original = ch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !original.isEmpty, !original.isPunctOnly else { continue }
                let clipped = String(original.prefix(800))
                // 너무 긴 문장이 들어오면 추가 분할
                if clipped.count > 600 {
                    // 1차: 쉼표류/중국어 쉼표로 분할 시도
                    let subparts = clipped.split(usingRegex: #"[，,、;：:]\s*"#)
                    if subparts.count > 1 {
                        for sp in subparts {
                            let s = String(sp.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !s.isEmpty, !s.isPunctOnly else { continue }
                            let normalized = normalizeForID(s)
                            let sid = sha1Hex("\(normalized)|\(url.absoluteString)#\(idx)::v1")
                            out.append(.init(id: sid, url: url, indexInPage: idx, originalText: s, normalizedText: normalized))
                            idx += 1
                        }
                        continue
                    }
                    // 2차: 길이 기준 하드 컷 분할(400자 단위)
                    var start = clipped.startIndex
                    while start < clipped.endIndex {
                        let end = clipped.index(start, offsetBy: 400, limitedBy: clipped.endIndex) ?? clipped.endIndex
                        let s = String(clipped[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty, !s.isPunctOnly {
                            let normalized = normalizeForID(s)
                            let sid = sha1Hex("\(normalized)|\(url.absoluteString)#\(idx)::v1")
                            out.append(.init(id: sid, url: url, indexInPage: idx, originalText: s, normalizedText: normalized))
                            idx += 1
                        }
                        start = end
                    }
                    continue
                }
                let normalized = normalizeForID(clipped)
                let sid = sha1Hex("\(normalized)|\(url.absoluteString)#\(idx)::v1")
                out.append(.init(
                    id: sid,
                    url: url,
                    indexInPage: idx,
                    originalText: clipped,
                    normalizedText: normalized
                ))
                idx += 1
                if out.count >= 300 { break }
            }
            if out.count >= 300 { break }
        }
        let totalChars = out.reduce(0) { $0 + $1.originalText.count }
        let maxLen = out.map { $0.originalText.count }.max() ?? 0
        let top5 = out.map { $0.originalText.count }.sorted(by: >).prefix(5)
        print("[EXTRACT] url=\(url.absoluteString) segs=\(out.count) totalChars=\(totalChars) maxLen=\(maxLen) top5=\(Array(top5))")
        return out
    }

    private func normalizeForID(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha1Hex(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func split(usingRegex pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [self] }
        let ns = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length))
        var prev = 0
        var parts: [String] = []
        for m in matches {
            let r = NSRange(location: prev, length: m.range.location - prev)
            if r.length > 0 { parts.append(ns.substring(with: r)) }
            prev = m.range.location + m.range.length
        }
        let tail = NSRange(location: prev, length: ns.length - prev)
        if tail.length > 0 { parts.append(ns.substring(with: tail)) }
        return parts
    }
    
    // 텍스트가 문장부호로만 이루어졌는지 확인
    var isPunctOnly: Bool {
        let punct = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return self.unicodeScalars.allSatisfy { punct.contains($0) }
    }
}
