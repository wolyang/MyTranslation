// File: GlossaryTabView.swift
import SwiftData
import SwiftUI

struct GlossaryTabView: View {
    @StateObject private var vm: GlossaryViewModel

    @State private var termSheetTarget: TermSheetTarget? = nil

    @State private var showImporter: Bool = false
    @State private var showExporter: Bool = false

    // People UI
    @State private var personSheetTarget: PersonSheetTarget? = nil

    // Segment
    enum Segment: String, CaseIterable, Identifiable { case terms = "용어"; case people = "인물"; var id: String { rawValue } }
    @State private var segment: Segment = .terms

    init(modelContext: ModelContext) {
        _vm = StateObject(wrappedValue: GlossaryViewModel(modelContext: modelContext))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    TextField("검색(원문/번역/카테고리/인물)", text: $vm.query)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                Picker("섹션", selection: $segment) {
                    Text("용어").tag(Segment.terms)
                    Text("인물").tag(Segment.people)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                List {
                    if segment == .terms {
                        ForEach(vm.terms) { term in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(term.source)
                                        .font(.headline)
                                    Text(term.target)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if term.isEnabled == false {
                                        Label("적용 안 함", systemImage: "slash.circle")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if !term.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(term.category)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.thinMaterial)
                                            .clipShape(Capsule())
                                    }
                                }
                                Spacer()
                                Button {
                                    termSheetTarget = .edit(term.persistentModelID)
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete { idx in
                            idx.compactMap { vm.terms[$0] }.forEach { vm.delete($0) }
                        }
                    } else {
                        ForEach(vm.people) { p in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vm.displayName(for: p))
                                        .font(.headline)
                                    if let ft = p.familyTarget, let gt = p.givenTarget, !(ft+gt).isEmpty {
                                        Text("타겟: \(ft) \(gt)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !p.aliases.isEmpty {
                                        Text("별칭 \(p.aliases.count)개")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    personSheetTarget = .edit(p.persistentModelID)
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete { idx in
                            idx.compactMap { vm.people[$0] }.forEach { vm.deletePerson($0) }
                        }
                    }
                }
            }
            .navigationTitle("용어집")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "tray.and.arrow.down") }
                    Button { showExporter = true } label: { Image(systemName: "tray.and.arrow.up") }
                    if segment == .terms {
                        Button {
                            termSheetTarget = .create(UUID())
                        } label: { Image(systemName: "plus") }
                    } else {
                        Button {
                            personSheetTarget = .create(UUID())
                        } label: { Image(systemName: "person.crop.circle.badge.plus") }
                    }
                }
            }
            .sheet(item: $termSheetTarget) { target in
                TermEditorSheet(term: vm.term(for: target.termID)) { term, s, t, c, isEnabled in
                    vm.upsert(term: term, source: s, target: t, category: c, isEnabled: isEnabled)
                }
            }
            .sheet(item: $personSheetTarget) { target in
                PersonEditorSheet(person: vm.person(for: target.personID)) { action in
                    switch action {
                    case let .create(personId, familySources, familyTarget, givenSources, givenTarget, aliases):
                        vm.createPerson(personId: personId,
                                        familySources: familySources,
                                        familyTarget: familyTarget,
                                        givenSources: givenSources,
                                        givenTarget: givenTarget,
                                        aliases: aliases)
                    case let .update(person, familySources, familyTarget, givenSources, givenTarget, aliases):
                        vm.updatePerson(person,
                                        familySources: familySources,
                                        familyTarget: familyTarget,
                                        givenSources: givenSources,
                                        givenTarget: givenTarget,
                                        aliases: aliases)
                    case let .delete(person):
                        vm.deletePerson(person)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do { try vm.importJSON(from: url) } catch { print("import error: \(error)") }
                case .failure(let err):
                    print("import picker error: \(err)")
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: vm.makeExportDocument(),
                contentType: .json,
                defaultFilename: GlossaryConstants.exportFileName
            ) { result in
                if case .failure(let err) = result { print("export error: \(err)") }
            }
        }
    }
}

private enum TermSheetTarget: Identifiable {
    case create(UUID)
    case edit(PersistentIdentifier)

    var id: String {
        switch self {
        case let .create(uuid):
            return "create-\(uuid.uuidString)"
        case let .edit(identifier):
            return "edit-\(String(describing: identifier))"
        }
    }

    var termID: PersistentIdentifier? {
        switch self {
        case .create:
            return nil
        case let .edit(identifier):
            return identifier
        }
    }

}

private enum PersonSheetTarget: Identifiable {
    case create(UUID)
    case edit(PersistentIdentifier)

    var id: String {
        switch self {
        case let .create(uuid):
            return "create-\(uuid.uuidString)"
        case let .edit(identifier):
            return "edit-\(String(describing: identifier))"
        }
    }

    var personID: PersistentIdentifier? {
        switch self {
        case .create:
            return nil
        case let .edit(identifier):
            return identifier
        }
    }

}
