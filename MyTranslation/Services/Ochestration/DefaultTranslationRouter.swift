// File: DefaultTranslationRouter.swift
import Foundation

enum TranslationRouterError: Error {
    case noAvailableEngine
}

final class DefaultTranslationRouter: TranslationRouter {
    private let afm: TranslationEngine
    private let deepl: TranslationEngine
    private let google: TranslationEngine
    private let cache: CacheStore
    private let glossaryStore: GlossaryStore
    private let postEditor: PostEditor // 유지(호출 제거)
    private let comparer: ResultComparer? // 유지(호출 제거)
    private let reranker: Reranker? // 유지(호출 제거)

    // private lazy var fm: FMOrchestrator = .init(...)

    init(
        afm: TranslationEngine,
        deepl: TranslationEngine,
        google: TranslationEngine,
        cache: CacheStore,
        glossaryStore: GlossaryStore,
        postEditor: PostEditor,
        comparer: ResultComparer?,
        reranker: Reranker?
    ) {
        self.afm = afm
        self.deepl = deepl
        self.google = google
        self.cache = cache
        self.glossaryStore = glossaryStore
        self.postEditor = postEditor
        self.comparer = comparer
        self.reranker = reranker
    }

    public func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult] {
        let glossaryEntries: [GlossaryEntry]
        if options.applyGlossary {
            glossaryEntries = await MainActor.run { (try? glossaryStore.snapshot()) ?? [] }
        } else {
            glossaryEntries = []
        }

        let engine = engine(for: preferredEngine)
        return try await translate(
            segments: segments,
            options: options,
            engine: engine,
            glossaryEntries: glossaryEntries
        )
    }

    private func translate(
        segments: [Segment],
        options: TranslationOptions,
        engine: TranslationEngine,
        glossaryEntries: [GlossaryEntry]
    ) async throws -> [TranslationResult] {
        var cached: [TranslationResult] = []
        var toTranslate: [Segment] = []
        for segment in segments {
            let key = cacheKey(for: segment, options: options, engine: engine.tag)
            if let hit = cache.lookup(key: key) {
                cached.append(hit)
            } else {
                toTranslate.append(segment)
            }
        }

        var translated: [TranslationResult] = []
        if toTranslate.isEmpty == false {
            let termMasker = TermMasker()
            let maskedResults = toTranslate.map { segment in
                termMasker.maskWithLocks(segment: segment, glossary: glossaryEntries)
            }
            let maskedPacks = maskedResults.map { $0.pack }
            let maskedSegments = maskedPacks.map { item in
                Segment(
                    id: item.seg.id,
                    url: item.seg.url,
                    indexInPage: item.seg.indexInPage,
                    originalText: item.masked,
                    normalizedText: item.seg.normalizedText
                )
            }

            let engineResults = try await engine.translate(maskedSegments, options: options)
            let finals: [TranslationResult] = engineResults.enumerated().map { index, result in
                let pack = maskedPacks[index]
                let personQueues = maskedResults[index].personQueues
                let raw = result.text
                let corrected = termMasker.fixParticlesAroundLocks(raw, locks: pack.locks)
                let collapsedBefore = termMasker.collapseSpacesAroundTokensNearPunct(in: corrected, tokens: Array(pack.locks.keys))
                let unmasked = termMasker.unlockTermsSafely(
                    collapsedBefore,
                    locks: pack.locks,
                    personQueues: personQueues
                )
                let collapsedAfter = termMasker.collapseSpacesAroundReplacementsNearPunct(in: unmasked, replacements: pack.locks.mapValues({ $0.target
                }))
                let hanCount = collapsedAfter.unicodeScalars.filter { $0.properties.isIdeographic }.count
                let residual = Double(hanCount) / Double(max(collapsedAfter.count, 1))
                return TranslationResult(
                    id: result.id,
                    segmentID: result.segmentID,
                    engine: result.engine,
                    text: collapsedAfter,
                    residualSourceRatio: residual,
                    createdAt: result.createdAt
                )
            }

            translated.reserveCapacity(finals.count)
            for (index, result) in finals.enumerated() {
                translated.append(result)
                let key = cacheKey(for: maskedPacks[index].seg, options: options, engine: engine.tag)
                cache.save(result: result, forKey: key)
            }
        }

        let merged = cached + translated
        let bySegment: [String: TranslationResult] = merged.reduce(into: [:]) { storage, item in
            storage[item.segmentID] = item
        }
        return segments.compactMap { bySegment[$0.id] }
    }

    private func engine(for tag: EngineTag) -> TranslationEngine {
        switch tag {
        case .afm: return afm
        case .google: return google
        case .deepl: return deepl
        case .afmMask, .unknown: return afm
        }
    }

    func cacheKey(for segment: Segment, options: TranslationOptions, engine: EngineTag) -> String {
        "\(segment.id)|\(engine.rawValue)|pf=\(options.preserveFormatting)|style=\(options.style)|g=\(options.applyGlossary)"
    }
}
