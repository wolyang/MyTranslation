//
//  FMCacheKeys.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

enum FMCacheKeys {
    static func translationKey(inputHash: String, engine: EngineTag, fmModelID: String?) -> String {
        if let mid = fmModelID, !mid.isEmpty {
            return "tx:\(engine.rawValue):\(inputHash):fm@\(mid)"
        } else {
            return "tx:\(engine.rawValue):\(inputHash)"
        }
    }
}
