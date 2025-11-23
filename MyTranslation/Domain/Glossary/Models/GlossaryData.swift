import Foundation

/// 데이터 계층에서 서비스 계층으로 전달하는 용어집 데이터.
public struct GlossaryData: Sendable {
    /// 페이지 텍스트에서 실제로 매칭된 Term 목록.
    public let matchedTerms: [Glossary.SDModel.SDTerm]

    /// 전체 Pattern 목록 (조합 용어 생성에 필요).
    public let patterns: [Glossary.SDModel.SDPattern]

    /// Term key별 매칭된 source 텍스트들.
    /// key: termKey, value: 실제로 페이지에 나타난 source 텍스트 집합.
    public let matchedSourcesByKey: [String: Set<String>]

    public init(
        matchedTerms: [Glossary.SDModel.SDTerm],
        patterns: [Glossary.SDModel.SDPattern],
        matchedSourcesByKey: [String: Set<String>]
    ) {
        self.matchedTerms = matchedTerms
        self.patterns = patterns
        self.matchedSourcesByKey = matchedSourcesByKey
    }
}
