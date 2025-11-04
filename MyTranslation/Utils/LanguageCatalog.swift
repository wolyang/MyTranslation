//
//  LanguageCatalog.swift
//  MyTranslation
//
//  Created by OpenAI on 2024/04/06.
//

import Foundation

/// 앱 전역에서 사용할 언어 목록과 기본값을 관리한다.
enum LanguageCatalog {
    /// 주소창에서 사용자가 선택할 수 있는 수동 출발 언어 목록을 반환한다.
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

    /// 번역 도착 언어 후보를 기기 설정을 우선으로 정렬해 반환한다.
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

    /// 기기의 선호 언어에서 지역 코드를 제거하고, 중국어만 스크립트 정보를 보존한다.
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

    /// 기본 출발 언어는 자동 감지로 시작한다.
    static func defaultSourceSelection() -> SourceLanguageSelection {
        .auto(detected: nil)
    }
}
