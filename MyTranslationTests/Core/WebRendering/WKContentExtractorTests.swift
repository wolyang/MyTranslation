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

struct WKContentExtractorTests {

    @Test @MainActor
    func extractorGeneratesUniqueSegmentIDsForDuplicateText() async throws {
        let snapshot = #"[{"text":"Hello world.\nHello world.","map":[{"token":"n1","start":0,"end":25}]}]"#
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com")!
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

        #expect(segments.count == 2)
        #expect(Set(segments.map { $0.id }).count == 2)
        #expect(segments.first?.normalizedText == segments.last?.normalizedText)
        #expect(segments.allSatisfy { $0.domRange != nil })
    }

    @Test @MainActor
    func extractorSkipsPunctuationOnlySegments() async throws {
        let snapshot = #"[{"text":"쟈그라...\n......\n다시 시작한다","map":[{"token":"t1","start":0,"end":17}]}]"#
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/story")!
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

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
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

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
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

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
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

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
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

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

    @Test @MainActor
    func extractorSplitsLongParagraphIntoSentences() async throws {
        // 150자를 초과하는 긴 단락 (각 문장이 80자 이상이어야 preferredLength~maxLength 범위에서 감지됨)
        let longParagraph = String(repeating: "이것은 정말로 긴 문장의 시작 부분이고 ", count: 5) + "첫 번째 문장입니다. " +
                           String(repeating: "저것은 또 다른 긴 문장의 중간 부분이며 ", count: 5) + "두 번째 문장입니다. " +
                           String(repeating: "그것은 마지막으로 오는 긴 문장이자 ", count: 5) + "세 번째 문장입니다."
        let snapshot = """
        [
          {
            "text": "\(longParagraph)",
            "map": [
              { "token": "n2", "start": 0, "end": \(longParagraph.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/long-paragraph")!
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

        #expect(segments.count == 3)  // 긴 단락은 문장으로 분할
        #expect(segments[0].originalText.contains("첫 번째 문장입니다."))
        #expect(segments[1].originalText.contains("두 번째 문장입니다."))
        #expect(segments[2].originalText.contains("세 번째 문장입니다."))
    }

    @Test @MainActor
    func extractorSplitsLongChineseParagraphIntoSentences() async throws {
        // 150자를 초과하는 긴 중국어 단락 (사용자가 제공한 실제 예시 사용)
        let longText = "自从上次被迫裸奔被善太发现后，这家伙就不知道搭错了哪根筋，一直在他耳边叭叭什么苦海无涯回头是岸，沉沦是一时的身体是自己的，人要学会有尊严的活着奥也是不能出卖自己的肉体等稀奇古怪球球人听得头昏脑胀的话。碍于伽古拉曾经殷切威胁要是他们二人的关系被除彼此以外第三个人知道他就给红凯再放上六只魔王兽替重忆昔日峥嵘，凯只能旁敲侧击地告诉善太自己并没有做地球上那个叫做鸭的职业，他只给一个人服务。被善太听完之后尖叫的一声什么凯哥原来你是被包养吗再度打败。他已经放弃了去解释自己在善太眼里逐渐扭曲的形象，换主动为被动——主动辟谣变被动躲避。每一次看见善太那苦大深仇念念有词的能直接幻视杂志上那个据说很能哔哔叨叨的中国唐僧的脸，都选择转身逃跑甚至用上瞬移来远离问题。"
        let snapshot = """
        [
          {
            "text": "\(longText)",
            "map": [
              { "token": "n1", "start": 0, "end": \(longText.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/chinese")!
        let config = SegmentExtractConfig(preferredLength: 80, maxLength: 150)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

        // 실제로는 3개로 분할됨 (첫 2개 문장은 80자 이상, 나머지는 합쳐져서 80~150 범위)
        #expect(segments.count == 3)
        #expect(segments[0].originalText.hasSuffix("话。"))
        #expect(segments[1].originalText.hasSuffix("服务。"))
        #expect(segments[2].originalText.hasSuffix("问题。"))
    }

    @Test @MainActor
    func extractorDoesNotSplitOnQuotedPunctuation() async throws {
        // 인용문 내부의 ?로 분할하지 않는지 검증
        // "가이는 당황해서 '?!' 라고 외쳤다."
        // - '?'의 위치: 11글자
        // - 진짜 종료 '.'의 위치: 22글자
        // preferredLength=10, maxLength=25로 설정하면 10~25 범위에서 분할점 탐색
        // - 11글자의 '?' (인용문 내부) → 범위 안에 있음! 하지만 인용문이므로 무시해야 함
        // - 22글자의 '.' (진짜 종료) → 범위 안에 있음, 여기서 분할해야 함
        let text = "가이는 당황해서 '?!' 라고 외쳤다. 그리고 '정말이야?' 하고 물었다."
        let snapshot = """
        [
          {
            "text": "\(text)",
            "map": [
              { "token": "n1", "start": 0, "end": \(text.count) }
            ]
          }
        ]
        """
        let executor = StubWebViewExecutor(result: snapshot)
        let extractor = WKContentExtractor()
        let url = URL(string: "https://example.com/quoted")!
        let config = SegmentExtractConfig(preferredLength: 10, maxLength: 25)
        let segments = try await extractor.extract(using: executor, url: url, config: config)

        // 현재 구현은 인용문을 구분하지 않으므로, 이 테스트는 실패할 수 있음
        // TODO: findBreakPoint에 인용문 감지 로직 추가 필요
        #expect(segments.count == 2)
        #expect(segments[0].originalText.hasSuffix("외쳤다."))
        #expect(segments[1].originalText.hasSuffix("물었다."))
    }
}
