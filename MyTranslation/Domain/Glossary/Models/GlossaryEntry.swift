import Foundation

/// Glossary 엔트리를 표현하는 도메인 모델.
public struct GlossaryEntry: Sendable, Hashable {
    /// 엔트리를 구성하는 Term 정보 스냅샷.
    public struct ComponentTerm: Sendable, Hashable {
        public struct Source: Sendable, Hashable {
            public let text: String
            public let prohibitStandalone: Bool

            public init(text: String, prohibitStandalone: Bool) {
                self.text = text
                self.prohibitStandalone = prohibitStandalone
            }
        }

        public let key: String
        public let target: String
        public let variants: Set<String>
        public let sources: [Source]
        public let matchedSources: Set<String>
        public let preMask: Bool
        public let isAppellation: Bool
        public let activatorKeys: Set<String>
        public let activatesKeys: Set<String>

        public init(
            key: String,
            target: String,
            variants: Set<String>,
            sources: [Source],
            matchedSources: Set<String>,
            preMask: Bool,
            isAppellation: Bool,
            activatorKeys: Set<String>,
            activatesKeys: Set<String>
        ) {
            self.key = key
            self.target = target
            self.variants = variants
            self.sources = sources
            self.matchedSources = matchedSources
            self.preMask = preMask
            self.isAppellation = isAppellation
            self.activatorKeys = activatorKeys
            self.activatesKeys = activatesKeys
        }
    }

    public var source: String
    public var target: String
    public var variants: Set<String>
    public var preMask: Bool
    public var isAppellation: Bool
    public var prohibitStandalone: Bool

    public enum Origin: Sendable, Hashable {
        case termStandalone(termKey: String)
        /// composerId/needPairCheck는 패턴 제어를 위해 포함하며, leftKey는 필수(L-only 패턴은 rightKey가 nil).
        case composer(composerId: String, leftKey: String, rightKey: String?, needPairCheck: Bool)
    }
    public var origin: Origin

    /// 조합 엔트리의 구성 Term 정보(standalone은 1개, composer는 L/R 각각 포함).
    public var componentTerms: [ComponentTerm] = []

    // 조건부 활성화 관계 정보
    public var activatorKeys: Set<String> = []   // 이 Entry를 활성화하는 Term 키들
    public var activatesKeys: Set<String> = []   // 이 Entry가 활성화하는 Term 키들

    public init(
        source: String,
        target: String,
        variants: Set<String>,
        preMask: Bool,
        isAppellation: Bool,
        prohibitStandalone: Bool,
        origin: Origin,
        componentTerms: [ComponentTerm] = [],
        activatorKeys: Set<String> = [],
        activatesKeys: Set<String> = []
    ) {
        self.source = source
        self.target = target
        self.variants = variants
        self.preMask = preMask
        self.isAppellation = isAppellation
        self.prohibitStandalone = prohibitStandalone
        self.origin = origin
        self.componentTerms = componentTerms
        self.activatorKeys = activatorKeys
        self.activatesKeys = activatesKeys
    }
}
