//
//  APIKeys.swift
//  MyTranslation
//
//  Created by sailor.m on 10/18/25.
//

import Foundation

enum APIKeys {
    static var googleTranslate: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleAPIKey") as? String ?? ""
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
