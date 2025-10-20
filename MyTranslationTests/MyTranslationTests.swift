//
//  MyTranslationTests.swift
//  MyTranslationTests
//
//  Created by sailor.m on 10/1/25.
//

import Foundation
import Testing
@testable import MyTranslation

@MainActor
private final class StubWebViewExecutor: WebViewScriptExecutor {
    private let result: String

    init(result: String) {
        self.result = result
    }

    func runJS(_ script: String) async throws -> String { result }

    func currentURL() async -> URL? { nil }
}

struct MyTranslationTests {

    @Test @MainActor
    func extractorGeneratesUniqueSegmentIDsForDuplicateText() async throws {
        let snapshot = """
        [
          {
            "text": "Hello world.\nHello world.",
            "map": [
              { "token": "n1", "start": 0, "end": 25 }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com")!
        let segments = try await extractor.extract(using: executor, url: url)

        #expect(segments.count == 2)
        #expect(Set(segments.map { $0.id }).count == 2)
        #expect(segments.first?.normalizedText == segments.last?.normalizedText)
        #expect(segments.allSatisfy { $0.domRange != nil })
    }

    @Test @MainActor
    func extractorSkipsPunctuationOnlySegments() async throws {
        let snapshot = """
        [
          {
            "text": "쟈그라...\n......\n다시 시작한다",
            "map": [
              { "token": "t1", "start": 0, "end": 17 }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/story")!
        let segments = try await extractor.extract(using: executor, url: url)

        #expect(segments.count == 2)
        #expect(segments.allSatisfy { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy { $0.isPunctuation } })
    }

    @Test @MainActor
    func extractorKeepsMultiSentenceParagraphAsSingleSegment() async throws {
        let snapshot = """
        [
          {
            "text": "첫 번째 문장입니다. 두 번째 문장도 이어지고 있습니다. 마지막 문장까지 하나의 단락으로 유지됩니다.",
            "map": [
              { "token": "n2", "start": 0, "end": 54 }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/paragraph")!
        let segments = try await extractor.extract(using: executor, url: url)

        #expect(segments.count == 1)
        #expect(segments.first?.originalText.contains("두 번째 문장") == true)
    }

    @Test @MainActor
    func extractorSplitsVeryLongParagraphIntoMultipleSegments() async throws {
        let longSentence = String(repeating: "a", count: 700) + "?" + String(repeating: "b", count: 650)
        let snapshot = """
        [
          {
            "text": "\(longSentence)",
            "map": [
              { "token": "nA", "start": 0, "end": \(longSentence.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/long")!
        let segments = try await extractor.extract(using: executor, url: url)

        #expect(segments.count > 1)
        #expect(segments.map { $0.indexInPage } == Array(0..<segments.count))
    }

    @Test @MainActor
    func extractorPreservesEntireBlockWhenChunking() async throws {
        let block = String(repeating: "가", count: 500)
            + String(repeating: "나", count: 500)
            + String(repeating: "다", count: 500)
        let snapshot = """
        [
          {
            "text": "\(block)",
            "map": [
              { "token": "n0", "start": 0, "end": \(block.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/full")!
        let segments = try await extractor.extract(using: executor, url: url)

        let combined = segments.map { $0.originalText }.joined()
        #expect(combined == block)
        #expect(segments.count >= 2)
    }

    @Test @MainActor
    func extractorDoesNotSplitSegmentsByCommaWhenChunking() async throws {
        let repeated = Array(repeating: "이 문장은 쉼표를 포함하고, 여전히 하나의 의미를 가지고, 사용자에게 보여집니다, ", count: 90).joined()
        let snapshot = """
        [
          {
            "text": "\(repeated)",
            "map": [
              { "token": "nComma", "start": 0, "end": \(repeated.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/comma")!
        let segments = try await extractor.extract(using: executor, url: url)

        #expect(segments.count < 20)
        #expect(segments.contains { $0.originalText.components(separatedBy: ",").count > 3 })
    }

    @Test
    func inlineScriptExposesSidBasedReplacementHelpers() {
        let script = WebViewInlineReplacer.scriptForTesting()
        #expect(script.contains("translationBySid"))
        #expect(script.contains("_applyForSegment"))
        #expect(!script.contains("S.map.get"))
    }

    @Test
    func selectionBridgeScriptTagsTextNodesWithSegmentId() {
        let script = SelectionBridge.scriptForTesting()
        #expect(script.contains("tagTextNodesWithSegment"))
        #expect(script.contains("__afmSegmentId"))
        #expect(script.contains("MT_COLLECT_BLOCK_SNAPSHOTS"))
        #expect(script.contains("startToken"))
    }
}
