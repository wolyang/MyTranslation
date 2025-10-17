// Services/GlossarySeeder.swift
import Foundation
import SwiftData

/// 앱 번들에 포함된 terms.json을 처음 실행 시(or 버전 갱신 시) SwiftData로 시드.
enum GlossarySeeder {
    private static let seededVersionKey = "seededTermsVersion" // UserDefaults key

    static func seedIfNeeded(_ modelContext: ModelContext) {
        // 1) 번들에서 terms.json 찾기
        guard let url = Bundle.main.url(forResource: "terms", withExtension: "json") else {
            print("GlossarySeeder: terms.json not found in bundle.")
            return
        }

        // 2) 디코드
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GlossaryJSON.self, from: data)

            // 개발중 임시 주석 처리
//            // 3) 이미 같은/더 높은 버전을 시드했다면 스킵
//            let currentSeededVer = UserDefaults.standard.integer(forKey: seededVersionKey)
//            if decoded.meta.version <= currentSeededVer {
//                print("GlossarySeeder: already seeded version \(currentSeededVer). skip.")
//                return
//            }

            // 4) 기존 용어들 로드 (중복/업데이트 처리 대비)
            var fetch = FetchDescriptor<Term>()
            let existing = (try? modelContext.fetch(fetch)) ?? []
            var existingBySource: [String: Term] = [:]
            existing.forEach { existingBySource[$0.source] = $0 }

            // 5) upsert
            for item in decoded.terms {
                if let exist = existingBySource[item.source] {
                    // 업데이트
                    exist.target = item.target
                    exist.strict = item.strict ?? exist.strict
                    exist.variants = item.variants ?? exist.variants
                    exist.notes = item.notes ?? exist.notes
                    exist.category = item.category ?? exist.category
                } else {
                    // 신규
                    let t = Term(
                        source: item.source,
                        target: item.target,
                        strict: item.strict ?? true,
                        variants: item.variants ?? [],
                        notes: item.notes,
                        category: item.category
                    )
                    modelContext.insert(t)
                }
            }

            try modelContext.save()

            // 6) 성공적으로 저장했다면 버전 기록
            UserDefaults.standard.set(decoded.meta.version, forKey: seededVersionKey)
            print("GlossarySeeder: seeded terms v\(decoded.meta.version) (\(decoded.terms.count) items).")
        } catch {
            print("GlossarySeeder error:", error)
        }
    }
}
