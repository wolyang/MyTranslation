import CoreGraphics
import Foundation

extension BrowserViewModel {
    /// 페이지별로 선택된 출발/도착 언어를 묶어 관리한다.
    struct PageLanguagePreference: Equatable {
        var source: SourceLanguageSelection
        var target: AppLanguage

        var sourceDescription: String { source.description }
        var targetDescription: String { target.displayName }
    }

    /// 현재 페이지의 번역 진행 상황과 캐시를 보관한다.
    struct PageTranslationState {
        var url: URL
        var segments: [Segment]
        var totalSegments: Int
        var buffersByEngine: [TranslationEngineID: StreamBuffer]
        var failedSegmentIDs: Set<String>
        var finalizedSegmentIDs: Set<String>
        var scheduledSegmentIDs: Set<String>
        var summary: TranslationStreamSummary?
        var lastEngineID: TranslationEngineID?
        var languagePreference: PageLanguagePreference

        init(url: URL, segments: [Segment], languagePreference: PageLanguagePreference) {
            self.url = url
            self.segments = segments
            self.totalSegments = segments.count
            self.buffersByEngine = [:]
            self.failedSegmentIDs = []
            self.finalizedSegmentIDs = []
            self.scheduledSegmentIDs = []
            self.summary = nil
            self.lastEngineID = nil
            self.languagePreference = languagePreference
        }
    }

    /// 동일 세그먼트 순서를 유지하기 위한 스트림 버퍼.
    struct StreamBuffer {
        private(set) var ordered: [TranslationStreamPayload] = []

        mutating func upsert(_ payload: TranslationStreamPayload) {
            if let index = ordered.firstIndex(where: { $0.segmentID == payload.segmentID }) {
                ordered[index] = payload
            } else {
                ordered.append(payload)
            }
            ordered.sort { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.segmentID < rhs.segmentID
                }
                return lhs.sequence < rhs.sequence
            }
        }

        var segmentIDs: Set<String> { Set(ordered.map { $0.segmentID }) }
    }

    /// 캐시 적용 여부와 남은 세그먼트 ID 집합을 반환하는 구조체.
    struct CacheApplyResult {
        var applied: Bool
        var remainingSegmentIDs: [String]
    }

    struct OverlayState: Equatable {
        struct Translation: Equatable, Identifiable {
            var engineID: TranslationEngineID
            var title: String
            var text: String?
            var isLoading: Bool
            var errorMessage: String?

            var id: String { engineID }
        }

        var segmentID: String
        var selectedText: String
        var improvedText: String?
        var anchor: CGRect
        var primaryEngineTitle: String
        var primaryFinalText: String?
        var primaryPreNormalizedText: String?
        var translations: [Translation] = []
        var showsOriginalSection: Bool = true
    }
}
