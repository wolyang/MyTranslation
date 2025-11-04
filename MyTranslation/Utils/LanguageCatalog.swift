//
//  LanguageCatalog.swift
//  MyTranslation
//
//  Created by OpenAI on 2024/04/06.
//

import Foundation

enum LanguageCatalog {
    static var manualSourceLanguages: [AppLanguage] {
        var languages: [AppLanguage] = [
            AppLanguage(code: "zh-Hans"),
            AppLanguage(code: "zh-Hant"),
            AppLanguage(code: "en"),
            AppLanguage(code: "ja"),
            AppLanguage(code: "ko")
        ]
        let device = defaultTargetLanguage()
        if languages.contains(device) == false {
            languages.append(device)
        }
        return languages
    }

    static var targetLanguages: [AppLanguage] {
        var languages: [AppLanguage] = [
            AppLanguage(code: "ko"),
            AppLanguage(code: "en"),
            AppLanguage(code: "ja"),
            AppLanguage(code: "zh-Hans"),
            AppLanguage(code: "zh-Hant")
        ]
        let device = defaultTargetLanguage()
        if languages.contains(device) == false {
            languages.insert(device, at: 0)
        }
        return languages
    }

    static func defaultTargetLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let components = Locale.Components(identifier: preferred)

        if let languageCode = components.languageComponents.languageCode?.identifier {
            var identifier = languageCode

            if languageCode.lowercased() == "zh",
               let script = components.languageComponents.script?.identifier {
                identifier += "-\(script)"
            }

            return AppLanguage(code: identifier)
        }

        return AppLanguage(code: preferred)
    }

    static func defaultSourceSelection() -> SourceLanguageSelection {
        .auto(detected: nil)
    }
}
