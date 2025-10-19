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
