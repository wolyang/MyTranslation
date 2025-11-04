//
//  AppLanguage.swift
//  MyTranslation
//
//  Created by OpenAI on 2024/04/06.
//

import Foundation

/// 애플 언어 코드를 기준으로 번역 전반에서 공통 사용되는 언어 정보를 담는다.
public struct AppLanguage: Hashable, Codable, Sendable, Identifiable {
    public let code: String

    /// 애플 언어 코드를 ICU 규격으로 정규화해 저장한다.
    public init(code: String) {
        let canonical = Locale.identifier(.icu, from: code)
        self.code = canonical
    }

    public var id: String { code }

    /// 현재 기기 Locale에 맞춰 사용자에게 보여줄 언어 이름을 생성한다.
    public var displayName: String {
        let locale = Locale.current
        if let localized = locale.localizedString(forIdentifier: code) {
            return localized
        }
        if let localized = locale.localizedString(forLanguageCode: languageCode ?? code) {
            return localized
        }
        return code
    }

    private var localeComponents: Locale.Components {
        Locale.Components(identifier: code)
    }

    /// ISO 언어 코드를 추출한다. (예: "ko", "en")
    public var languageCode: String? {
        localeComponents.languageComponents.languageCode?.identifier
    }

    /// 언어 스크립트 정보를 추출한다. 중국어 간/번체 구분에 사용한다.
    public var scriptCode: String? {
        localeComponents.languageComponents.script?.identifier
    }

    /// Locale에 포함된 지역 코드를 추출한다. 필요 시 엔진별 분기에서 활용한다.
    public var regionCode: String? {
        localeComponents.region?.identifier
    }

    /// 언어/스크립트/지역 정보를 조합해 번역 캐시 키에 사용할 통일된 문자열을 만든다.
    public var normalizedForCacheKey: String {
        var components: [String] = []
        if let languageCode { components.append(languageCode.lowercased()) }
        if let scriptCode { components.append(scriptCode.lowercased()) }
        if let regionCode { components.append(regionCode.uppercased()) }
        if components.isEmpty { return code.lowercased() }
        return components.joined(separator: "-")
    }

    /// 중/일/한 언어인지 여부를 판별해 토큰 간 공백 처리 정책에 활용한다.
    public var isCJK: Bool {
        guard let languageCode = languageCode?.lowercased() else { return false }
        return ["zh", "ja", "ko"].contains(languageCode)
    }
}

/// 자동 감지/수동 지정 여부를 함께 보관하는 출발 언어 선택 상태.
public enum SourceLanguageSelection: Equatable, Sendable {
    case auto(detected: AppLanguage?)
    case manual(AppLanguage)

    /// 실제로 번역 엔진에 전달할 언어를 반환한다. 자동 감지 미완료 시 nil.
    public var resolved: AppLanguage? {
        switch self {
        case .auto(let detected):
            return detected
        case .manual(let language):
            return language
        }
    }

    /// 사용자가 수동으로 언어를 고른 상태인지 여부.
    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    /// 자동 모드일 때 감지 결과를 반영해 새로운 상태를 반환한다.
    public func updatingDetectedLanguage(_ language: AppLanguage?) -> SourceLanguageSelection {
        switch self {
        case .auto:
            return .auto(detected: language)
        case .manual:
            return self
        }
    }

    /// UI에 노출하기 위한 문자열 표현을 생성한다.
    public var description: String {
        switch self {
        case .auto(let detected):
            if let detected {
                return "자동 (\(detected.displayName))"
            }
            return "자동"
        case .manual(let language):
            return language.displayName
        }
    }

    /// 자동 감지 결과가 없을 때 기기 기본 언어를 사용하도록 보정한다.
    public var effectiveLanguage: AppLanguage {
        switch self {
        case .manual(let language):
            return language
        case .auto(let detected):
            if let detected { return detected }
            let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
            return AppLanguage(code: identifier)
        }
    }
}

/// 토큰 마스킹 시 공백 삽입 전략을 정의한다.
public enum TokenSpacingBehavior: Sendable, Equatable {
    case disabled
    case isolatedSegments
}
