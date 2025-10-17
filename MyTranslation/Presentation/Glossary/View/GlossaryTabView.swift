// File: GlossaryTabView.swift
import SwiftUI
import SwiftData

struct GlossaryTabView: View {
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        GlossaryContentView(modelContext: modelContext)
    }
}

private struct GlossaryContentView: View {
    let modelContext: ModelContext
    @StateObject private var vm: GlossaryViewModel

    @State private var isExporting = false
    @State private var isImporting = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        _vm = StateObject(wrappedValue: GlossaryViewModel(modelContext: modelContext))
    }

    var body: some View {
        VStack {
            HStack {
                TextField("검색(중/한)", text: Binding(
                    get: { vm.query },
                    set: { vm.query = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onReceive(
                    vm.$query
                        .removeDuplicates()
                        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                ) { _ in
                    vm.refresh()
                }

                Picker("분류", selection: Binding(
                    get: { vm.selectedCategory },
                    set: { vm.selectedCategory = $0 }
                  )) {
                      Text("전체").tag("전체")
                      ForEach(GlossaryConstants.categories, id: \.self) { Text($0).tag($0) }
                  }
                .onChange(of: vm.selectedCategory) { _, _ in vm.refresh() }
                
                Button("추가") { vm.addNew() }

                Menu("가져오기/내보내기") {
                    Button("JSON 가져오기…") { isImporting = true }
                    Button("JSON 내보내기…") { isExporting = true }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                ForEach(vm.terms) { term in
                    Button {
                        vm.edit(term)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(term.source).font(.headline)
                                if term.strict { Text("strict").font(.caption).foregroundStyle(.secondary) }
                                if let cat = term.category, !cat.isEmpty {
                                    Text(cat).font(.caption2).padding(4).background(.thinMaterial).cornerRadius(6)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(term.target).foregroundStyle(.secondary)
                                if !term.variants.isEmpty {
                                    Text(term.variants.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let notes = term.notes, !notes.isEmpty {
                                Text(notes).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { vm.delete(at: $0) }
            }
        }
        .onAppear { vm.refresh() }

        // ✅ VM의 @Published Bool에 직접 바인딩
        .sheet(isPresented: $vm.isPresentingEditor) {
            TermEditorSheet(
                term: vm.editingTerm,               // 편집이면 대상, 신규면 nil
                onSave: { vm.upsert($0) },
                onCancel: { vm.isPresentingEditor = false }
            )
            .presentationDetents([.medium, .large])
        }

        // Export / Import
        .fileExporter(isPresented: $isExporting,
                      document: GlossaryJSONDocument(terms: vm.terms),
                      contentType: .json,
                      defaultFilename: "terms.json") { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { vm.importJSON(from: url) }
        }
    }
}
