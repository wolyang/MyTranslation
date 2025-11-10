//
//  APIKeys.swift
//  MyTranslation
//
//  Created by sailor.m on 10/18/25.
//

import Foundation

enum APIKeys {
    static var google: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleAPIKey") as? String ?? ""
    }

    static var deepl: String {
        // Info.plist에 DeepLAuthKey 항목을 추가하고 실제 API 키를 입력하세요.
        // 예) DeepLAuthKey = "DEEPL-API-KEY"
        return Bundle.main.object(forInfoDictionaryKey: "DeepLAuthKey") as? String ?? ""
    }
}
// endpoint: https://translation.googleapis.com/language/translate/v2
/**
 {
   "q": ["Hello world", "How are you?"],
   "target": "ko",
   "source": "en",
   "format": "text",
   "key": "YOUR_API_KEY"
 }
 */
