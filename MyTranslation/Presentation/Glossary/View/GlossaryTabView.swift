// File: GlossaryTabView.swift
import SwiftData
import SwiftUI

struct GlossaryTabView: View {
//    @StateObject private var vm: GlossaryViewModel
//
//    @State private var termSheetTarget: TermSheetTarget? = nil
//
//    @State private var showImporter: Bool = false
//    @State private var showExporter: Bool = false
//
//    // People UI
//    @State private var personSheetTarget: PersonSheetTarget? = nil
//
//    // Segment
//    enum Segment: String, CaseIterable, Identifiable { case terms = "용어"; case people = "인물"; var id: String { rawValue } }
//    @State private var segment: Segment = .terms
//
//    init(modelContext: ModelContext) {
//        _vm = StateObject(wrappedValue: GlossaryViewModel(modelContext: modelContext))
//    }

    var body: some View {
        Text("Hello world")
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
