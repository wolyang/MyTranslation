// File: TermEditorSheet.swift
import SwiftUI

struct TermEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 편집 대상(nil이면 신규)
    let original: Term?
    /// 저장 콜백: 신규/수정 모두 Term 반환
    let onSave: (Term) -> Void
    let onCancel: () -> Void

    @State private var draft: TermDraft

    init(term: Term?, onSave: @escaping (Term) -> Void, onCancel: @escaping () -> Void) {
        self.original = term
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: term.map(TermDraft.init(from:)) ?? TermDraft())
    }

    private var isNew: Bool { original == nil }
    private var titleText: String { isNew ? "용어 추가" : "용어 편집" }

    var body: some View {
        NavigationStack {
            Form {
                Section("기본") {
                    TextField("source", text: Binding(
                        get: { draft.source },
                        set: { draft.source = $0 }
                    ))
                    TextField("target", text: Binding(
                        get: { draft.target },
                        set: { draft.target = $0 }
                    ))
                    Toggle("strict", isOn: Binding(
                        get: { draft.strict },
                        set: { draft.strict = $0 }
                    ))
                    Picker("카테고리", selection: Binding(
                        get: { draft.category ?? "" },
                        set: { draft.category = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("선택 안 함").tag("")
                        ForEach(GlossaryConstants.categories, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("옵션") {
                    TextField("variants(쉼표로 구분)", text: Binding(
                        get: { draft.variants.joined(separator: ",") },
                        set: { draft.variants = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                    TextField("notes", text: Binding(
                        get: { draft.notes ?? "" },
                        set: { draft.notes = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let out = draft.toModel(into: original)
                        onSave(out)
                        dismiss()
                    }
                    .disabled(draft.source.trimmingCharacters(in: .whitespaces).isEmpty ||
                              draft.target.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}


private struct TermDraft {
    var source: String = ""
    var target: String = ""
    var strict: Bool = true
    var variants: [String] = []
    var notes: String? = nil
    var category: String? = nil

    init() {}
    init(from term: Term) {
        source = term.source
        target = term.target
        strict = term.strict
        variants = term.variants
        notes = term.notes
        category = term.category
    }

    func toModel(into existing: Term? = nil) -> Term {
        if let t = existing {
            t.source = source
            t.target = target
            t.strict = strict
            t.variants = variants
            t.notes = notes
            t.category = category
            return t
        } else {
            return Term(source: source, target: target, strict: strict, variants: variants, notes: notes, category: category)
        }
    }
}
