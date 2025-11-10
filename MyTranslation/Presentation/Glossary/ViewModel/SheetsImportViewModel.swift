import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SheetsImportViewModel {
    enum Step { case url, tabs, preview }

    struct Tab: Identifiable, Hashable {
        let id = UUID()
        let title: String
        var kind: Kind
        enum Kind { case term, pattern, marker }
    }

    let context: ModelContext
    private let adapter: SheetImportAdapter

    var step: Step = .url
    var spreadsheetURL: String = ""
    var availableTabs: [Tab] = []
    var selectedTermTabs: Set<UUID> = []
    var selectedPatternTabs: Set<UUID> = []
    var selectedMarkerTabs: Set<UUID> = []
    var dryRunReport: Glossary.SDModel.ImportDryRunReport? = nil
    var errorMessage: String?
    var isProcessing: Bool = false

    init(context: ModelContext, adapter: SheetImportAdapter = SheetImportAdapter()) {
        self.context = context
        self.adapter = adapter
    }

    func validateURL() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let tabs = try await adapter.fetchTabs(urlString: spreadsheetURL)
            availableTabs = tabs.map { Tab(title: $0.title, kind: .term) }
            step = .tabs
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPreview() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let selection = Selection(
                termTitles: selectedTermTabs.compactMap { id in availableTabs.first(where: { $0.id == id })?.title },
                patternTitles: selectedPatternTabs.compactMap { id in availableTabs.first(where: { $0.id == id })?.title },
                markerTitles: selectedMarkerTabs.compactMap { id in availableTabs.first(where: { $0.id == id })?.title }
            )
            dryRunReport = try await adapter.performDryRun(urlString: spreadsheetURL, selection: selection, context: context)
            step = .preview
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importSelection() async {
        guard let report = dryRunReport else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            try await adapter.importData(urlString: spreadsheetURL, report: report, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    struct Selection {
        let termTitles: [String]
        let patternTitles: [String]
        let markerTitles: [String]
    }
}

struct SheetImportAdapter {
    func fetchTabs(urlString: String) async throws -> [(title: String, id: Int)] {
        guard !urlString.isEmpty else { throw NSError(domain: "Sheets", code: 0, userInfo: [NSLocalizedDescriptionKey: "URL을 입력하세요."]) }
        // Stubbed list for offline previews
        return ["Terms", "Patterns", "Markers"].enumerated().map { (idx, title) in (title: title, id: idx) }
    }

    func performDryRun(urlString: String, selection: SheetsImportViewModel.Selection, context: ModelContext) async throws -> Glossary.SDModel.ImportDryRunReport {
        let bundle = Glossary.SDModel.ImportDryRunReport(
            terms: .init(newCount: selection.termTitles.count, updateCount: 0, deleteCount: 0),
            patterns: .init(newCount: selection.patternTitles.count, updateCount: 0, deleteCount: 0),
            markers: .init(newCount: selection.markerTitles.count, updateCount: 0, deleteCount: 0),
            warnings: [],
            termKeyCollisions: [],
            patternKeyCollisions: [],
            markerKeyCollisions: []
        )
        return bundle
    }

    func importData(urlString: String, report: Glossary.SDModel.ImportDryRunReport, context: ModelContext) async throws {
        enum ImportError: LocalizedError {
            case invalidURL
            case spreadsheetIdMissing
            case missingAPIKey
            case noRecognizedSheets

            var errorDescription: String? {
                switch self {
                case .invalidURL:
                    return "유효한 Google 스프레드시트 URL이 아닙니다."
                case .spreadsheetIdMissing:
                    return "스프레드시트 ID를 추출할 수 없습니다."
                case .missingAPIKey:
                    return "Google API 키가 설정되지 않았습니다."
                case .noRecognizedSheets:
                    return "가져올 수 있는 시트 구성을 찾지 못했습니다."
                }
            }
        }

        struct SheetClient {
            func extractSpreadsheetID(from urlString: String) throws -> String {
                guard let url = URL(string: urlString) else { throw ImportError.invalidURL }
                if let id = url.pathComponents.drop { $0 != "d" }.dropFirst().first, !id.isEmpty {
                    return id
                }
                // fallback: 정규식 탐색
                let pattern = #"/spreadsheets/d/([a-zA-Z0-9-_]+)"#
                if let range = url.absoluteString.range(of: pattern, options: .regularExpression) {
                    let match = url.absoluteString[range]
                    if let idRange = match.range(of: "([a-zA-Z0-9-_]+)", options: .regularExpression) {
                        let id = match[idRange]
                        if !id.isEmpty { return String(id) }
                    }
                }
                throw ImportError.spreadsheetIdMissing
            }

            func fetchTabs(spreadsheetId: String) async throws -> [(title: String, id: Int)] {
                guard !APIKeys.google.isEmpty else { throw ImportError.missingAPIKey }
                let fields = "sheets.properties(title,sheetId)"
                guard let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)?fields=\(fields)&key=\(APIKeys.google)") else {
                    throw ImportError.invalidURL
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let metadata = try JSONDecoder().decode(Glossary.Sheet.SheetsMetadata.self, from: data)
                return metadata.sheets.map { sheet in (sheet.properties.title, sheet.properties.sheetId) }
            }

            func fetchRows(spreadsheetId: String, sheetTitle: String) async throws -> [[String]] {
                guard !APIKeys.google.isEmpty else { throw ImportError.missingAPIKey }
                let encoded = sheetTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sheetTitle
                guard let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetId)/values/\(encoded)?majorDimension=ROWS&key=\(APIKeys.google)") else {
                    throw ImportError.invalidURL
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(Glossary.Sheet.ValuesResponse.self, from: data)
                return response.values ?? []
            }
        }

        struct HeaderMap<Column: Hashable> {
            let index: [Column: Int]
            init?(header: [String], mapping: [String: Column]) {
                var table: [Column: Int] = [:]
                for (offset, value) in header.enumerated() {
                    let key = HeaderMap.normalize(value)
                    if let column = mapping[key], table[column] == nil {
                        table[column] = offset
                    }
                }
                guard !table.isEmpty else { return nil }
                index = table
            }

            static func normalize(_ header: String) -> String {
                let trimmed = header
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "-", with: "_")
                var snake = ""
                for ch in trimmed {
                    if ch.isUppercase {
                        if let last = snake.last, last != '_' {
                            snake += "_"
                        }
                        snake.append(contentsOf: ch.lowercased())
                    } else {
                        snake.append(ch)
                    }
                }
                let collapsed = snake.replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
                return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_")).lowercased()
            }

            func value(in row: [String], for column: Column) -> String? {
                guard let idx = index[column], idx < row.count else { return nil }
                let value = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }

        enum TermColumn { case sourcesOK, sourcesNG, target, variants, tags, components, isAppellation, preMask }
        enum PatternColumn { case name, displayName, roles, grouping, groupLabel, sourceJoiners, sourceTemplates, targetTemplates, left, right, skipSame, isAppellation, preMask, defaultProhibit, defaultIsAppellation, defaultPreMask, needPairCheck }
        enum MarkerColumn { case source, target, variants, position, prohibit }

        func parseBool(_ raw: String?) -> Bool {
            guard let raw else { return false }
            let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "y", "yes", "true", "t", "on"].contains(lowered)
        }

        _ = report

        let client = SheetClient()
        let spreadsheetId = try client.extractSpreadsheetID(from: urlString)
        let tabs = try await client.fetchTabs(spreadsheetId: spreadsheetId)

        var termSheets: [String: [TermRow]] = [:]
        var patternRows: [PatternRow] = []
        var markerRows: [AppellationRow] = []

        let termMapping: [String: TermColumn] = [
            "sources_ok": .sourcesOK,
            "source_ok": .sourcesOK,
            "sources": .sourcesOK,
            "sourcesng": .sourcesNG,
            "sources_ng": .sourcesNG,
            "source_ng": .sourcesNG,
            "sources_prohibit": .sourcesNG,
            "sources_ng_text": .sourcesNG,
            "target": .target,
            "target_text": .target,
            "variants": .variants,
            "variant": .variants,
            "tags": .tags,
            "components": .components,
            "component": .components,
            "is_appellation": .isAppellation,
            "appellation": .isAppellation,
            "pre_mask": .preMask,
            "premask": .preMask
        ]

        let patternMapping: [String: PatternColumn] = [
            "name": .name,
            "pattern": .name,
            "display_name": .displayName,
            "displayname": .displayName,
            "roles": .roles,
            "grouping": .grouping,
            "group_label": .groupLabel,
            "grouplabel": .groupLabel,
            "source_joiners": .sourceJoiners,
            "source_templates": .sourceTemplates,
            "target_templates": .targetTemplates,
            "left": .left,
            "right": .right,
            "skip_same": .skipSame,
            "skip_pairs_if_same_term": .skipSame,
            "is_appellation": .isAppellation,
            "pre_mask": .preMask,
            "default_prohibit": .defaultProhibit,
            "default_is_appellation": .defaultIsAppellation,
            "default_premask": .defaultPreMask,
            "default_premask_flag": .defaultPreMask,
            "default_pre_mask": .defaultPreMask,
            "need_pair_check": .needPairCheck
        ]

        let markerMapping: [String: MarkerColumn] = [
            "source": .source,
            "target": .target,
            "variants": .variants,
            "position": .position,
            "prohibit": .prohibit,
            "prohibit_standalone": .prohibit
        ]

        for tab in tabs {
            let rows = try await client.fetchRows(spreadsheetId: spreadsheetId, sheetTitle: tab.title)
            guard !rows.isEmpty else { continue }
            let headerRow = rows[0]
            if let header = HeaderMap(header: headerRow, mapping: termMapping) {
                let entries = rows.dropFirst().compactMap { row -> TermRow? in
                    let target = header.value(in: row, for: .target) ?? ""
                    let sourcesOK = header.value(in: row, for: .sourcesOK) ?? ""
                    let sourcesNG = header.value(in: row, for: .sourcesNG) ?? ""
                    if target.isEmpty && sourcesOK.isEmpty && sourcesNG.isEmpty { return nil }
                    return TermRow(
                        sourcesOK: sourcesOK,
                        sourcesProhibit: sourcesNG,
                        target: target,
                        variants: header.value(in: row, for: .variants) ?? "",
                        tags: header.value(in: row, for: .tags) ?? "",
                        components: header.value(in: row, for: .components) ?? "",
                        isAppellation: parseBool(header.value(in: row, for: .isAppellation)),
                        preMask: parseBool(header.value(in: row, for: .preMask))
                    )
                }
                if !entries.isEmpty { termSheets[tab.title] = entries }
                continue
            }

            if let header = HeaderMap<PatternColumn>(header: headerRow, mapping: patternMapping) {
                let entries = rows.dropFirst().compactMap { row -> PatternRow? in
                    guard let name = header.value(in: row, for: .name), !name.isEmpty else { return nil }
                    return PatternRow(
                        name: name,
                        displayName: header.value(in: row, for: .displayName) ?? "",
                        roles: header.value(in: row, for: .roles) ?? "",
                        grouping: header.value(in: row, for: .grouping) ?? "",
                        groupLabel: header.value(in: row, for: .groupLabel) ?? "",
                        sourceJoiners: header.value(in: row, for: .sourceJoiners) ?? "",
                        sourceTemplates: header.value(in: row, for: .sourceTemplates) ?? "",
                        targetTemplates: header.value(in: row, for: .targetTemplates) ?? "",
                        left: header.value(in: row, for: .left) ?? "",
                        right: header.value(in: row, for: .right) ?? "",
                        skipSame: parseBool(header.value(in: row, for: .skipSame)),
                        isAppellation: parseBool(header.value(in: row, for: .isAppellation)),
                        preMask: parseBool(header.value(in: row, for: .preMask)),
                        defProhibit: parseBool(header.value(in: row, for: .defaultProhibit)),
                        defIsAppellation: parseBool(header.value(in: row, for: .defaultIsAppellation)),
                        defPreMask: parseBool(header.value(in: row, for: .defaultPreMask)),
                        needPairCheck: parseBool(header.value(in: row, for: .needPairCheck))
                    )
                }
                patternRows.append(contentsOf: entries)
                continue
            }

            if let header = HeaderMap<MarkerColumn>(header: headerRow, mapping: markerMapping) {
                let entries = rows.dropFirst().compactMap { row -> AppellationRow? in
                    guard let source = header.value(in: row, for: .source), !source.isEmpty else { return nil }
                    return AppellationRow(
                        source: source,
                        target: header.value(in: row, for: .target) ?? "",
                        variants: header.value(in: row, for: .variants) ?? "",
                        position: header.value(in: row, for: .position) ?? "",
                        prohibit: parseBool(header.value(in: row, for: .prohibit))
                    )
                }
                markerRows.append(contentsOf: entries)
                continue
            }
        }

        guard !termSheets.isEmpty || !patternRows.isEmpty || !markerRows.isEmpty else {
            throw ImportError.noRecognizedSheets
        }

        let bundle = try buildGlossaryJSON(termsBySheet: termSheets, patterns: patternRows, markers: markerRows)
        let upserter = Glossary.SDModel.GlossaryUpserter(context: context, merge: .overwrite)
        let result = try upserter.apply(bundle: bundle)
        Glossary.SDModel.ToastHub.shared.show(
            "용어 +\(result.terms.newCount + result.terms.updateCount), 패턴 +\(result.patterns.newCount + result.patterns.updateCount), 호칭 +\(result.markers.newCount + result.markers.updateCount) 가져왔습니다."
        )
    }
}
