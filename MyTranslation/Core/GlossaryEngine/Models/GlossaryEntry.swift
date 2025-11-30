import Foundation

/// Glossary 엔트리를 표현하는 도메인 모델.
public struct GlossaryEntry: Sendable, Hashable {
    /// 엔트리를 구성하는 Term 정보 스냅샷.
    public struct ComponentTerm: Sendable, Hashable {
        public let key: String
        public let target: String
        public let variants: [String]
        public let source: String

        public init(
            key: String,
            target: String,
            variants: [String],
            source: String
        ) {
            self.key = key
            self.target = target
            self.variants = variants
            self.source = source
        }
    }

    public var source: String
    public var target: String
    public var variants: [String]
    public var preMask: Bool
    public var isAppellation: Bool

    public enum Origin: Sendable, Hashable {
        case termStandalone(termKey: String)
        /// composerId는 패턴 제어를 위해 포함하며, termKeys는 1개 이상 필수
        case composer(composerId: String, termKeys: [String])
    }
    public var origin: Origin

    /// 조합 엔트리의 구성 Term 정보(standalone은 1개, composer는 모두 포함).
    public var componentTerms: [ComponentTerm] = []

    public init(
        source: String,
        target: String,
        variants: [String],
        preMask: Bool,
        isAppellation: Bool,
        origin: Origin,
        componentTerms: [ComponentTerm] = []
    ) {
        self.source = source
        self.target = target
        self.variants = variants
        self.preMask = preMask
        self.isAppellation = isAppellation
        self.origin = origin
        self.componentTerms = componentTerms
    }
}
