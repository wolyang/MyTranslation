import Foundation

/// GlossaryEntry 중복 제거 유틸.
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
                // variants 병합
                existing.variants.formUnion(entry.variants)
                // prohibitStandalone 병합: AND 연산
                // Pattern 기반 엔트리는 prohibitStandalone == false이므로,
                // && 연산 시 "모두 금지(true)여야만 금지 유지" 정책을 따른다.
                // 즉, Pattern 엔트리가 하나라도 있으면(false) 허용으로 변경됨.
                existing.prohibitStandalone =
                    existing.prohibitStandalone && entry.prohibitStandalone
                // componentTerms 병합 (좌/우 순서 보존)
                var seenKeys: Set<String> = []
                existing.componentTerms = (existing.componentTerms + entry.componentTerms)
                    .filter { seenKeys.insert($0.key).inserted }
                existing.activatorKeys.formUnion(entry.activatorKeys)
                existing.activatesKeys.formUnion(entry.activatesKeys)
                map[key] = existing
            } else {
                map[key] = entry
            }
        }

        return Array(map.values)
    }
}
