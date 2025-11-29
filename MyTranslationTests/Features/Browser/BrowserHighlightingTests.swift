import Foundation
import UIKit
import Testing
@testable import MyTranslation

struct BrowserHighlightingTests {
    @Test
    func highlightedTextBuildsAttributedString() {
        let text = "Hello Choigangja"
        let entry = GlossaryEntry(
            source: "최강자",
            target: "Choigangja",
            variants: [],
            preMask: true,
            isAppellation: false,
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
}
