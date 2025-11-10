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
        // Stub: in production this would call GlossarySheetImport + GlossarySDUpserter
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
