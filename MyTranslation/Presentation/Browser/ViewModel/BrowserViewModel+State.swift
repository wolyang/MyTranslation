import CoreGraphics
import Foundation

extension BrowserViewModel {
    struct PageLanguagePreference: Equatable {
        var source: SourceLanguageSelection
        var target: AppLanguage

        var sourceDescription: String { source.description }
        var targetDescription: String { target.displayName }
    }

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
        var translations: [Translation] = []
        var showsOriginalSection: Bool = true
    }
}
