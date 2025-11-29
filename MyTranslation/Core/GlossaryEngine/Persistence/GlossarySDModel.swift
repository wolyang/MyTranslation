//
//  GlossarySDModel.swift
//  MyTranslation
//
//  Created by sailor.m on 11/8/25.
//

import Foundation
import SwiftData

extension Glossary.SDModel {
    @Model
    public final class SDTerm {
        @Attribute(.unique) var key: String
        var target: String
        var variants: [String] = []

        var isAppellation: Bool = false
        var preMask: Bool = false

        @Relationship(deleteRule: .cascade) var sources: [SDSource] = []
        @Relationship(deleteRule: .cascade) var components: [SDComponent] = []

        // 태그(M:N) - 조인 테이블 경유
        @Relationship(deleteRule: .cascade) var termTagLinks: [SDTermTagLink] = []

        // 문맥 기반 비활성화
        var deactivatedIn: [String] = []

        // 조건부 활성화 관계 (Term 간 상호 참조)
        @Relationship(deleteRule: .nullify, inverse: \SDTerm.activates) var activators: [SDTerm] = []  // 이 Term을 활성화하는 Term 목록
        var activates: [SDTerm] = []  // 이 Term이 활성화하는 Term 목록 (inverse에 의해 자동 관리)
        
        init(
            key: String,
            target: String,
            variants: [String] = [],
            isAppellation: Bool = false,
            preMask: Bool = true,
            sources: [SDSource] = [],
            components: [SDComponent] = [],
            termTagLinks: [SDTermTagLink] = [],
            deactivatedIn: [String] = []
        ) {
            self.key = key
            self.target = target
            self.variants = variants
            self.isAppellation = isAppellation
            self.preMask = preMask
            self.sources = sources
            self.components = components
            self.termTagLinks = termTagLinks
            self.deactivatedIn = deactivatedIn
        }
    }

    @Model
    public final class SDSource {
        var text: String
        var prohibitStandalone: Bool
        @Relationship var term: SDTerm

        init(text: String, prohibitStandalone: Bool, term: SDTerm) {
            self.text = text
            self.prohibitStandalone = prohibitStandalone
            self.term = term
        }
    }
    
    // Q-gram 인덱스 테이블 (bi/tri-gram 폭발 저장)
    @Model
    public final class SDSourceIndex {
        var qgram: String // 검색 키
        var script: Int16 // 0:Unknown 1:Hangul 2:CJK 3:Latin 4:Mixed
        var len: Int16 // 원문 길이 버킷
        @Relationship var term: SDTerm
        
        init(qgram: String, script: Int16, len: Int16, term: SDTerm) {
            self.qgram = qgram
            self.script = script
            self.len = len
            self.term = term
        }
    }
    
    // MARK: - Component / Group
    
    @Model
    public final class SDComponent {
        // 이 Term가 어떤 패턴에서 어떤 역할/그룹/템플릿 인덱스를 쓰는지
        var pattern: String                      // ex) "person", "cp", "ultraAffix"
        var role: String?                        // "family", "given", nil(무역할)
        @Relationship var term: SDTerm

        @Relationship(deleteRule: .cascade) var groupLinks: [SDComponentGroup] = []

        init(pattern: String, role: String? = nil, term: SDTerm) {
            self.pattern = pattern
            self.role = role
            self.term = term
        }
    }

    @Model
    public final class SDGroup {
        // 패턴별 그룹 라벨(동일 이름이라도 패턴이 다르면 별개)
        @Attribute(.unique) var uid: String       // "\(pattern)#\(name)" 등 유일키
        var pattern: String
        var name: String                          // ex) "쿠레나이가이", "m78", "z"

        // 역참조: 이 그룹에 속한 컴포넌트 링크들
        @Relationship(deleteRule: .cascade) var componentLinks: [SDComponentGroup] = []

        init(uid: String, pattern: String, name: String) {
            self.pattern = pattern
            self.name = name
            self.uid = uid
        }
        
        convenience init(pattern: String, name: String) {
            let uid = "\(pattern)#\(name)"
            self.init(uid: uid, pattern: pattern, name: name)
        }
    }

    // 다대다: Component ↔ Group
    @Model
    public final class SDComponentGroup {
        @Relationship var component: SDComponent
        @Relationship var group: SDGroup
        init(component: SDComponent, group: SDGroup) {
            self.component = component
            self.group = group
        }
    }
    
    // MARK: - Tag (용어 태그 자동완성/필터용, M:N)

    @Model
    public final class SDTag {
        @Attribute(.unique) var name: String
        // 역참조: 태그↔용어 링크
        @Relationship(deleteRule: .cascade) var termLinks: [SDTermTagLink] = []
        init(name: String) { self.name = name }
    }

    // 다대다: Term ↔ Tag
    @Model
    public final class SDTermTagLink {
        @Relationship var term: SDTerm
        @Relationship var tag: SDTag
        init(term: SDTerm, tag: SDTag) { self.term = term; self.tag = tag }
    }

    // MARK: - Pattern / Selector (분해 저장)

    @Model
    public final class SDPattern {
        @Attribute(.unique) var name: String          // "person", "cp", "ultraman"...

        // 역할
        var roles: [String] = []

        // 실행 옵션
        var skipPairsIfSameTerm: Bool = true

        // 템플릿 슬롯
        var sourceTemplates: [String]           // ex) ["{family} {given}", ...]
        var targetTemplate: String              // ex) "{family} {given}"
        var variantTemplates: [String]          // ex) ["{family}{given}", "{family}·{given}", ...]
        
        var isAppellation: Bool
        var preMask: Bool
        
        init(name: String, roles: [String] = [], skipPairsIfSameTerm: Bool = true, sourceTemplates: [String] = [""], targetTemplate: String = "", variantTemplates: [String] = [""], isAppellation: Bool = false, preMask: Bool = true) {
            self.name = name
            self.roles = roles
            self.skipPairsIfSameTerm = skipPairsIfSameTerm
            self.sourceTemplates = sourceTemplates
            self.targetTemplate = targetTemplate
            self.variantTemplates = variantTemplates
            self.isAppellation = isAppellation
            self.preMask = preMask
        }
    }

    // UI/편집 메타 — 화면 생성용
    public enum SDPatternGrouping: String, Codable { case none, optional, required }

    @Model
    public final class SDPatternMeta {
        @Attribute(.unique) var name: String          // SDPattern.name과 동일
        var displayName: String

        // 그룹 사용 정책
        var grouping: SDPatternGrouping = SDPatternGrouping.optional
        var groupLabel: String = "그룹"

        // 이 패턴으로 '새 Term' 생성 시 기본값
        var defaultProhibitStandalone: Bool = true
        var defaultIsAppellation: Bool = false
        var defaultPreMask: Bool = false
        
        init(name: String, displayName: String, grouping: SDPatternGrouping, groupLabel: String, defaultProhibitStandalone: Bool, defaultIsAppellation: Bool, defaultPreMask: Bool) {
            self.name = name
            self.displayName = displayName
            self.grouping = grouping
            self.groupLabel = groupLabel
            self.defaultProhibitStandalone = defaultProhibitStandalone
            self.defaultIsAppellation = defaultIsAppellation
            self.defaultPreMask = defaultPreMask
        }
    }
}
