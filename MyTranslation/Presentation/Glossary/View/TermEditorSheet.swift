// File: TermEditorSheet.swift
import SwiftData
import SwiftUI

struct TermEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let onSave: (String, String, String, Bool) -> Void

    @State private var source: String
    @State private var target: String
    @State private var category: String
    @State private var isEnabled: Bool

    init(term: Term?, onSave: @escaping (String, String, String, Bool) -> Void) {
        self.onSave = onSave
        _source = State(initialValue: term?.source ?? "")
        _target = State(initialValue: term?.target ?? "")
        _category = State(initialValue: term?.category ?? "")
        _isEnabled = State(initialValue: term?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("원문")) {
                    TextField("source", text: $source)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(header: Text("번역")) {
                    TextField("target", text: $target)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(header: Text("카테고리 (선택)")) {
                    TextField("category", text: $category)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(header: Text("번역 적용")) {
                    Toggle("이 용어를 번역에 사용", isOn: $isEnabled)
                }
            }
            .navigationTitle("용어 편집")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(source, target, category, isEnabled)
                        dismiss()
                    }.disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
