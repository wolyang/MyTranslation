//
//  GlossarySheetImport.swift
//  MyTranslation
//
//  Created by sailor.m on 11/10/25.
//

import Foundation

extension Glossary {
    enum Sheet { }
}

extension Glossary.Sheet {
    struct SheetsMetadata: Decodable {
        struct Sheet: Decodable {
            struct Properties: Decodable { let title: String; let sheetId: Int }
            let properties: Properties
        }
        let sheets: [Sheet]
    }

    struct ValuesResponse: Decodable { let values: [[String]]? }

    // 파싱된 Term 데이터 (upsert 전 intermediate 형태)
    struct ParsedTerm {
        let key: String
        let target: String
        let variants: [String]
        let sources: [SourceData]
        let isAppellation: Bool
        let preMask: Bool
        let activatedByKeys: [String]  // 신규: activated_by 컬럼에서 파싱된 Term 키들
        let deactivatedIn: [String]    // 신규: deactivated_in 컬럼

        struct SourceData {
            let text: String
            let prohibitStandalone: Bool
        }
    }
    
    static func fetchSheetTabs(spreadsheetId: String) async throws -> [(title: String, id: Int)] {
        let fields = "sheets.properties(title,sheetId)"
        let urlStr = "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)?fields=\(fields)&key=\(APIKeys.google)"
        let (data, _) = try await URLSession.shared.data(from: URL(string: urlStr)!)
        let meta = try JSONDecoder().decode(SheetsMetadata.self, from: data)
        return meta.sheets.map { ($0.properties.title, $0.properties.sheetId) }
    }
    
    static func fetchRows(spreadsheetId: String, sheetTitle: String) async throws -> [[String]] {
        // 전체 시트를 행 기준으로 조회: majorDimension=ROWS
        let range = sheetTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sheetTitle
        let urlStr = "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(range)?majorDimension=ROWS&key=\(APIKeys.google)"
        let (data, _) = try await URLSession.shared.data(from: URL(string: urlStr)!)
        let res = try JSONDecoder().decode(ValuesResponse.self, from: data)
        return res.values ?? []
    }
    
}
