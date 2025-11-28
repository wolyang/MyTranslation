// File: MyTranslateApp.swift
import SwiftUI
import SwiftData

@main
struct MyTranslateApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var container: AppContainer

    init() {
        let modelContainer = try! ModelContainer(for: Glossary.SDModel.SDTerm.self, Glossary.SDModel.SDSource.self, Glossary.SDModel.SDSourceIndex.self, Glossary.SDModel.SDComponent.self, Glossary.SDModel.SDGroup.self, Glossary.SDModel.SDComponentGroup.self, Glossary.SDModel.SDTag.self, Glossary.SDModel.SDTermTagLink.self, Glossary.SDModel.SDPattern.self, Glossary.SDModel.SDPatternMeta.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: false))

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
