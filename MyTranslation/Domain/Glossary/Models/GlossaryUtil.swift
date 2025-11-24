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

        static func filterJoiners(from joiners: [String], in pageText: String) -> [String] {
            if joiners.isEmpty { return [""] }
            if joiners.count <= 1 { return joiners }
            var result = joiners.filter {
                pageText.contains($0)
            }
            if joiners.contains("") {
                result.append("")
            }
            return result
        }

        static func renderSources(_ tpl: String, joiner J: String?, L: SDTerm, R: SDTerm?) -> [String] {
            var s = tpl
            if let J { s = s.replacingOccurrences(of: "{J}", with: J) }
            var sources: [String] = []
            for ls in L.sources {
                let replacedL = s.replacingOccurrences(of: "{L}", with: ls.text)
                if let R {
                    for rs in R.sources {
                        let replacedR = replacedL.replacingOccurrences(of: "{R}", with: rs.text)
                        sources.append(replacedR)
                    }
                } else {
                    sources.append(replacedL)
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
