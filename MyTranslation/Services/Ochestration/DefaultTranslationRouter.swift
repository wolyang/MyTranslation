// File: DefaultTranslationRouter.swift
import Foundation

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
        options: TranslationOptions
    ) async throws -> [TranslationResult] {
        // 1) Glossary 스냅샷 (옵션이 켜진 경우에만)
        let entries: [GlossaryEntry]
        if options.applyGlossary {
            entries = await MainActor.run { (try? glossaryStore.snapshot()) ?? [] }
        } else {
            entries = []
        }

        // 2) 캐시 조회 → hit/miss 분리
        var cached: [TranslationResult] = []
        var toTranslate: [Segment] = []
        for s in segments {
            let key = cacheKey(for: s, options: options, engine: .afm)
            if let hit = cache.lookup(key: key) {
                cached.append(hit)
            } else {
                toTranslate.append(s)
            }
        }
        

        // 3) AFM으로 번역 (필요 시 마스킹)
        var translated: [TranslationResult] = []
        if toTranslate.isEmpty == false {
            let termMasker = TermMasker()
            
            // (a) glossary 마스킹
            let maskedResults =
                toTranslate.map { s in
                    termMasker.maskWithLocks(segment: s, glossary: entries)
                }
            let maskedPacks = maskedResults.map { $0.pack }

            let maskedSegments: [Segment] = maskedPacks.map { item in
                Segment(
                    id: item.seg.id,
                    url: item.seg.url,
                    indexInPage: item.seg.indexInPage,
                    originalText: item.masked,
                    normalizedText: item.seg.normalizedText
                )
            }

            // (b) AFM 번역 호출
//            let afmResults = try await afm.translate(maskedSegments, options: options)
            let afmResults = try await google.translate(maskedSegments, options: options)

            // 4) 언마스킹 → 리스크/리절듀얼 계산 → 캐시 저장
            struct FinalPack {
                let base: TranslationResult
                let finalText: String
                let residual: Double
                let source: String
            }

            // 언마스킹 후 바로 최종 텍스트로 사용 (FM 자동 후처리 제거)
            let finals: [FinalPack] = afmResults.enumerated().map { i, r in
                let pack = maskedPacks[i]
                let personQueues = maskedResults[i].personQueues
                let raw = r.text
                
                // 조사 교정 (토큰 주변만)
                let corrected = termMasker.fixParticlesAroundLocks(raw, locks: pack.locks)
                // 언락 (토큰 → 한국어 용어)
                let unmasked = termMasker.unlockTermsSafely(corrected, locks: pack.locks, personQueues: personQueues)
                
                // 간단 residual: 한자/한문자 비율 (기존 계산 유지)
                let hanCount = unmasked.unicodeScalars.filter { $0.properties.isIdeographic }.count
                let residual = Double(hanCount) / Double(max(unmasked.count, 1))
                return FinalPack(base: r, finalText: unmasked, residual: residual, source: pack.seg.originalText)
            }

            // 결과 합성 + 캐시 저장
            translated.reserveCapacity(finals.count)
            for (i, f) in finals.enumerated() {
                let result = TranslationResult(
                    id: f.base.id,
                    segmentID: f.base.segmentID,
                    engine: f.base.engine,
                    text: f.finalText,
                    residualSourceRatio: f.residual,
                    createdAt: f.base.createdAt
                )
                translated.append(result)
                let key = cacheKey(for: maskedPacks[i].seg, options: options, engine: .afm)
                cache.save(result: result, forKey: key)
            }
            print("4")
        }

        // 5) (옵션) 향후 DeepL/Google 후보군과의 비교/재랭킹 위치 (FM 자동 후처리 제거로 현재는 패스)

        // 6) 원래 순서로 머지 & 반환
        let merged = (cached + translated)
        let bySegment: [String: TranslationResult] = merged.reduce(into: [:]) { $0[$1.segmentID] = $1 }
        return segments.compactMap { bySegment[$0.id] }
    }

    func cacheKey(for segment: Segment, options: TranslationOptions, engine: EngineTag) -> String {
        "\(segment.id)|\(engine.rawValue)|pf=\(options.preserveFormatting)|style=\(options.style)|g=\(options.applyGlossary)"
    }
}
