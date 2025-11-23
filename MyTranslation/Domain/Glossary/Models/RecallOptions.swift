import Foundation

public enum ScriptKind: Int16, Sendable {
    case unknown = 0
    case hangul = 1
    case cjk = 2
    case latin = 3
    case mixed = 4
}

public struct RecallOptions: Sendable {
    public var gram: Int = 2
    public var minHitPerTerm: Int = 1
    public var allowedScripts: Set<ScriptKind>? = nil
    public var allowedLenBuckets: Set<Int16>? = nil

    public var enableUnigramRecall: Bool = true           // 1-gram도 조회
    public var unigramScripts: Set<ScriptKind> = [.cjk]   // 1-gram은 CJK만
    public var maxDistinctUnigrams: Int = 512             // 과리콜 방지 상한

    public init() { }
}
