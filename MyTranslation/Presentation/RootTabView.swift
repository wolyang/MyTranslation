// File: RootTabView.swift
import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        TabView {
            BrowserTabView(container: container)
                .tabItem { Label("브라우저", systemImage: "globe") }
            GlossaryTabView()
                .tabItem { Label("용어집", systemImage: "book") }
        }
        .task {
            // 앱 시작 후 한 번 시드 시도
            GlossarySeeder.seedIfNeeded(modelContext)
        }
    }
}
