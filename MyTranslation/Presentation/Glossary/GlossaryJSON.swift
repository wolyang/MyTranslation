//  GlossaryJSON.swift
import Foundation
import UniformTypeIdentifiers
import SwiftUI

// 내보내기/가져오기 JSON 포맷
struct GlossaryJSON: Codable {
    struct Meta: Codable { let version: Int; let lang: String
        public init(version: Int = 3, lang: String = "zh->ko") {
        self.version = version
        self.lang = lang
        }
    }
    struct NameVariant: Codable {
        let source: [String]
        let target: String?
    }

    struct PeopleName: Codable {
        let family: NameVariant
        let given:  NameVariant
    }

    struct PersonItem: Codable {
        let person_id: String
        let name: PeopleName
        let aliases: [NameVariant]
    }

    struct TermItem: Codable {
        let source: String
        let target: String
        let category: String
    }

    let meta: Meta
    let terms: [TermItem]
    let people: [PersonItem]
    
    public init(terms: [TermItem], people: [PersonItem] = [], meta: Meta = .init()) {
    self.meta = meta
    self.terms = terms
    self.people = people
    }
}

// FileExporter 용 문서 래퍼
public struct GlossaryJSONDocument: FileDocument {
public static var readableContentTypes: [UTType] { [.json] }
public static var writableContentTypes: [UTType] { [.json] }


var payload: GlossaryJSON


init(payload: GlossaryJSON) {
self.payload = payload
}


init(terms: [Term], people: [Person] = []) {
let termsItems = terms.map { GlossaryJSON.TermItem(source: $0.source, target: $0.target, category: $0.category) }
    let personItems = people.map {
        GlossaryJSON.PersonItem(person_id: $0.personId, name: .init(family: .init(source: $0.familySources, target: $0.familyTarget), given: .init(source: $0.givenSources, target: $0.givenTarget)), aliases: $0.aliases.map({ a in
                .init(source: a.sources, target: a.target)
        }))
    }
self.payload = GlossaryJSON(terms: termsItems, people: personItems)
}


// FileDocument
public init(configuration: ReadConfiguration) throws {
guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
self.payload = try JSONDecoder().decode(GlossaryJSON.self, from: data)
}


public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
let data = try JSONEncoder().encode(payload)
return .init(regularFileWithContents: data)
}
}
