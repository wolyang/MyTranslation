// File: GlossaryTabView.swift
import SwiftData
import SwiftUI

struct GlossaryTabView: View {
    private let modelContext: ModelContext

    @State private var homeViewModel: GlossaryHomeViewModel
    @State private var activeSheet: ActiveSheet? = nil
    @State private var selection: Tab = .terms

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        _homeViewModel = State(initialValue: GlossaryHomeViewModel(context: modelContext))
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                GlossaryHomeView(
                    viewModel: homeViewModel,
                    onCreateTerm: { pattern in presentTermEditor(patternID: pattern?.id) },
                    onEditTerm: { row in presentTermEditor(termID: row.id) },
                    onOpenImport: { activeSheet = ActiveSheet.importSheet() }
                )
                .navigationTitle("용어")
            }
            .tabItem { Label("용어", systemImage: "list.bullet") }
            .tag(Tab.terms)

            NavigationStack {
                PatternListView(
                    viewModel: homeViewModel,
                    onCreatePattern: { presentPatternEditor(nil) },
                    onEditPattern: { presentPatternEditor($0.id) }
                )
            }
            .tabItem { Label("패턴", systemImage: "square.grid.2x2") }
            .tag(Tab.patterns)

            NavigationStack {
                AppellationListView(viewModel: homeViewModel)
            }
            .tabItem { Label("호칭", systemImage: "text.quote") }
            .tag(Tab.appellations)
        }
        .sheet(item: $activeSheet, onDismiss: { Task { await homeViewModel.reloadAll() } }) { sheet in
            switch sheet {
            case .term(let viewModel, _):
                TermEditorView(viewModel: viewModel)
            case .pattern(let viewModel, _):
                PatternEditorView(viewModel: viewModel)
            case .importSheet(_):
                SheetsImportCoordinatorView(modelContext: modelContext)
            }
        }
    }

    private func presentTermEditor(termID: PersistentIdentifier? = nil, patternID: String? = nil) {
        do {
            let viewModel = try TermEditorViewModel(context: modelContext, termID: termID, patternID: patternID)
            activeSheet = ActiveSheet.term(viewModel)
        } catch {
            print("TermEditor init error: \(error)")
        }
    }

    private func presentTermEditor(patternID: String?) {
        presentTermEditor(termID: nil, patternID: patternID)
    }

    private func presentPatternEditor(_ id: String?) {
        do {
            let viewModel = try PatternEditorViewModel(context: modelContext, patternID: id)
            activeSheet = ActiveSheet.pattern(viewModel)
        } catch {
            print("PatternEditor init error: \(error)")
        }
    }

    private enum Tab: Hashable {
        case terms
        case patterns
        case appellations
    }

    private enum ActiveSheet: Identifiable {
        case term(TermEditorViewModel, UUID)
        case pattern(PatternEditorViewModel, UUID)
        case importSheet(UUID)

        static func term(_ viewModel: TermEditorViewModel) -> ActiveSheet { .term(viewModel, UUID()) }
        static func pattern(_ viewModel: PatternEditorViewModel) -> ActiveSheet { .pattern(viewModel, UUID()) }
        static func importSheet() -> ActiveSheet { .importSheet(UUID()) }

        var id: UUID {
            switch self {
            case .term(_, let id): return id
            case .pattern(_, let id): return id
            case .importSheet(let id): return id
            }
        }
    }
}
