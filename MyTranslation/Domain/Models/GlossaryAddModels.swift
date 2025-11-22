import Foundation

enum OverlayTextSection: Equatable {
    case original
    case improved
    case primaryFinal
    case primaryPreNormalized
    case alternative(engineID: String)
}

/// 오버레이에서 텍스트 선택 후 노출되는 Glossary 추가 시트 상태.
struct GlossaryAddSheetState: Identifiable, Equatable {
    enum SelectionKind: Equatable {
        case original
        case translated
    }

    struct MatchedTerm: Equatable {
        let key: String
        let entry: GlossaryEntry
    }

    struct UnmatchedTermCandidate: Identifiable, Equatable {
        public let id: UUID = UUID()
        public let termKey: String?
        public let entry: GlossaryEntry
        public let appearanceOrder: Int
        public let similarity: Double
    }

    let id: UUID = UUID()
    let selectedText: String
    let originalText: String
    let selectedRange: NSRange
    let section: OverlayTextSection
    let selectionKind: SelectionKind
    let matchedTerm: MatchedTerm?
    let unmatchedCandidates: [UnmatchedTermCandidate]

    var sectionDescription: String {
        switch section {
        case .original: return "원문"
        case .improved: return "AI 개선 번역"
        case .primaryFinal: return "최종 번역"
        case .primaryPreNormalized: return "정규화 전 번역"
        case .alternative(let engineID): return "대체 번역 (\(engineID))"
        }
    }
}
