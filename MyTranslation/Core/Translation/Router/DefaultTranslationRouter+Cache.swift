import Foundation

extension DefaultTranslationRouter {
    /// 용어집 사용 여부에 따라 최신 용어집 데이터를 가져온다.
    func fetchGlossaryData(fullText: String, shouldApply: Bool) async -> GlossaryData? {
        guard shouldApply else { return nil }
        return try? await glossaryRepository.fetchData(for: fullText)
    }

    /// 캐시 적중 시 최종 페이로드를 만들고, 적중하지 않으면 nil을 반환한다.
    func cacheHitPayload(
        for segment: Segment,
        options: TranslationOptions,
        engine: EngineTag,
        sequence: inout Int
    ) -> TranslationStreamPayload? {
        let key = cacheKey(for: segment, options: options, engine: engine)
        guard let hit = cache.lookup(key: key) else { return nil }

        let payload = TranslationStreamPayload(
            segmentID: segment.id,
            originalText: segment.originalText,
            translatedText: hit.text,
            engineID: hit.engine.rawValue,
            sequence: sequence
        )
        sequence += 1
        return payload
    }
}
