import Foundation

/// 용어 하이라이팅 범위를 표현하는 메타데이터.
public struct TermHighlightMetadata: Sendable, Equatable {
    /// 원문에서 감지된 용어 위치.
    public let originalTermRanges: [TermRange]
    /// 최종 번역문에서의 용어 위치.
    public let finalTermRanges: [TermRange]
    /// 정규화 전 번역문에서의 용어 위치.
    public let preNormalizedTermRanges: [TermRange]?

    public init(
        originalTermRanges: [TermRange],
        finalTermRanges: [TermRange],
        preNormalizedTermRanges: [TermRange]? = nil
    ) {
        self.originalTermRanges = originalTermRanges
        self.finalTermRanges = finalTermRanges
        self.preNormalizedTermRanges = preNormalizedTermRanges
    }
}

/// Glossary 용어와 range 정보를 묶어 표현한다.
public struct TermRange: Sendable, Equatable, Hashable {
    public let entry: GlossaryEntry
    public let range: Range<String.Index>
    public let type: TermType

    public init(entry: GlossaryEntry, range: Range<String.Index>, type: TermType) {
        self.entry = entry
        self.range = range
        self.type = type
    }

    public enum TermType: String, Sendable, Equatable {
        case masked      // preMask = true
        case normalized  // preMask = false
    }
}

public extension TermHighlightMetadata {
    /// 원문 하이라이트에서 선택된 NSRange와 정확히 겹치는 용어를 반환합니다.
    func matchedEntryForOriginal(nsRange: NSRange, in text: String) -> GlossaryEntry? {
        guard let range = Range(nsRange, in: text) else { return nil }
        return originalTermRanges.first(where: { $0.range == range })?.entry
    }
}
