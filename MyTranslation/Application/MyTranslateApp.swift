// File: MyTranslateApp.swift
import SwiftUI
import SwiftData

@main
struct MyTranslateApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var container: AppContainer

    init() {
        let modelContainer = try! ModelContainer(for: Person.self, Alias.self, Term.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        _container = StateObject(wrappedValue: AppContainer(context: modelContainer.mainContext, useOnDeviceFM: true, fmConfig:
FMConfig(enablePostEdit: true, enableComparer: false, enableRerank: false)))
        self.modelContainer = modelContainer
    }

    var body: some Scene {
        WindowGroup {
            BrowserRootView(container: container)
                .environmentObject(container)
//                .task {
//                    container.prepareFMIfNeeded()
//                }
        }
        .modelContainer(modelContainer)
    }
}
