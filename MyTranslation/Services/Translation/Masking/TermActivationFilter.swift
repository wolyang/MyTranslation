import Foundation

/// 용어 비활성화 판단 전용 필터.
/// - Note: Phase 1 단순화 버전 — 세그먼트에 deactivated context 문자열이 등장하면 해당 source를 비활성화한다.
public final class TermActivationFilter {
    public init() { }

    /// Source가 비활성화 문맥 안에 있는지 판단한다.
    /// - Returns: true면 비활성화, false면 유지
    public func shouldDeactivate(
        source: String,
        deactivatedIn: [String],
        segmentText: String
    ) -> Bool {
        guard deactivatedIn.isEmpty == false else { return false }
        for ctx in deactivatedIn where !ctx.isEmpty {
            if segmentText.contains(ctx) { return true }
        }
        return false
    }
}
