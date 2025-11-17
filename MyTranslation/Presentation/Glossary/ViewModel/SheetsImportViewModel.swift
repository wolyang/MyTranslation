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
        enum Kind: String, Codable { case term, pattern, marker }
    }

    let context: ModelContext
    private let adapter: SheetImportAdapter
    private let defaults: UserDefaults
    private var savedTabKinds: [String: Tab.Kind]

    var step: Step = .url
    var spreadsheetURL: String
    var availableTabs: [Tab] = []
    var selectedTermTabs: Set<UUID> = []
    var selectedPatternTabs: Set<UUID> = []
    var selectedMarkerTabs: Set<UUID> = []
    var dryRunReport: Glossary.SDModel.ImportDryRunReport? = nil
    var errorMessage: String?
    var isProcessing: Bool = false
    var applyDeletions: Bool = false

    init(
        context: ModelContext,
        adapter: SheetImportAdapter = SheetImportAdapter(),
        defaults: UserDefaults = .standard
    ) {
        self.context = context
        self.adapter = adapter
        self.defaults = defaults
        self.savedTabKinds = Self.loadSavedTabKinds(from: defaults)
        self.spreadsheetURL = defaults.string(forKey: DefaultsKey.spreadsheetURL) ?? ""
    }

    func validateURL() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let tabs = try await adapter.fetchTabs(urlString: spreadsheetURL)
            availableTabs = tabs.map { Tab(title: $0.title) }
            restoreSelectionsFromDefaults()
            defaults.set(spreadsheetURL, forKey: DefaultsKey.spreadsheetURL)
            step = .tabs
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPreview() async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let selection = currentSelection()
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
            let selection = currentSelection()
            try await adapter.importData(
                urlString: spreadsheetURL,
                selection: selection,
                report: report,
                context: context
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    struct Selection {
        let termTitles: [String]
        let patternTitles: [String]
        let markerTitles: [String]
        let applyDeletions: Bool
    }

    private func currentSelection() -> Selection {
        Selection(
            termTitles: titles(for: selectedTermTabs),
            patternTitles: titles(for: selectedPatternTabs),
            markerTitles: titles(for: selectedMarkerTabs),
            applyDeletions: applyDeletions
        )
    }

    private func titles(for ids: Set<UUID>) -> [String] {
        availableTabs.compactMap { ids.contains($0.id) ? $0.title : nil }
    }

    private func title(for id: UUID) -> String? {
        availableTabs.first(where: { $0.id == id })?.title
    }

    private func restoreSelectionsFromDefaults() {
        selectedTermTabs.removeAll()
        selectedPatternTabs.removeAll()
        selectedMarkerTabs.removeAll()
        for tab in availableTabs {
            guard let kind = savedTabKinds[tab.title] else { continue }
            switch kind {
            case .term: selectedTermTabs.insert(tab.id)
            case .pattern: selectedPatternTabs.insert(tab.id)
            case .marker: selectedMarkerTabs.insert(tab.id)
            }
        }
    }

    private func persistTabKinds() {
        let raw = savedTabKinds.mapValues { $0.rawValue }
        defaults.set(raw, forKey: DefaultsKey.tabKinds)
    }

    func setSelection(kind: Tab.Kind?, forTab id: UUID) {
        updateSelection(for: id, to: kind)
    }

    private func updateSelection(for id: UUID, to newValue: Tab.Kind?) {
        selectedTermTabs.remove(id)
        selectedPatternTabs.remove(id)
        selectedMarkerTabs.remove(id)
        if let kind = newValue {
            switch kind {
            case .term: selectedTermTabs.insert(id)
            case .pattern: selectedPatternTabs.insert(id)
            case .marker: selectedMarkerTabs.insert(id)
            }
        }
        guard let title = title(for: id) else { return }
        if let kind = newValue {
            savedTabKinds[title] = kind
        } else {
            savedTabKinds.removeValue(forKey: title)
        }
        persistTabKinds()
    }

    private static func loadSavedTabKinds(from defaults: UserDefaults) -> [String: Tab.Kind] {
        guard let raw = defaults.dictionary(forKey: DefaultsKey.tabKinds) as? [String: String] else { return [:] }
        var map: [String: Tab.Kind] = [:]
        for (title, value) in raw {
            if let kind = Tab.Kind(rawValue: value) {
                map[title] = kind
            }
        }
        return map
    }

    private enum DefaultsKey {
        static let spreadsheetURL = "SheetsImport.lastSpreadsheetURL"
        static let tabKinds = "SheetsImport.tabKinds"
    }
}

struct SheetImportAdapter {
    func fetchTabs(urlString: String) async throws -> [(title: String, id: Int)] {
        guard !urlString.isEmpty else { throw NSError(domain: "Sheets", code: 0, userInfo: [NSLocalizedDescriptionKey: "URL을 입력하세요."]) }
        guard let spreadsheetId = extractSpreadsheetId(from: urlString) else {
            throw NSError(domain: "Sheets", code: 0, userInfo: [NSLocalizedDescriptionKey: "올바른 URL을 입력하세요."])
        }
        return try await Glossary.Sheet.fetchSheetTabs(spreadsheetId: spreadsheetId)
    }

    func extractSpreadsheetId(from urlString: String) -> String? {
        guard let range1 = urlString.range(of: "/d/"),
              let range2 = urlString.range(of: "/edit", range: range1.upperBound..<urlString.endIndex) else {
            return nil
        }
        return String(urlString[range1.upperBound..<range2.lowerBound])
    }

    func performDryRun(urlString: String, selection: SheetsImportViewModel.Selection, context: ModelContext) async throws -> Glossary.SDModel.ImportDryRunReport {
        let bundle = try await makeBundle(urlString: urlString, selection: selection)
        let upserter = await Glossary.SDModel.GlossaryUpserter(
            context: context,
            merge: .overwrite,
            sync: makeSyncPolicy(for: selection)
        )
        return try await upserter.dryRun(bundle: bundle)
    }

    func importData(
        urlString: String,
        selection: SheetsImportViewModel.Selection,
        report: Glossary.SDModel.ImportDryRunReport,
        context: ModelContext
    ) async throws {
        _ = report

        let bundle = try await makeBundle(urlString: urlString, selection: selection)
        let upserter = await Glossary.SDModel.GlossaryUpserter(
            context: context,
            merge: .overwrite,
            sync: makeSyncPolicy(for: selection)
        )
        let result = try await upserter.apply(bundle: bundle)
        await Glossary.SDModel.ToastHub.shared.show(
            "용어 +\(result.terms.newCount + result.terms.updateCount), 패턴 +\(result.patterns.newCount + result.patterns.updateCount), 호칭 +\(result.markers.newCount + result.markers.updateCount) 가져왔습니다."
        )
    }

    private func makeSyncPolicy(for selection: SheetsImportViewModel.Selection) -> Glossary.SDModel.ImportSyncPolicy {
        var policy = Glossary.SDModel.ImportSyncPolicy()
        if selection.applyDeletions {
            policy.removeMissingTerms = !selection.termTitles.isEmpty
            policy.removeMissingPatterns = !selection.patternTitles.isEmpty
            policy.removeMissingMarkers = !selection.markerTitles.isEmpty
        } else {
            policy.removeMissingTerms = false
            policy.removeMissingPatterns = false
            policy.removeMissingMarkers = false
        }
        return policy
    }

    private func makeBundle(urlString: String, selection: SheetsImportViewModel.Selection) async throws -> JSBundle {
        guard !selection.termTitles.isEmpty || !selection.patternTitles.isEmpty || !selection.markerTitles.isEmpty else {
            throw ImportError.emptySelection
        }

        let spreadsheetId = try resolveSpreadsheetId(urlString: urlString)

        var termSheets: [String: [TermRow]] = [:]
        var patternRows: [PatternRow] = []
        var markerRows: [AppellationRow] = []

        let termMapping: [String: TermColumn] = [
            "key": .key,
            "id": .key,
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

        for title in selection.termTitles {
            let rows = try await Glossary.Sheet.fetchRows(spreadsheetId: spreadsheetId, sheetTitle: title)
            guard !rows.isEmpty else { continue }
            let headerRow = rows[0]
            guard let header = HeaderMap(header: headerRow, mapping: termMapping) else {
                throw ImportError.malformedSheet(title)
            }
            let entries = rows.dropFirst().compactMap { row -> TermRow? in
                let key = header.value(in: row, for: .key) ?? ""
                let target = header.value(in: row, for: .target) ?? ""
                let sourcesOK = header.value(in: row, for: .sourcesOK) ?? ""
                let sourcesNG = header.value(in: row, for: .sourcesNG) ?? ""
                if target.isEmpty && sourcesOK.isEmpty && sourcesNG.isEmpty { return nil }
                return TermRow(
                    key: key,
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
            if !entries.isEmpty { termSheets[title] = entries }
        }

        for title in selection.patternTitles {
            let rows = try await Glossary.Sheet.fetchRows(spreadsheetId: spreadsheetId, sheetTitle: title)
            guard !rows.isEmpty else { continue }
            let headerRow = rows[0]
            guard let header = HeaderMap<PatternColumn>(header: headerRow, mapping: patternMapping) else {
                throw ImportError.malformedSheet(title)
            }
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
        }

        for title in selection.markerTitles {
            let rows = try await Glossary.Sheet.fetchRows(spreadsheetId: spreadsheetId, sheetTitle: title)
            guard !rows.isEmpty else { continue }
            let headerRow = rows[0]
            guard let header = HeaderMap<MarkerColumn>(header: headerRow, mapping: markerMapping) else {
                throw ImportError.malformedSheet(title)
            }
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
        }

        guard !termSheets.isEmpty || !patternRows.isEmpty || !markerRows.isEmpty else {
            throw ImportError.noRecognizedSheets
        }

        return try buildGlossaryJSON(termsBySheet: termSheets, patterns: patternRows, markers: markerRows)
    }

    private func resolveSpreadsheetId(urlString: String) throws -> String {
        guard !APIKeys.google.isEmpty else { throw ImportError.missingAPIKey }

        guard !urlString.isEmpty else {
            throw ImportError.invalidURL
        }

        guard let spreadsheetId = extractSpreadsheetId(from: urlString) else {
            throw ImportError.spreadsheetIdMissing
        }
        return spreadsheetId
    }

    private func parseBool(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "y", "yes", "true", "t", "on"].contains(lowered)
    }
}

extension SheetImportAdapter {
    enum ImportError: LocalizedError {
        case invalidURL
        case spreadsheetIdMissing
        case missingAPIKey
        case noRecognizedSheets
        case emptySelection
        case malformedSheet(String)

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
            case .emptySelection:
                return "가져올 시트를 선택하세요."
            case let .malformedSheet(title):
                return "\(title) 시트의 헤더 구성을 해석할 수 없습니다."
            }
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
                    if let last = snake.last, last != "_" {
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

    enum TermColumn { case key, sourcesOK, sourcesNG, target, variants, tags, components, isAppellation, preMask }
    enum PatternColumn { case name, displayName, roles, grouping, groupLabel, sourceJoiners, sourceTemplates, targetTemplates, left, right, skipSame, isAppellation, preMask, defaultProhibit, defaultIsAppellation, defaultPreMask, needPairCheck }
    enum MarkerColumn { case source, target, variants, position, prohibit }
}
