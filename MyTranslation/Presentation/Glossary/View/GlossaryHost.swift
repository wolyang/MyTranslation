// File: GlossaryHost.swift
import SwiftUI
import SwiftData

/// `GlossaryTabView`를 시트나 풀스크린 컨텍스트에서 노출할 때 닫기 버튼을 제공하는 래퍼입니다.
struct GlossaryHost: View {
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
