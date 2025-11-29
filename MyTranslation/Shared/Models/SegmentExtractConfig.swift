import Foundation

public struct SegmentExtractConfig: Sendable, Equatable {
    public let preferredLength: Int
    public let maxLength: Int

    public init(preferredLength: Int, maxLength: Int) {
        self.preferredLength = preferredLength
        self.maxLength = maxLength
    }
}
