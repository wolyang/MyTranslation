import Foundation

/// GlossaryEntry 중복 제거 유틸.
/// 주의: 반환 배열의 순서는 입력 순서를 보존하지 않는다.
/// 순서 의미가 필요한 소비자(예: 원문 위치 기준 정렬)는 deduplicate 이후에 별도 정렬 단계를 수행해야 한다.
public enum Deduplicator {
    public static func deduplicate(_ entries: [GlossaryEntry]) -> [GlossaryEntry] {
        struct Key: Hashable {
            let source: String
            let target: String
            let preMask: Bool
            let isAppellation: Bool
        }

        var map: [Key: GlossaryEntry] = [:]

        for entry in entries {
            let key = Key(
                source: entry.source,
                target: entry.target,
                preMask: entry.preMask,
                isAppellation: entry.isAppellation
            )

            if var existing = map[key] {
                // variants 병합 (중복 제거)
                var seen: Set<String> = []
                existing.variants = (existing.variants + entry.variants)
                    .filter { seen.insert($0).inserted }
                // componentTerms 병합 (좌/우 순서 보존)
                var seenKeys: Set<String> = []
                existing.componentTerms = (existing.componentTerms + entry.componentTerms)
                    .filter { seenKeys.insert($0.key).inserted }
                map[key] = existing
            } else {
                map[key] = entry
            }
        }

        return Array(map.values)
    }
}
