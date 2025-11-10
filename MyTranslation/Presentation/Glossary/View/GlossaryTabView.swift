// File: GlossaryTabView.swift
import SwiftData
import SwiftUI

struct GlossaryTabView: View {
    private let modelContext: ModelContext

    @State private var homeViewModel: GlossaryHomeViewModel
    @State private var termEditorViewModel: TermEditorViewModel? = nil
    @State private var showTermEditor: Bool = false
    @State private var patternEditorViewModel: PatternEditorViewModel? = nil
    @State private var showPatternEditor: Bool = false
    @State private var showImportSheet: Bool = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        _homeViewModel = State(initialValue: GlossaryHomeViewModel(context: modelContext))
    }

    var body: some View {
        NavigationStack {
            GlossaryHomeView(
                viewModel: homeViewModel,
                onCreateTerm: { pattern in presentTermEditor(patternID: pattern?.id) },
                onEditTerm: { row in presentTermEditor(termID: row.id) },
                onOpenPatternEditor: { pattern in presentPatternEditor(pattern?.id) },
                onOpenImport: { showImportSheet = true }
            )
        }
        .sheet(isPresented: $showTermEditor, onDismiss: { Task { await homeViewModel.reloadAll() } }) {
            if let vm = termEditorViewModel {
                TermEditorView(viewModel: vm)
            }
        }
        .sheet(isPresented: $showPatternEditor, onDismiss: { Task { await homeViewModel.reloadAll() } }) {
            if let vm = patternEditorViewModel {
                PatternEditorView(viewModel: vm)
            }
        }
        .sheet(isPresented: $showImportSheet, onDismiss: { Task { await homeViewModel.reloadAll() } }) {
            SheetsImportCoordinatorView(modelContext: modelContext)
        }
    }

    private func presentTermEditor(termID: PersistentIdentifier? = nil, patternID: String? = nil) {
        do {
            termEditorViewModel = try TermEditorViewModel(context: modelContext, termID: termID, patternID: patternID)
            showTermEditor = true
        } catch {
            print("TermEditor init error: \(error)")
        }
    }

    private func presentTermEditor(patternID: String?) {
        presentTermEditor(termID: nil, patternID: patternID)
    }

    private func presentPatternEditor(_ id: String?) {
        do {
            patternEditorViewModel = try PatternEditorViewModel(context: modelContext, patternID: id)
            showPatternEditor = true
        } catch {
            print("PatternEditor init error: \(error)")
        }
    }
}
