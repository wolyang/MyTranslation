//
//  EngineTag.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

public enum EngineTag: String, Codable, CaseIterable {
    case afm
    case deepl
    case google
    case afmMask
    case unknown

    public static var allCases: [EngineTag] { [.afm, .google, .deepl] }

    public var displayName: String {
        switch self {
        case .afm: return "AFM"
        case .google: return "Google"
        case .deepl: return "DeepL"
        case .afmMask: return "AFM Mask"
        case .unknown: return "Unknown"
        }
    }

    public var shortLabel: String {
        switch self {
        case .afm: return "AFM"
        case .google: return "GGL"
        case .deepl: return "DPL"
        case .afmMask: return "AFM"
        case .unknown: return "???"
        }
    }
}
