// File: GlossaryHost.swift
import SwiftUI
import SwiftData

struct GlossaryHost: View { // NEW
    let modelContext: ModelContext

    var body: some View {
        GlossaryTabView(modelContext: modelContext)
    }
}
