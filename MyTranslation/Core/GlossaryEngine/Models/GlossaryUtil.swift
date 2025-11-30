import Foundation

extension Glossary {
    enum Util {
        typealias SDTerm = Glossary.SDModel.SDTerm
        typealias SDSource = Glossary.SDModel.SDSource

        static func scriptKind(of ch: Character) -> ScriptKind {
            guard let u = ch.unicodeScalars.first else { return .unknown }
            switch u.value {
            case 0xAC00...0xD7A3: return .hangul
            case 0x4E00...0x9FFF: return .cjk
            case 0x0041...0x007A, 0x0030...0x0039: return .latin
            default: return .unknown
            }
        }

        static func char(_ ch: Character, isIn scripts: Set<ScriptKind>) -> Bool {
            scripts.contains(scriptKind(of: ch))
        }

        static func detectScriptKind(_ s: String) -> ScriptKind {
            var hasH = false
            var hasC = false
            var hasL = false
            for u in s.unicodeScalars {
                switch u.value {
                case 0xAC00...0xD7A3: hasH = true
                case 0x4E00...0x9FFF: hasC = true
                case 0x0041...0x007A, 0x0030...0x0039: hasL = true
                default: break
                }
            }
            let flags = (hasH ? 1 : 0) + (hasC ? 2 : 0) + (hasL ? 4 : 0)
            switch flags {
            case 1: return .hangul
            case 2: return .cjk
            case 4: return .latin
            case 0: return .unknown
            default: return .mixed
            }
        }

        static func lengthBucket(_ n: Int) -> Int16 {
            switch n {
            case 0...2: return 2
            case 3...4: return 4
            case 5...8: return 8
            case 9...16: return 16
            case 17...24: return 24
            default: return 32
            }
        }

        static func qgrams(_ s: String, n: Int) -> [String] {
            guard n > 0, s.count >= n else { return [] }
            var out: [String] = []
            let arr = Array(s)
            for i in 0..<(arr.count - n + 1) { out.append(String(arr[i..<(i+n)])) }
            return out
        }
        
        // MARK: - placeholder 추출 (slot 이름)

                /// 예: "{name_1}{name_2}" -> ["name_1", "name_2"]
                /// (여기서는 slot = 템플릿에 적힌 placeholder 이름을 그대로 사용)
                static func extractSlots(from template: String) -> [String] {
                    var slots: [String] = []
                    var current = ""
                    var inside = false

                    for ch in template {
                        if ch == "{" {
                            inside = true
                            current = ""
                        } else if ch == "}" {
                            if inside, !current.isEmpty {
                                slots.append(current)
                            }
                            inside = false
                        } else if inside {
                            current.append(ch)
                        }
                    }

                    // 같은 slot이 여러 번 나오더라도 한 번만 있으면 충분
                    return Array(Set(slots))
                }

        // MARK: - Target 렌더링

        /// tpl: "{slot1}{slot2}"
        /// componentsBySlot: ["slot1": comp1, "slot2": comp2]
        /// AppearedTerm.target을 써서 최종 target 문자열 생성
        static func renderTarget(
            _ tpl: String,
            componentsBySlot: [String: AppearedComponent]
        ) -> String {
            var t = tpl
            for (slot, comp) in componentsBySlot {
                t = t.replacingOccurrences(of: "{\(slot)}",
                                           with: comp.appearedTerm.target)
            }
            return t
        }

        // MARK: - Source 렌더링 (sources: [String] 전부 조합)

        /// AppearedTerm.sources의 곱집합을 모두 펼쳐서 RenderSource 배열 리턴
        static func renderSources(
            _ tpl: String,
            componentsBySlot: [String: AppearedComponent]
        ) -> [(composed: String, sourcesBySlot: [String: String])] {
            let slotsInTpl = extractSlots(from: tpl)

            // slot별 source 후보 목록 만들기
            var sourcesBySlot: [String: [String]] = [:]

            for slot in slotsInTpl {
                if let comp = componentsBySlot[slot] {
                    let term = comp.appearedTerm
                    let candidates = term.appearedSources.map { $0.text }
                    sourcesBySlot[slot] = candidates
                } else {
                    sourcesBySlot[slot] = [""]
                }
            }

            var results: [(composed: String, sourcesBySlot: [String: String])] = []

            func dfs(
                _ index: Int,
                _ currentParts: [String: String]
            ) {
                if index == slotsInTpl.count {
                    var composed = tpl
                    var partsBySlot: [String: String] = [:]

                    for slot in slotsInTpl {
                        let part = currentParts[slot] ?? ""
                        partsBySlot[slot] = part
                        composed = composed.replacingOccurrences(of: "{\(slot)}",
                                                                 with: part)
                    }

                    results.append((composed: composed,
                                    sourcesBySlot: partsBySlot))
                    return
                }

                let slot = slotsInTpl[index]
                let candidates = sourcesBySlot[slot] ?? []

                for s in candidates {
                    var next = currentParts
                    next[slot] = s
                    dfs(index + 1, next)
                }
            }

            dfs(0, [:])
            return results
        }

        // MARK: - Variants 렌더링 (target variants)

        /// 템플릿들 + slot별 AppearedComponent로 가능한 모든 variant 문자열 생성
        static func renderVariants(
            templates: [String],
            componentsBySlot: [String: AppearedComponent]
        ) -> [String] {
            var results = Set<String>()

            for tpl in templates {
                let slotsInTpl = extractSlots(from: tpl)

                // slot별 후보 문자열 목록 (variants 없으면 target 하나만)
                var variantsBySlot: [String: [String]] = [:]

                for slot in slotsInTpl {
                    guard let comp = componentsBySlot[slot] else {
                        variantsBySlot[slot] = [""]
                        continue
                    }
                    let term = comp.appearedTerm
                    let vs = term.variants.isEmpty ? [term.target] : term.variants
                    variantsBySlot[slot] = vs
                }

                func dfs(
                    _ index: Int,
                    _ currentReplacements: [String: String]
                ) {
                    if index == slotsInTpl.count {
                        var s = tpl
                        for (slot, value) in currentReplacements {
                            s = s.replacingOccurrences(of: "{\(slot)}", with: value)
                        }
                        results.insert(s)
                        return
                    }

                    let slot = slotsInTpl[index]
                    let candidates = variantsBySlot[slot] ?? [""]

                    for v in candidates {
                        var next = currentReplacements
                        next[slot] = v
                        dfs(index + 1, next)
                    }
                }

                dfs(0, [:])
            }

            return Array(results)
        }
        
        
        // MARK: - regarcy

        static func renderSources(_ tpl: String, joiner J: String?, L: SDTerm, R: SDTerm?) -> [(composed: String, left: String, right: String)] {
            var s = tpl
            if let J { s = s.replacingOccurrences(of: "{J}", with: J) }
            var sources: [(String, String, String)] = []
            for ls in L.sources {
                let replacedL = s.replacingOccurrences(of: "{L}", with: ls.text)
                if let R {
                    for rs in R.sources {
                        let replacedR = replacedL.replacingOccurrences(of: "{R}", with: rs.text)
                        sources.append((replacedR, ls.text, rs.text))
                    }
                } else {
                    sources.append((replacedL, ls.text, ""))
                }
            }
            return sources
        }

        static func renderTarget(_ tpl: String, L: SDTerm, R: SDTerm?) -> String {
            var t = tpl
            t = t.replacingOccurrences(of: "{L}", with: L.target)
            if let R { t = t.replacingOccurrences(of: "{R}", with: R.target) }
            return t
        }

        static func renderVariants(_ tpl: String, joiners: [String], L: SDTerm, R: SDTerm?) -> [String] {
            if let R {
                var reverseTpl = tpl.replacingOccurrences(of: "{L}", with: "{T}")
                reverseTpl = reverseTpl.replacingOccurrences(of: "{R}", with: "{L}")
                reverseTpl = reverseTpl.replacingOccurrences(of: "{T}", with: "{R}")
                let lAll = L.variants + [L.target]
                let rAll = R.variants + [R.target]
                let tpls: [String] = [tpl, reverseTpl]
                var variants: [String] = []
                for lv in lAll {
                    for rv in rAll {
                        for j in joiners {
                            for t in tpls {
                                var s = t
                                s = s.replacingOccurrences(of: "{J}", with: j)
                                s = s.replacingOccurrences(of: "{L}", with: lv)
                                s = s.replacingOccurrences(of: "{R}", with: rv)
                                variants.append(s)
                            }
                        }
                    }
                }
                return variants
            } else {
                return L.variants.map {
                    tpl.replacingOccurrences(of: "{L}", with: $0)
                }
            }
        }
    }
}
