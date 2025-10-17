//  GlossaryJSON.swift
import Foundation
import UniformTypeIdentifiers
import SwiftUI

// 내보내기/가져오기 JSON 포맷
struct GlossaryJSON: Codable {
    struct Item: Codable {
        let source: String
        let target: String
        let strict: Bool?
        let variants: [String]?
        let notes: String?
        let category: String?
    }
    let meta: Meta
    let terms: [Item]

    struct Meta: Codable { let version: Int; let lang: String }
}

// FileExporter 용 문서 래퍼
struct GlossaryJSONDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.json] }
    
    var payload: GlossaryJSON

    init(terms: [Term]) {
        self.payload = GlossaryJSON(
            meta: .init(version: 2, lang: "zh->ko"),
            terms: terms.map {
                .init(
                    source: $0.source,
                    target: $0.target,
                    strict: $0.strict,
                    variants: $0.variants,
                    notes: $0.notes,
                    category: $0.category
                )
            }
        )
    }

    init(configuration: ReadConfiguration) throws {
        // 가져오기는 GlossaryTabView에서 처리
        self.payload = GlossaryJSON(meta: .init(version: 2, lang: "zh->ko"), terms: [])
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(payload)
        return .init(regularFileWithContents: data)
    }
}
