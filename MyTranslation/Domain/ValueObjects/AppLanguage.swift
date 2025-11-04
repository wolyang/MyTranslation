//
//  AppLanguage.swift
//  MyTranslation
//
//  Created by OpenAI on 2024/04/06.
//

import Foundation

public struct AppLanguage: Hashable, Codable, Sendable, Identifiable {
    public let code: String

    public init(code: String) {
        let canonical = Locale.canonicalIdentifier(from: code) ?? code
        self.code = canonical
    }

    public var id: String { code }

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

    public var languageCode: String? {
        localeComponents.languageComponents.languageCode?.identifier
    }

    public var scriptCode: String? {
        localeComponents.languageComponents.script?.identifier
    }

    public var regionCode: String? {
        localeComponents.region?.identifier
    }

    public var normalizedForCacheKey: String {
        var components: [String] = []
        if let languageCode { components.append(languageCode.lowercased()) }
        if let scriptCode { components.append(scriptCode.lowercased()) }
        if let regionCode { components.append(regionCode.uppercased()) }
        if components.isEmpty { return code.lowercased() }
        return components.joined(separator: "-")
    }

    public var isCJK: Bool {
        guard let languageCode = languageCode?.lowercased() else { return false }
        return ["zh", "ja", "ko"].contains(languageCode)
    }
}

public enum SourceLanguageSelection: Equatable, Sendable {
    case auto(detected: AppLanguage?)
    case manual(AppLanguage)

    public var resolved: AppLanguage? {
        switch self {
        case .auto(let detected):
            return detected
        case .manual(let language):
            return language
        }
    }

    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    public func updatingDetectedLanguage(_ language: AppLanguage?) -> SourceLanguageSelection {
        switch self {
        case .auto:
            return .auto(detected: language)
        case .manual:
            return self
        }
    }

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

public enum TokenSpacingBehavior: Sendable, Equatable {
    case disabled
    case isolatedSegments
}
