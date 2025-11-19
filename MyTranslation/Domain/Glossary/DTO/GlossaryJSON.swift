//  GlossaryJSON.swift

import Foundation

// MARK: - JSON Schemas

public struct JSSource: Codable, Hashable {
    public var source: String
    public var prohibitStandalone: Bool
}

public struct JSTerm: Codable, Hashable {
    public var key: String
    public var sources: [JSSource]
    public var target: String
    public var variants: [String]
    public var tags: [String]
    public var components: [JSComponent]
    public var isAppellation: Bool
    public var preMask: Bool
}

public struct JSComponent: Codable, Hashable {
    public var pattern: String            // ex) "person", "cp", "ultraAffix"
    public var roles: [String]?           // ex) ["family"], ["given"], nil(무역할)
    public var groups: [String]?          // ex) ["쿠레나이가이"], ["m78","z"], nil
    
    public var srcTplIdx: Int?             // sourceTemplates[] 중 몇 번째? (기본: 0)
    public var tgtTplIdx: Int?             // targetTemplates[] 중 몇 번째? (기본: 0)
}

public struct JSTermSelector: Codable, Hashable {
    public var roles: [String]?           // 예: ["family"], ["given"], nil
    public var tagsAll: [String]?         // AND
    public var tagsAny: [String]?         // OR
    public var includeTermKeys: [String]? // 고정 포함
    public var excludeTermKeys: [String]? // 명시 제외
}

public enum JSGrouping: String, Codable, Hashable {
    case none
    case optional
    case required
}

public struct JSPattern: Codable, Hashable {
    public var name: String
    public var left: JSTermSelector?
    public var right: JSTermSelector?
    public var skipPairsIfSameTerm: Bool
    
    public var sourceJoiners: [String]    // 예: [" ", "・"]
    public var sourceTemplates: [String]  // 예: ["{L}{J}{R}"]
    public var targetTemplates: [String]  // 예: ["{L} {R}", "{R} {L}"]
    
    // 조합 결과물 메타(출력 토큰에 적용)
    public var isAppellation: Bool
    public var preMask: Bool
    
    public var displayName: String
    public var roles: [String]
    public var grouping: JSGrouping
    public var groupLabel: String?
    
    // 새 Term 기본값(패턴 기반 프리셋)
    public var defaultProhibitStandalone: Bool
    public var defaultIsAppellation: Bool
    public var defaultPreMask: Bool
    
    // 조합을 구성하는 Term이 prohibitStandAlone = true일 때, 다른 쪽 Term이 세그먼트에 존재한다면 처음 Term도 entry에 포함시켜 정규화한다.
    public var needPairCheck: Bool
}

struct JSBundle: Codable, Hashable {
    var terms: [JSTerm]
    var patterns: [JSPattern]
}
