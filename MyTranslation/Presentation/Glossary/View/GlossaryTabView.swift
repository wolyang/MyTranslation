// File: GlossaryTabView.swift
import SwiftData
import SwiftUI

struct GlossaryTabView: View {
    let modelContext: ModelContext

    @State private var homeViewModel: GlossaryHomeViewModel
    @Binding var selection: Tab
    @Binding var activeSheet: ActiveSheet?

    init(
        modelContext: ModelContext,
        viewModel: GlossaryHomeViewModel,
        selection: Binding<Tab>,
        activeSheet: Binding<ActiveSheet?>
    ) {
        self.modelContext = modelContext
        self._homeViewModel = State(initialValue: viewModel)
        self._selection = selection
        self._activeSheet = activeSheet
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("섹션", selection: $selection) {
                Text("용어").tag(Tab.terms)
                Text("패턴").tag(Tab.patterns)
                Text("호칭").tag(Tab.appellations)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()

            Group {
                switch selection {
                case .terms:
                    NavigationStack {
                        GlossaryHomeView(
                            viewModel: homeViewModel,
                            onCreateTerm: { pattern in presentTermEditor(patternID: pattern?.id) },
                            onEditTerm: { row in presentTermEditor(termID: row.id) },
                            onOpenImport: { activeSheet = ActiveSheet.importSheet() }
                        )
                    }
                case .patterns:
                    NavigationStack {
                        PatternListView(
                            viewModel: homeViewModel,
                            onCreatePattern: { presentPatternEditor(nil) },
                            onEditPattern: { presentPatternEditor($0.id) }
                        )
                    }
                case .appellations:
                    NavigationStack {
                        AppellationListView(viewModel: homeViewModel)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    enum Tab: Hashable {
        case terms
        case patterns
        case appellations
    }

    enum ActiveSheet: Identifiable {
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
