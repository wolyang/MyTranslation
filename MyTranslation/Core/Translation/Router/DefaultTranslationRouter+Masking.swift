import Foundation

extension DefaultTranslationRouter {
    /// 외부(예: 오버레이)에서 사용할 수 있는 마스킹 컨텍스트 생성기. 엔진 독립적이다.
    public func prepareMaskingContext(
        segments: [Segment],
        options: TranslationOptions
    ) async -> MaskingContext? {
        let glossaryData = await fetchGlossaryData(
            fullText: segments.map { $0.originalText }.joined(),
            shouldApply: options.applyGlossary
        )

        let termActivationFilter = TermActivationFilter()
        let termMasker = TermMasker()
        termMasker.tokenSpacingBehavior = options.tokenSpacingBehavior

        return await prepareMaskingContextInternal(
            from: segments,
            glossaryData: glossaryData,
            termMasker: termMasker,
            termActivationFilter: termActivationFilter
        )
    }

    /// 스트리밍 처리를 위해 마스킹된 세그먼트와 보조 정보를 구성한다.
    func prepareMaskingContextInternal(
        from segments: [Segment],
        glossaryData: GlossaryData?,
        termMasker: TermMasker,
        termActivationFilter: TermActivationFilter
    ) async -> MaskingContext {
        var allSegmentPieces: [SegmentPieces] = []
        var maskedPacks: [MaskedPack] = []
        var nameGlossariesPerSegment: [[NameGlossary]] = []

        for segment in segments {
            let (pieces, glossaryEntries) = termMasker.buildSegmentPieces(
                segment: segment,
                matchedTerms: glossaryData?.matchedTerms ?? [],
                patterns: glossaryData?.patterns ?? [],
                matchedSources: glossaryData?.matchedSourcesByKey ?? [:],
                termActivationFilter: termActivationFilter
            )
            allSegmentPieces.append(pieces)

            let pack = termMasker.maskFromPieces(
                pieces: pieces,
                segment: segment
            )
            maskedPacks.append(pack)

            let nameGlossaries = termMasker.makeNameGlossariesFromPieces(
                pieces: pieces,
                allEntries: glossaryEntries
            )
            nameGlossariesPerSegment.append(nameGlossaries)
        }

        let maskedSegments: [Segment] = maskedPacks.map { pack in
            Segment(
                id: pack.seg.id,
                url: pack.seg.url,
                indexInPage: pack.seg.indexInPage,
                originalText: pack.masked,
                normalizedText: pack.seg.normalizedText,
                domRange: pack.seg.domRange
            )
        }

        return MaskingContext(
            maskedSegments: maskedSegments,
            maskedPacks: maskedPacks,
            nameGlossariesPerSegment: nameGlossariesPerSegment,
            segmentPieces: allSegmentPieces
        )
    }

    /// 마스킹 연산에 필요한 컨텍스트를 표현한다. 엔진 독립적이다.
    struct MaskingContext: Sendable {
        let maskedSegments: [Segment]
        let maskedPacks: [MaskedPack]
        let nameGlossariesPerSegment: [[NameGlossary]]
        let segmentPieces: [SegmentPieces]
    }
}
