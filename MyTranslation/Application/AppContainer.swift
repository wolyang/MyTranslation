// File: AppContainer.swift
import Foundation
import SwiftData
import Translation

final class AppContainer: ObservableObject {
    // Engines / Services
    let afmService: AFMTranslationService
    let afmEngine: TranslationEngine

    // Router & infra
    let cache: CacheStore
    let glossaryStore: GlossaryStore
    let router: TranslationRouter
    
    let postEditor: PostEditor
    let comparer: ResultComparer?
    let reranker: Reranker?
    
    var settings = UserSettings()
    
    let fmManager: FMModelManaging
    let fmQuery: FMQueryService
    let fmConfig: FMConfig

    @MainActor
    init(context: ModelContext, useOnDeviceFM: Bool = true, fmConfig: FMConfig = .init()) {
        self.fmConfig = fmConfig
        
        self.afmService = AFMTranslationService()
        self.afmEngine  = AFMEngine(client: afmService)
        
        if useOnDeviceFM {
            let modelMgr = FMModelManager()
            self.fmManager = modelMgr
            self.fmQuery = DefaultFMQueryService(fm: modelMgr)
            self.postEditor = fmConfig.enablePostEdit ? FMPostEditor(fm: modelMgr) : NopPostEditor()
            self.comparer = fmConfig.enableComparer ? CrossEngineComparer(fm: modelMgr) : nil
            self.reranker = fmConfig.enableRerank ? RerankerImpl() : nil
        } else {
            self.fmManager = FMModelManager() // 더미로 유지
            self.postEditor = NopPostEditor()
            self.comparer = nil
            self.reranker = nil
            self.fmQuery = NopQueryService()
        }

        self.cache = DefaultCacheStore()
        self.glossaryStore = DefaultGlossaryStore(context: context)

        self.router = DefaultTranslationRouter(
            afm: afmEngine,
            deepl: DeepLEngine(),
            google: GoogleEngine(),
            cache: cache,
            glossaryStore: glossaryStore,
            postEditor: postEditor,
            comparer: comparer,
            reranker: reranker
        )
    }

    // SwiftUI .translationTask에서 넘어온 세션을 서비스에 연결
    @MainActor
    func attachAFMSession(_ session: TranslationSession) {
        afmService.attach(session: session)
    }
    
    /// AFM 세션 붙이기 전에 모델 준비(비동기 1회)
    func prepareFMIfNeeded() {
        Task { await fmManager.prepareIfNeeded() }
    }
}
