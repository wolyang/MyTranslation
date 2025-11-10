//// File: PersonEditorSheet.swift
//import SwiftUI
//
//enum PersonEditAction {
//    case create(personId: String,
//                familySources: [String], familyTarget: String?,
//                givenSources: [String],  givenTarget: String?,
//                aliases: [(sources: [String], target: String?)])
//    case update(person: Person,
//                familySources: [String], familyTarget: String?,
//                givenSources: [String],  givenTarget: String?,
//                aliases: [(sources: [String], target: String?)])
//    case delete(person: Person)
//}
//
//struct PersonEditorSheet: View {
//    @Environment(\.dismiss) private var dismiss
//
//    let person: Person?
//    let onCommit: (PersonEditAction) -> Void
//
//    @State private var personId: String
//    @State private var familySourcesText: String
//    @State private var familyTarget: String
//    @State private var givenSourcesText: String
//    @State private var givenTarget: String
//
//    @State private var aliasRows: [AliasRow]
//
//    struct AliasRow: Identifiable, Hashable {
//        var id = UUID()
//        var sourcesText: String
//        var target: String
//    }
//
//    init(person: Person?, onCommit: @escaping (PersonEditAction) -> Void) {
//        self.person = person
//        self.onCommit = onCommit
//        _personId = State(initialValue: person?.personId ?? "")
//        _familySourcesText = State(initialValue: person?.familySources.joined(separator: ", ") ?? "")
//        _familyTarget = State(initialValue: person?.familyTarget ?? "")
//        _givenSourcesText = State(initialValue: person?.givenSources.joined(separator: ", ") ?? "")
//        _givenTarget = State(initialValue: person?.givenTarget ?? "")
//        _aliasRows = State(initialValue: (person?.aliases ?? []).map { AliasRow(sourcesText: $0.sources.joined(separator: ", "), target: $0.target ?? "") })
//    }
//
//    var body: some View {
//        NavigationStack {
//            Form {
//                Section("기본") {
//                    TextField("personId", text: $personId)
//                        .textInputAutocapitalization(.never)
//                        .autocorrectionDisabled()
//                        .disabled(person != nil) // 기존 인물은 ID 변경 금지
//                    TextField("family sources (쉼표 구분)", text: $familySourcesText)
//                    TextField("family target", text: $familyTarget)
//                    TextField("given sources (쉼표 구분)", text: $givenSourcesText)
//                    TextField("given target", text: $givenTarget)
//                }
//                Section("별칭(Aliases)") {
//                    if aliasRows.isEmpty {
//                        Text("별칭이 없습니다").foregroundStyle(.secondary)
//                    }
//                    ForEach($aliasRows) { $row in
//                        VStack(alignment: .leading) {
//                            TextField("sources (쉼표 구분)", text: $row.sourcesText)
//                            TextField("target (선택)", text: $row.target)
//                        }
//                    }
//                    .onDelete { idx in aliasRows.remove(atOffsets: idx) }
//                    Button { aliasRows.append(.init(sourcesText: "", target: "")) } label: {
//                        Label("별칭 추가", systemImage: "plus")
//                    }
//                }
//                if let person = person {
//                    Section {
//                        Button(role: .destructive) {
//                            onCommit(.delete(person: person))
//                            dismiss()
//                        } label: { Text("이 인물 삭제") }
//                    }
//                }
//            }
//            .navigationTitle(person == nil ? "인물 추가" : "인물 편집")
//            .toolbar {
//                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
//                ToolbarItem(placement: .confirmationAction) {
//                    Button("저장") {
//                        let famSources = familySourcesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
//                        let givSources = givenSourcesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
//                        let aliases: [(sources: [String], target: String?)] = aliasRows.map { row in
//                            let srcs = row.sourcesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
//                            let tgt = row.target.trimmingCharacters(in: .whitespaces)
//                            return (srcs, tgt.isEmpty ? nil : tgt)
//                        }
//                        if let person = person {
//                            onCommit(.update(person: person,
//                                             familySources: famSources, familyTarget: familyTarget.isEmpty ? nil : familyTarget,
//                                             givenSources: givSources,  givenTarget: givenTarget.isEmpty ? nil : givenTarget,
//                                             aliases: aliases))
//                        } else {
//                            onCommit(.create(personId: personId,
//                                              familySources: famSources, familyTarget: familyTarget.isEmpty ? nil : familyTarget,
//                                              givenSources: givSources,  givenTarget: givenTarget.isEmpty ? nil : givenTarget,
//                                              aliases: aliases))
//                        }
//                        dismiss()
//                    }
//                    .disabled(person == nil && personId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
//                }
//            }
//        }
//    }
//}
