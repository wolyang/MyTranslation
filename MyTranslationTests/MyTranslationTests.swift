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

    @Test
    func chooseJosaResolvesCompositeParticles() {
        let masker = TermMasker()

        #expect(masker.chooseJosa(for: "만가", baseHasBatchim: false, baseIsRieul: false) == "만이")
        #expect(masker.chooseJosa(for: "만 는", baseHasBatchim: false, baseIsRieul: false) == "만 은")
        #expect(masker.chooseJosa(for: "만로", baseHasBatchim: true, baseIsRieul: true) == "만으로")
        #expect(masker.chooseJosa(for: "에게만", baseHasBatchim: true, baseIsRieul: false) == "에게만")
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
        for range in result.ranges {
            #expect(String(result.text[range.range]) == "gray")
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
    func normalizeEntitiesHandlesAuxiliarySequences() {
        let masker = TermMasker()
        let names = [
            TermMasker.NameGlossary(target: "쟈그라", variants: ["가구라", "가굴라", "가고라"]),
            TermMasker.NameGlossary(target: "쿠레나이 가이", variants: ["홍카이"])
        ]

        let text = "가구라만이가 나타났고 홍카이만에게 경고했다."
        let normalized = masker.normalizeEntitiesAndParticles(
            in: text,
            locksByToken: [:],
            names: names,
            mode: .namesOnly
        )

        #expect(normalized.contains("쟈그라만이"))
        #expect(normalized.contains("쿠레나이 가이만에게"))
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
}
