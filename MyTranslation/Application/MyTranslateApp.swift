// File: MyTranslateApp.swift
import SwiftUI
import SwiftData

@main
struct MyTranslateApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var container: AppContainer
    
    init() {
        let schema = Schema([Term.self])
        let modelContainer = try! ModelContainer(for: schema)
        
        _container = StateObject(wrappedValue: AppContainer(context: modelContainer.mainContext, useOnDeviceFM: true, fmConfig: FMConfig(enablePostEdit: true, enableComparer: false, enableRerank: false)))
        self.modelContainer = modelContainer
    }
    
    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(container)
                .task {
                    container.prepareFMIfNeeded()
                }
        }
        .modelContainer(modelContainer)
    }
}
