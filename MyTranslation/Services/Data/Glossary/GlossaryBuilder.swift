// Services/GlossaryBuilder.swift
import SwiftData

struct GlossaryBuilder {
    /// SwiftData에서 사람/용어를 읽어 GlossaryEntry[]로 전개
    @MainActor
    static func makeGlossaryEntries(modelContext: ModelContext) throws -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        // 1) PEOPLE → person 엔트리 생성
        let people: [Person] = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        for p in people {
            // family/given 풀네임 후보 생성(구분자: "", " ", "·", "・", "-")
            let seps = ["", " ", "·", "・", "-"]
            for f in p.familySources {
                for g in p.givenSources {
                    for s in seps {
                        let full = f + s + g
                        let fullKo = [p.familyTarget, p.givenTarget].compactMap { $0 }.joined(separator: " ")
                        if !fullKo.isEmpty {
                            entries.append(.init(source: full, target: fullKo, category: .person))
                        }
                    }
                }
            }
            // 단일 성/이름
            if let ft = p.familyTarget {
                for fs in p.familySources { entries.append(.init(source: fs, target: ft, category: .person)) }
            }
            if let gt = p.givenTarget {
                for gs in p.givenSources { entries.append(.init(source: gs, target: gt, category: .person)) }
            }
            // alias
            for a in p.aliases {
                let tgt = a.target // nil 가능
                for s in a.sources {
                    if let tgt = tgt, !tgt.isEmpty {
                        entries.append(.init(source: s, target: tgt, category: .person))
                    } else {
                        // target이 없는 위험 약칭은 기본적으로 제외(원하면 정책적으로 포함)
                        // entries.append(.init(source: s, target: (p.givenTarget ?? p.familyTarget ?? ""), category: .person))
                    }
                }
            }
        }

        // 2) TERMS → term/other
        let terms: [Term] = (try? modelContext.fetch(FetchDescriptor<Term>())) ?? []
        for t in terms {
            let cat: TermCategory = .init(with: t.category)
            entries.append(.init(source: t.source, target: t.target, category: cat))
        }

        // 최장일치가 유리하므로 길이 내림차순으로 정렬해 두면 좋습니다(마스커에서 한 번 더 정렬해도 OK)
        entries.sort { $0.source.count > $1.source.count }
        return entries
    }
}
