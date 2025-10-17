//
//  TermMasker.swift
//  MyTranslation
//

import Foundation

@inline(__always)
public func hangulFinalJongInfo(_ s: String) -> (hasBatchim: Bool, isRieul: Bool) {
    guard let last = s.unicodeScalars.last else { return (false, false) }
    let v = Int(last.value)
    guard (0xAC00...0xD7A3).contains(v) else { return (false, false) }
    let idx = v - 0xAC00
    let jong = idx % 28
    if jong == 0 { return (false, false) }
    return (true, jong == 8) // 8 == ㄹ
}

// MARK: - Term-only Masker

public final class TermMasker {

    private var nextIndex: Int = 1
    public init() {}

    /// 용어 사전(glossary: 원문→한국어)을 이용해 텍스트 내 용어를 ⟪Tn⟫로 잠그고 LockInfo를 생성한다.
    /// - 반환: masked(⟪Tn⟫ 포함), tags(기존 라우터용), locks(조사 교정/언락용)
    public func maskWithLocks(segment: Segment, glossary entries: [GlossaryEntry],
                              surroundWithNBSP: Bool = true) -> MaskedPack {
        let text = segment.originalText
        guard !text.isEmpty, !entries.isEmpty else { return .init(seg:segment, masked: text, tags: [], locks: [:]) }

        // 긴 키부터 치환(겹침 방지)
        let sorted = entries.sorted { $0.source.count > $1.source.count }

        var out = text
        var tags: [String] = []
        var locks: [String: LockInfo] = [:]

        for e in sorted {
            guard !e.source.isEmpty, out.contains(e.source) else { continue }
            
            let prefix: String
            switch e.category {
            case .person:       prefix = "P"
            case .organization: prefix = "O"
            case .term:         prefix = "K"
            case .other:        prefix = "X"
            }

            // === 토큰 생성 ===
            let token: String
            if e.category == .person {
                token = "__PERSON_\(prefix)\(nextIndex)__"   // 표준 인명 토큰(단일 규칙)
            } else {
                token = "⟪\(prefix)\(nextIndex)⟫"            // 기타 카테고리: 기존 각괄호 토큰 유지
            }
            nextIndex += 1

            // 텍스트 치환
            out = out.replacingOccurrences(of: e.source, with: token)
            
            // NBSP 경계 힌트(선택)
            if surroundWithNBSP {
                out = out.replacingOccurrences(of: token, with: "\u{00A0}" + token + "\u{00A0}")
            }

            // 라우터 unmask 호환을 위해 tags는 기존과 동일한 의미로 유지(필요 시 원래 규약에 맞춰 조정)
            tags.append(e.target)

            // 조사 교정용 LockInfo
            let (b, r) = hangulFinalJongInfo(e.target)
            locks[token] = LockInfo(placeholder: token, target: e.target, endsWithBatchim: b, endsWithRieul: r, category: e.category)
        }
        
        return .init(seg: segment, masked: out, tags: tags, locks: locks)
    }

    /// ⟪Tn⟫ 주변 조사(은/는, 이/가, 을/를, 과/와, (이)라, (으)로, (아/야)) 교정
    public func fixParticlesAroundLocks(_ text: String, locks: [String: LockInfo]) -> String {
        var out = text
        for (_, info) in locks {
            out = fixAroundToken(out, token: info.placeholder, info: info)
        }
        return out
    }
    
    /// 번역 결과에서 ⟪G0⟫, ⟪G1⟫ ... 토큰을 사전에 저장한 타깃 한글로 복원.
    func unmask(text: String, tags: [String]) -> String {
        guard !tags.isEmpty else { return text }
        var out = text
        for (i, val) in tags.enumerated() {
            let token = "⟪G\(i)⟫"
            out = out.replacingOccurrences(of: token, with: val)
        }
        return out
    }

    /// ⟪Tn⟫ 토큰들을 locks 사전에 따라 정확히 복원.
    /// 인접 토큰(예: ⟪T18⟫⟪T19⟫)도 안전하게 처리한다.
    func unlockTermsSafely(_ text: String, locks: [String: LockInfo]) -> String {
        // ⟪T123⟫ 형태만 정확히 매칭
        // 지원 토큰: 1) ⟪Xn⟫ 계열(⟪P/O/L/K/Xn⟫)  2) __PERSON_Pn__
            let pattern = #"(__PERSON_[A-Z]\d+__)|(?:⟪[A-Z]\d+⟫)"#
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let ns = text as NSString
        let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))

        // 매치 구간을 기준으로 앞에서부터 차곡차곡 빌드
        var out = String()
        out.reserveCapacity(text.utf16.count)
        var last = 0

        for m in matches {
            let range = m.range(at: 0) // 전체 토큰
            if last < range.location {
                out += ns.substring(with: NSRange(location: last, length: range.location - last))
            }
            let placeholder = ns.substring(with: range)
            if let lock = locks[placeholder] {
                out += lock.target           // 정상 복원
            } else {
                out += placeholder           // 사전에 없으면 원형 유지(보수적)
            }
            last = range.location + range.length
        }

        // 남은 꼬리 복사
        if last < ns.length {
            out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        }

        return out
    }


    // MARK: Impl (조사 교정 세부)
    private func fixAroundToken(_ s: String, token: String, info: LockInfo) -> String {
        // 1) 안전한 패턴 파츠
        let t  = NSRegularExpression.escapedPattern(for: token)
        let ws = "(?:\\s|\\u00A0)*" // 공백 + NBSP (0개 이상)

        var str = s

        // 2) 을/를
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "를", token + "을")
        } else {
            str = rxReplace(str, t + ws + "을", token + "를")
        }

        // 3) 은/는
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "는", token + "은")
        } else {
            str = rxReplace(str, t + ws + "은", token + "는")
        }

        // 4) 이/가
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "가", token + "이")
        } else {
            str = rxReplace(str, t + ws + "이", token + "가")
        }

        // 5) 과/와
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "와", token + "과")
        } else {
            str = rxReplace(str, t + ws + "과", token + "와")
        }

        // 6) (이)라
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "라", token + "이라")
        } else {
            str = rxReplace(str, t + ws + "이라", token + "라")
        }

        // 7) (으)로 — ㄹ 특례
        if info.endsWithBatchim {
            if info.endsWithRieul {
                str = rxReplace(str, t + ws + "으로", token + "로")   // ㄹ 받침이면 무조건 '로'
            } else {
                str = rxReplace(str, t + ws + "로", token + "으로")   // 일반 받침: '로'→'으로'
            }
        } else {
            str = rxReplace(str, t + ws + "으로", token + "로")       // 받침 없음: '으로'→'로'
        }

        // 8) 아/야
        if info.endsWithBatchim {
            str = rxReplace(str, t + ws + "야", token + "아")
        } else {
            str = rxReplace(str, t + ws + "아", token + "야")
        }

        return str
    }
    
    func rxReplace(_ str: String, _ pattern: String, _ repl: String) -> String {
        do {
            let rx = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(str.startIndex..., in: str)
            return rx.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: repl)
        } catch {
            print("[JOSA][ERR] invalid regex: \(pattern) error=\(error)")
            return str
        }
    }

}
