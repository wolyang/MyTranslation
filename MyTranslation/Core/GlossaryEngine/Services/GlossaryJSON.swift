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
    public var deactivatedIn: [String] = []
    public var activatedByKeys: [String]?  // 이 Term을 활성화하는 Term 키들 (nil = [])
}

public struct JSComponent: Codable, Hashable {
    public var pattern: String            // ex) "person", "cp", "ultraAffix"
    public var role: String?              // ex) "family", "given", nil(무역할)
    public var groups: [String]?          // ex) ["쿠레나이가이"], ["m78","z"], nil
}

public enum JSGrouping: String, Codable, Hashable {
    case none
    case optional
    case required
}

public struct JSPattern: Codable, Hashable {
    public var name: String
    public var skipPairsIfSameTerm: Bool
    
    public var sourceTemplates: [String]  // 예: ["{L} {R}"]
    public var targetTemplate: String     // 예: "{L} {R}"
    public var variantTemplates: [String] // 예: ["{L} {R}", "{R} {L}"]
    
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
}

struct JSBundle: Codable, Hashable {
    var terms: [JSTerm]
    var patterns: [JSPattern]
}
