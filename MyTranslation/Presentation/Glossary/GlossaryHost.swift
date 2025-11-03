// File: GlossaryHost.swift
import SwiftUI
import SwiftData

struct GlossaryHost: View { // NEW
    @Environment(\.dismiss) private var dismiss

    let modelContext: ModelContext

    var body: some View {
        GlossaryTabView(modelContext: modelContext)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") {
                        dismiss()
                    }
                    .accessibilityLabel("용어집 닫기")
                }
            }
            .interactiveDismissDisabled(false)
    }
}
