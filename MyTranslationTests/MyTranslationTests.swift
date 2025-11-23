//
//  MyTranslationTests.swift
//  MyTranslationTests
//
//  Created by sailor.m on 10/1/25.
//

import Foundation
import UIKit
import SwiftData
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
        let snapshot = #"[{"text":"Hello world.\nHello world.","map":[{"token":"n1","start":0,"end":25}]}]"#
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
        let snapshot = #"[{"text":"쟈그라...\n......\n다시 시작한다","map":[{"token":"t1","start":0,"end":17}]}]"#
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

    @Test
    func chooseJosaResolvesCompositeParticles() {
        let masker = TermMasker()

        // 공백이 포함된 입력은 이미 결정된 형태를 유지해야 하므로 교체하지 않는다.
        #expect(masker.chooseJosa(for: "만가", baseHasBatchim: false, baseIsRieul: false) == "만이")
        #expect(masker.chooseJosa(for: "만 는", baseHasBatchim: false, baseIsRieul: false) == "만 는")
        #expect(masker.chooseJosa(for: "만로", baseHasBatchim: true, baseIsRieul: true) == "만으로")
        #expect(masker.chooseJosa(for: "에게만", baseHasBatchim: true, baseIsRieul: false) == "에게만")
    }

    @Test
    func promoteProhibitedEntriesActivatesPairWithinContext() {
        let masker = TermMasker()
        let left = GlossaryEntry(
            source: "알파",
            target: "Alpha",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: true,
            origin: .termStandalone(termKey: "left")
        )
        let right = GlossaryEntry(
            source: "베타",
            target: "Beta",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: true,
            origin: .termStandalone(termKey: "right")
        )
        let composer = GlossaryEntry(
            source: "알파-베타",
            target: "Alpha-Beta",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .composer(composerId: "pair", leftKey: "left", rightKey: "right", needPairCheck: true)
        )

        let text = "이 문장에는 알파와 베타가 같이 등장한다."
        let promoted = masker.promoteProhibitedEntries(in: text, entries: [left, right, composer])

        #expect(promoted.count == 2)
        #expect(promoted.contains(left))
        #expect(promoted.contains(right))
    }

    @Test
    func promoteProhibitedEntriesIgnoresDistantPairs() {
        let masker = TermMasker()
        masker.contextWindow = 5
        let left = GlossaryEntry(
            source: "왼쪽",
            target: "Left",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: true,
            origin: .termStandalone(termKey: "L")
        )
        let right = GlossaryEntry(
            source: "오른쪽",
            target: "Right",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: true,
            origin: .termStandalone(termKey: "R")
        )
        let composer = GlossaryEntry(
            source: "양쪽",
            target: "Both",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .composer(composerId: "pair2", leftKey: "L", rightKey: "R", needPairCheck: true)
        )

        let gap = String(repeating: "가", count: 120)
        let text = "왼쪽이라는 단어가 나오고 \(gap) 문장 끝부분에 오른쪽이라는 단어가 있다."
        let promoted = masker.promoteProhibitedEntries(in: text, entries: [left, right, composer])

        #expect(promoted.isEmpty)
    }

    @Test
    func promoteActivatedEntriesReturnsOnlyTriggeredTerms() {
        let masker = TermMasker()
        let hero = GlossaryEntry(
            source: "주인공",
            target: "Hero",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "hero"),
            activatorKeys: [],
            activatesKeys: ["sidekick"]
        )
        let sidekick = GlossaryEntry(
            source: "조력자",
            target: "Sidekick",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "sidekick"),
            activatorKeys: ["hero"],
            activatesKeys: []
        )

        let text = "이야기 속 주인공이 등장했다."
        let activated = masker.promoteActivatedEntries(
            from: [hero, sidekick],
            standaloneEntries: [hero, sidekick],
            original: text
        )

        #expect(activated.count == 1)
        #expect(activated.first == sidekick)
    }

    @Test
    func normalizeDamagedETokensRestoresCorruptedPlaceholders() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#31__": .init(placeholder: "__E#31__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "텍스트 E#３１__ 와 __ E #31 __ 그리고 #31__ 을 포함"
        let restored = masker.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored.contains("__E#31__"))
        #expect(restored.components(separatedBy: "__E#31__").count == 4)
    }

    @Test
    func normalizeDamagedETokensIgnoresUnknownIds() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#7__": .init(placeholder: "__E#7__", target: "Seven", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let corrupted = "E#99__ 는 모르는 토큰이다."
        let restored = masker.normalizeDamagedETokens(corrupted, locks: locks)

        #expect(restored == corrupted)
    }

    @Test
    func surroundTokenWithNBSPAddsSpacingAroundLatin() {
        let masker = TermMasker()
        let token = "__E#1__"
        let text = "Hello__E#1__World"

        let spaced = masker.surroundTokenWithNBSP(text, token: token)

        #expect(spaced.contains("Hello\u{00A0}\(token)\u{00A0}World"))
    }

    @Test
    func insertSpacesAroundTokensOnlyForPunctOnlyParagraphs() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments

        let text = "__E#1__,__E#2__!"
        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ , __E#2__ !"))
    }

    @Test
    func insertSpacesAroundTokensKeepsNormalParagraphsUntouched() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments

        let text = "본문과__E#1__이 섞여 있다."
        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced == text)
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentRemovesExtraSpaces() {
        let masker = TermMasker()
        let text = ",   Alpha   !"

        let collapsed = masker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == ",Alpha!")
    }

    @Test
    func collapseSpacesWhenIsolatedSegmentKeepsParticles() {
        let masker = TermMasker()
        let text = ", Alpha의 "

        let collapsed = masker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(text, target: "Alpha")

        #expect(collapsed == text)
    }

    @Test
    func normalizeTokensAndParticlesReplacesMultipleTokens() {
        let masker = TermMasker()
        let locks: [String: LockInfo] = [
            "__E#1__": .init(placeholder: "__E#1__", target: "Alpha", endsWithBatchim: false, endsWithRieul: false, isAppellation: false),
            "__E#2__": .init(placeholder: "__E#2__", target: "Beta", endsWithBatchim: false, endsWithRieul: false, isAppellation: false)
        ]

        let text = "__E#1____E#2__를 본다"
        let normalized = masker.normalizeTokensAndParticles(in: text, locksByToken: locks)

        #expect(normalized.contains("AlphaBeta"))
        #expect(normalized.hasSuffix("본다"))
    }

    @Test
    func buildSegmentPiecesHandlesEmptyInput() {
        let masker = TermMasker()
        let segment = Segment(
            id: "empty",
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: "",
            normalizedText: "",
            domRange: nil
        )

        let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: [])
        #expect(pieces.originalText.isEmpty)
        #expect(pieces.pieces.count == 1)
        if case let .text(content, range) = pieces.pieces.first {
            #expect(content.isEmpty)
            #expect(range.isEmpty)
        } else {
            #expect(false, "첫 번째 조각이 text 이어야 합니다.")
        }
    }

    @Test
    func buildSegmentPiecesWithoutGlossaryReturnsSingleTextPiece() {
        let masker = TermMasker()
        let text = "Plain text without glossary."
        let segment = Segment(
            id: "plain",
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )

        let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: [])
        #expect(pieces.pieces.count == 1)
        if case let .text(content, range) = pieces.pieces.first {
            #expect(content == text)
            #expect(String(text[range]) == text)
        } else {
            #expect(false, "첫 번째 조각이 text 이어야 합니다.")
        }
    }

    @Test
    func insertSpacesAroundTokensAddsSpaceNearPunctuation() {
        let masker = TermMasker()
        masker.tokenSpacingBehavior = .isolatedSegments
        let text = "__E#1__!__E#2__?"

        let spaced = masker.insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(text)

        #expect(spaced.contains("__E#1__ ! __E#2__ ?"))
    }

    @Test
    func segmentPiecesTracksRanges() {
        let text = "Hello 최강자님, welcome!"
        let segment = Segment(
            id: "seg1",
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )
        let entry = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "t1")
        )

        let masker = TermMasker()
        let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: [entry])

        #expect(pieces.originalText == text)
        #expect(pieces.pieces.count == 3)

        if case let .text(prefix, range1) = pieces.pieces[0] {
            #expect(prefix == "Hello ")
            #expect(String(text[range1]) == "Hello ")
        } else {
            #expect(false, "첫 번째 조각이 text 이어야 합니다.")
        }

        if case let .term(termEntry, range2) = pieces.pieces[1] {
            #expect(termEntry.source == "최강자")
            #expect(String(text[range2]) == "최강자")
        } else {
            #expect(false, "두 번째 조각이 term 이어야 합니다.")
        }

        if case let .text(suffix, range3) = pieces.pieces[2] {
            #expect(suffix == "님, welcome!")
            #expect(String(text[range3]) == "님, welcome!")
        } else {
            #expect(false, "세 번째 조각이 text 이어야 합니다.")
        }
    }

    @Test
    func maskFromPiecesTracksRanges() {
        let text = "Hello 최강자님"
        let segment = Segment(
            id: "seg2",
            url: URL(string: "https://example.com")!,
            indexInPage: 0,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )
        let entry = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "t2")
        )

        let masker = TermMasker()
        let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: [entry])
        let pack = masker.maskFromPieces(pieces: pieces, segment: segment)

        #expect(pack.tokenEntries.count == 1)
        #expect(pack.maskedRanges.count == 1)
        if let token = pack.tokenEntries.keys.first,
           let range = pack.maskedRanges.first(where: { $0.type == .masked })?.range {
            #expect(String(pack.masked[range]) == token)
        } else {
            #expect(false, "마스킹된 토큰과 range를 찾지 못했습니다.")
        }
    }

    @Test
    func normalizeWithOrderTracksNormalizedRanges() {
        let original = "I love grey and grey"
        let translation = "나는 grey와 grey를 좋아함"
        let entry = GlossaryEntry(
            source: "grey",
            target: "gray",
            variants: ["grey"],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "grey")
        )

        let r1 = original.range(of: "grey")!
        let r2 = original.range(of: "grey", range: r1.upperBound..<original.endIndex)!
        let pieces = SegmentPieces(
            segmentID: "seg3",
            originalText: original,
            pieces: [
                .text(String(original[original.startIndex..<r1.lowerBound]), range: original.startIndex..<r1.lowerBound),
                .term(entry, range: r1),
                .text(String(original[r1.upperBound..<r2.lowerBound]), range: r1.upperBound..<r2.lowerBound),
                .term(entry, range: r2),
                .text(String(original[r2.upperBound..<original.endIndex]), range: r2.upperBound..<original.endIndex)
            ]
        )

        let name = TermMasker.NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let masker = TermMasker()
        let result = masker.normalizeWithOrder(
            in: translation,
            pieces: pieces,
            nameGlossaries: [name]
        )

        #expect(result.text.contains("gray"))
        #expect(result.ranges.count == 2)
        #expect(result.preNormalizedRanges.count == 2)
        for range in result.ranges {
            #expect(String(result.text[range.range]) == "gray")
            #expect(range.type == .normalized)
        }
        for range in result.preNormalizedRanges {
            #expect(range.type == .normalized)
        }
    }

    @Test
    func unmaskWithOrderTracksRanges() {
        let original = "안녕 최강자님과 용사님"
        let entry1 = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "e1")
        )
        let entry2 = GlossaryEntry(
            source: "용사",
            target: "Yongsa",
            variants: [],
            preMask: true,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "e2")
        )

        guard let r1 = original.range(of: "최강자"),
              let r2 = original.range(of: "용사") else {
            #expect(false, "원문에서 용어를 찾지 못했습니다.")
            return
        }

        let pieces = SegmentPieces(
            segmentID: "seg4",
            originalText: original,
            pieces: [
                .text(String(original[original.startIndex..<r1.lowerBound]), range: original.startIndex..<r1.lowerBound),
                .term(entry1, range: r1),
                .text(String(original[r1.upperBound..<r2.lowerBound]), range: r1.upperBound..<r2.lowerBound),
                .term(entry2, range: r2),
                .text(String(original[r2.upperBound..<original.endIndex]), range: r2.upperBound..<original.endIndex)
            ]
        )

        let textWithTokens = "안녕 __E#1__님과 __E#2__님"
        let locks: [String: LockInfo] = [
            "__E#1__": .init(placeholder: "__E#1__", target: entry1.target, endsWithBatchim: false, endsWithRieul: false, isAppellation: true),
            "__E#2__": .init(placeholder: "__E#2__", target: entry2.target, endsWithBatchim: false, endsWithRieul: false, isAppellation: true)
        ]
        let tokenEntries: [String: GlossaryEntry] = [
            "__E#1__": entry1,
            "__E#2__": entry2
        ]

        let masker = TermMasker()
        let result = masker.unmaskWithOrder(
            in: textWithTokens,
            pieces: pieces,
            locksByToken: locks,
            tokenEntries: tokenEntries
        )

        #expect(result.text.contains(entry1.target))
        #expect(result.text.contains(entry2.target))
        #expect(result.ranges.count == 2)
        for range in result.ranges {
            #expect(range.type == .masked)
        }
        #expect(result.deltas.count == 2)
    }

    @Test
    func highlightedTextBuildsAttributedString() {
        let text = "Hello Choigangja"
        let entry = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "e3")
        )
        let start = text.index(text.startIndex, offsetBy: 6)
        let end = text.endIndex
        let range = start..<end

        let highlighted = HighlightedText(
            text: text,
            highlights: [TermRange(entry: entry, range: range, type: .masked)]
        )

        #expect(highlighted.plainText == text)
        let nsRange = NSRange(location: 6, length: text.distance(from: start, to: end))
        let color = highlighted.attributedString.attribute(.backgroundColor, at: nsRange.location, effectiveRange: nil) as? UIColor
        #expect(color != nil)
    }

    @Test
    func streamBufferRetainsHighlightMetadata() {
        var buffer = BrowserViewModel.StreamBuffer()
        let text = "abc"
        let entry = GlossaryEntry(
            source: "a",
            target: "A",
            variants: [],
            preMask: true,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "k1")
        )
        let range = text.startIndex..<text.index(text.startIndex, offsetBy: 1)
        let metadata = TermHighlightMetadata(
            originalTermRanges: [],
            finalTermRanges: [TermRange(entry: entry, range: range, type: .masked)],
            preNormalizedTermRanges: nil
        )
        let payload = TranslationStreamPayload(
            segmentID: "s1",
            originalText: text,
            translatedText: text,
            preNormalizedText: nil,
            engineID: "e1",
            sequence: 0,
            highlightMetadata: metadata
        )

        buffer.upsert(payload)

        #expect(buffer.ordered.count == 1)
        #expect(buffer.ordered.first?.highlightMetadata?.finalTermRanges.count == 1)
    }

    @Test
    func normalizeVariantsAndParticlesTracksPreNormalizedRanges() {
        let text = "나는 grey와 grey를 좋아함"
        let name = TermMasker.NameGlossary(target: "gray", variants: ["grey"], expectedCount: 2, fallbackTerms: nil)
        let entry = GlossaryEntry(
            source: "grey",
            target: "gray",
            variants: ["grey"],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "tGrey")
        )

        let masker = TermMasker()
        let result = masker.normalizeVariantsAndParticles(
            in: text,
            entries: [(name, entry)],
            baseText: text,
            cumulativeDelta: 0
        )

        #expect(result.preNormalizedRanges.count == 2)
        #expect(result.ranges.count == 2)
        for r in result.preNormalizedRanges {
            #expect(String(text[r.range]) == "grey")
            #expect(r.type == .normalized)
        }
        for r in result.ranges {
            #expect(String(result.text[r.range]) == "gray")
        }
    }

    @Test
    func normalizeEntitiesHandlesAuxiliarySequences() {
        let masker = TermMasker()
        let names = [
            TermMasker.NameGlossary(target: "쟈그라", variants: ["가구라", "가굴라", "가고라"], expectedCount: 1, fallbackTerms: nil),
            TermMasker.NameGlossary(target: "쿠레나이 가이", variants: ["홍카이"], expectedCount: 1, fallbackTerms: nil)
        ]
        let entries: [GlossaryEntry] = [
            .init(
                source: "쟈그라",
                target: "쟈그라",
                variants: ["가구라", "가굴라", "가고라"],
                preMask: false,
                isAppellation: false,
                prohibitStandalone: false,
                origin: .termStandalone(termKey: "name1")
            ),
            .init(
                source: "쿠레나이 가이",
                target: "쿠레나이 가이",
                variants: ["홍카이"],
                preMask: false,
                isAppellation: false,
                prohibitStandalone: false,
                origin: .termStandalone(termKey: "name2")
            )
        ]

        let text = "가구라만이가 나타났고 홍카이만에게 경고했다."
        let normalized = masker.normalizeVariantsAndParticles(
            in: text,
            entries: Array(zip(names, entries)),
            baseText: text,
            cumulativeDelta: 0
        )

        #expect(normalized.text.contains("쟈그라만이"))
        #expect(normalized.text.contains("쿠레나이 가이만에게"))
    }
    
    @Test
    func unmatchedCandidatesRespectAnchorOrdering() {
        let entryA = GlossaryEntry(
            source: "凯",
            target: "가이",
            variants: ["카이", "케이"],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "termperson_6b5084f18cbb")
        )
        let entryB = GlossaryEntry(
            source: "伽古拉",
            target: "쟈그라",
            variants: ["가고라", "가구라"],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "termperson_5dd6e5c5e67f")
        )

        // 원문: A B A B
        let originalText = "当凯问伽古拉是否喜欢凯时，伽古拉笑了。"
        let originalRanges: [TermRange] = [
            TermRange(entry: entryA, range: find("凯", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryB, range: find("伽古拉", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("凯", in: originalText, occurrence: 1), type: .normalized),
            TermRange(entry: entryB, range: find("伽古拉", in: originalText, occurrence: 1), type: .normalized)
        ]

        // 번역문: B-tgt ... A-tgt (앞의 B, 뒤의 A가 매칭됨)
        let finalText = "Guy가 쟈그라에게 가이를 좋아하냐고 물었을 때, Juggler는 미소를 지었다."
        let finalRanges: [TermRange] = [
            TermRange(entry: entryB, range: find("쟈그라", in: finalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("가이", in: finalText, occurrence: 0), type: .normalized)
        ]

        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: finalRanges,
            preNormalizedTermRanges: nil
        )

        // 선택 범위가 첫 번째 번역(B-tgt) 앞이라면 A(뒤쪽 미매칭)가 우선
        let front = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "Guy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: 0
        )
        #expect(front.candidates.first?.entry.source == "凯")

        // 선택 범위가 마지막 번역(A-tgt) 뒤라면 B(뒤쪽 미매칭)가 우선
        let back = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "Juggler",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: finalText.count
        )
        #expect(back.candidates.first?.entry.source == "伽古拉")
    }
}

struct GlossaryImportTests {
    @MainActor
    private func makeUpserter(
        merge: Glossary.SDModel.ImportMergePolicy = .keepExisting
    ) throws -> (Glossary.SDModel.GlossaryUpserter, ModelContext) {
        let schema = Schema([
            Glossary.SDModel.SDTerm.self,
            Glossary.SDModel.SDSource.self,
            Glossary.SDModel.SDComponent.self,
            Glossary.SDModel.SDComponentGroup.self,
            Glossary.SDModel.SDGroup.self,
            Glossary.SDModel.SDTag.self,
            Glossary.SDModel.SDTermTagLink.self,
            Glossary.SDModel.SDPattern.self,
            Glossary.SDModel.SDPatternMeta.self,
            Glossary.SDModel.SDSourceIndex.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        return (Glossary.SDModel.GlossaryUpserter(context: context, merge: merge), context)
    }

    private func seedExistingTerm(in context: ModelContext) -> Glossary.SDModel.SDTerm {
        let term = Glossary.SDModel.SDTerm(key: "hero", target: "기존")
        term.variants = ["old"]
        term.preMask = false
        let source = Glossary.SDModel.SDSource(text: "Hero", prohibitStandalone: false, term: term)
        let tag = Glossary.SDModel.SDTag(name: "legacy")
        let link = Glossary.SDModel.SDTermTagLink(term: term, tag: tag)
        term.sources.append(source)
        term.termTagLinks.append(link)
        tag.termLinks.append(link)
        context.insert(term)
        context.insert(source)
        context.insert(tag)
        context.insert(link)
        return term
    }

    private func sampleTerm(
        key: String,
        target: String,
        variants: [String],
        tags: [String],
        activatedBy: [String]? = nil
    ) -> JSTerm {
        JSTerm(
            key: key,
            sources: [JSSource(source: key.capitalized, prohibitStandalone: false)],
            target: target,
            variants: variants,
            tags: tags,
            components: [JSComponent(pattern: "person", role: "name", groups: nil, srcTplIdx: nil, tgtTplIdx: nil)],
            isAppellation: false,
            preMask: false,
            activatedByKeys: activatedBy
        )
    }

    @Test @MainActor
    func dryRunCountsUnchangedTermsUsingSnapshots() throws {
        let (upserter, context) = try makeUpserter()

        let activator = Glossary.SDModel.SDTerm(key: "trigger", target: "트리거")
        let existing = Glossary.SDModel.SDTerm(key: "alpha", target: "알파")
        existing.variants = ["Alpha", "A"]
        existing.preMask = false
        let source = Glossary.SDModel.SDSource(text: "Alpha", prohibitStandalone: false, term: existing)
        let component = Glossary.SDModel.SDComponent(pattern: "person", role: "name", srcTplIdx: nil, tgtTplIdx: nil, term: existing)
        let tag = Glossary.SDModel.SDTag(name: "hero")
        let link = Glossary.SDModel.SDTermTagLink(term: existing, tag: tag)
        existing.sources.append(source)
        existing.components.append(component)
        existing.termTagLinks.append(link)
        existing.activators.append(activator)
        tag.termLinks.append(link)
        context.insert(activator)
        context.insert(existing)
        context.insert(source)
        context.insert(component)
        context.insert(tag)
        context.insert(link)

        let bundle = JSBundle(
            terms: [
                sampleTerm(
                    key: "alpha",
                    target: "알파",
                    variants: ["Alpha", "A"],
                    tags: ["hero"],
                    activatedBy: [" trigger ", ""]
                )
            ],
            patterns: []
        )

        let report = try upserter.dryRun(bundle: bundle)
        #expect(report.terms.unchangedCount == 1)
        #expect(report.terms.updateCount == 0)
        #expect(report.terms.newCount == 0)
        #expect(report.terms.deleteCount == 0)
    }

    @Test @MainActor
    func dryRunDetectsNewAndUpdatedTerms() throws {
        let (upserter, context) = try makeUpserter()
        let existing = Glossary.SDModel.SDTerm(key: "alpha", target: "old")
        context.insert(existing)

        let bundle = JSBundle(
            terms: [
                sampleTerm(key: "alpha", target: "new", variants: ["v1"], tags: []),
                sampleTerm(key: "beta", target: "beta-target", variants: [], tags: [])
            ],
            patterns: []
        )

        let report = try upserter.dryRun(bundle: bundle)
        #expect(report.terms.updateCount == 1)
        #expect(report.terms.newCount == 1)
        #expect(report.terms.unchangedCount == 0)
        #expect(report.terms.deleteCount == 0)
    }

    @Test @MainActor
    func applyRespectsMergePolicies() throws {
        let bundle = JSBundle(
            terms: [
                sampleTerm(
                    key: "hero",
                    target: "신규",
                    variants: ["new"],
                    tags: ["modern"]
                )
            ],
            patterns: []
        )

        let (keepUpserter, keepContext) = try makeUpserter(merge: .keepExisting)
        _ = seedExistingTerm(in: keepContext)
        _ = try keepUpserter.apply(bundle: bundle)
        let keepDesc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: #Predicate { $0.key == "hero" })
        let keepTerm = try keepContext.fetch(keepDesc).first!
        #expect(keepTerm.target == "기존")
        #expect(Set(keepTerm.variants) == Set(["old", "new"]))
        #expect(Set(keepTerm.termTagLinks.map { $0.tag.name }) == Set(["legacy", "modern"]))

        let (overwriteUpserter, overwriteContext) = try makeUpserter(merge: .overwrite)
        _ = seedExistingTerm(in: overwriteContext)
        _ = try overwriteUpserter.apply(bundle: bundle)
        let overwriteDesc = FetchDescriptor<Glossary.SDModel.SDTerm>(predicate: #Predicate { $0.key == "hero" })
        let overwriteTerm = try overwriteContext.fetch(overwriteDesc).first!
        #expect(overwriteTerm.target == "신규")
        #expect(overwriteTerm.variants == ["new"])
        #expect(Set(overwriteTerm.termTagLinks.map { $0.tag.name }) == Set(["modern"]))
    }

    // MARK: - GlossaryAdd candidate tests

    @Test
    func unmatchedCandidatesRespectAnchorOrdering() {
        let entryA = GlossaryEntry(
            source: "A",
            target: "A-tgt",
            variants: ["A-alt"],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "A")
        )
        let entryB = GlossaryEntry(
            source: "B",
            target: "B-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "B")
        )

        // 원문: A B A B
        let originalText = "A B A B"
        let originalRanges: [TermRange] = [
            TermRange(entry: entryA, range: find("A", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryB, range: find("B", in: originalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("A", in: originalText, occurrence: 1), type: .normalized),
            TermRange(entry: entryB, range: find("B", in: originalText, occurrence: 1), type: .normalized)
        ]

        // 번역문: B-tgt ... A-tgt (앞의 B, 뒤의 A가 매칭됨)
        let finalText = "B-tgt ... A-tgt"
        let finalRanges: [TermRange] = [
            TermRange(entry: entryB, range: find("B-tgt", in: finalText, occurrence: 0), type: .normalized),
            TermRange(entry: entryA, range: find("A-tgt", in: finalText, occurrence: 0), type: .normalized)
        ]

        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: finalRanges,
            preNormalizedTermRanges: nil
        )

        // 선택 범위가 첫 번째 번역(B-tgt) 앞이라면 앞쪽 미매칭인 A가 우선
        let front = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 5
        )
        #expect(front.candidates.first?.entry.source == "A")

        // 선택 범위가 마지막 번역(A-tgt) 뒤라면 뒤쪽 미매칭인 B가 우선
        let back = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: finalText,
            preNormalizedText: nil,
            selectionAnchor: finalText.count,
            maxCount: 5
        )
        #expect(back.candidates.first?.entry.source == "B")
    }

    @Test
    func unmatchedCandidatesTruncateWhenTooMany() {
        let base = GlossaryEntry(
            source: "X",
            target: "X-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "X")
        )
        let originalText = (0..<20).map { _ in "X" }.joined(separator: " ")
        let originalRanges: [TermRange] = (0..<20).map { idx in
            TermRange(entry: base, range: find("X", in: originalText, occurrence: idx), type: .normalized)
        }
        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )

        let result = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: metadata,
            selectedText: "dummy",
            finalText: nil,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 5
        )
        #expect(result.candidates.count == 5)
        #expect(result.truncated == true)
    }

    @Test
    func matchedEntryForOriginalFindsExactRange() {
        let text = "Hello A and B"
        let entryA = GlossaryEntry(
            source: "A",
            target: "A-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "A")
        )
        let entryB = GlossaryEntry(
            source: "B",
            target: "B-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "B")
        )

        let rA = find("A", in: text, occurrence: 0)
        let rB = find("B", in: text, occurrence: 0)
        let meta = TermHighlightMetadata(
            originalTermRanges: [
                TermRange(entry: entryA, range: rA, type: .normalized),
                TermRange(entry: entryB, range: rB, type: .normalized)
            ],
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )

        let nsA = NSRange(rA, in: text)
        let nsB = NSRange(rB, in: text)
        #expect(meta.matchedEntryForOriginal(nsRange: nsA, in: text)?.source == "A")
        #expect(meta.matchedEntryForOriginal(nsRange: nsB, in: text)?.source == "B")
        let miss = NSRange(location: 0, length: 3)
        #expect(meta.matchedEntryForOriginal(nsRange: miss, in: text) == nil)
    }

    @Test
    func composerCandidateProducesMultipleKeys() {
        let componentTerms: [GlossaryEntry.ComponentTerm] = [
            .init(
                key: "L",
                target: "L-tgt",
                variants: [],
                sources: [.init(text: "A", prohibitStandalone: false)],
                matchedSources: ["A"],
                preMask: false,
                isAppellation: false,
                activatorKeys: [],
                activatesKeys: []
            ),
            .init(
                key: "R",
                target: "R-tgt",
                variants: [],
                sources: [.init(text: "B", prohibitStandalone: false)],
                matchedSources: ["B"],
                preMask: false,
                isAppellation: false,
                activatorKeys: [],
                activatesKeys: []
            )
        ]
        let entry = GlossaryEntry(
            source: "AB",
            target: "AB-tgt",
            variants: [],
            preMask: false,
            isAppellation: false,
            prohibitStandalone: false,
            origin: .composer(composerId: "comp", leftKey: "L", rightKey: "R", needPairCheck: false),
            componentTerms: componentTerms
        )
        let originalText = "AB"
        let range = find("AB", in: originalText, occurrence: 0)
        let meta = TermHighlightMetadata(
            originalTermRanges: [TermRange(entry: entry, range: range, type: .normalized)],
            finalTermRanges: [],
            preNormalizedTermRanges: nil
        )
        let result = GlossaryAddCandidateUtil.computeUnmatchedCandidates(
            metadata: meta,
            selectedText: "dummy",
            finalText: nil,
            preNormalizedText: nil,
            selectionAnchor: 0,
            maxCount: 10
        )
        let keys = result.candidates.compactMap { $0.termKey }
        #expect(keys.contains("L"))
        #expect(keys.contains("R"))
        #expect(keys.count == 2)
    }
}

// MARK: - Helpers

private func find(_ needle: String, in haystack: String, occurrence: Int) -> Range<String.Index> {
    var start = haystack.startIndex
    var count = 0
    while let r = haystack.range(of: needle, range: start..<haystack.endIndex) {
        if count == occurrence {
            return r
        }
        count += 1
        start = r.upperBound
    }
    return haystack.startIndex..<haystack.startIndex
}
