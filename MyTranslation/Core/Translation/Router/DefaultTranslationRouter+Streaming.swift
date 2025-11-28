import Foundation

extension DefaultTranslationRouter {
    /// 엔진 스트림을 소비하며 최종 이벤트를 생성한다.
    func processStream(
        runID: String,
        engine: TranslationEngine,
        engineTag: EngineTag,
        maskedSegments: [Segment],
        pendingSegments: [Segment],
        indexByID: [String: Int],
        termMasker: TermMasker,
        maskingContext: MaskingContext,
        options: TranslationOptions,
        sequence: Int,
        state: StreamProcessingState,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> (newSequence: Int, newState: StreamProcessingState) {
        print(
            "[T] router.processStream ENTER masked=\(maskedSegments.count) engine=\(engine.tag.rawValue)"
        )

        var didLogFirstEmit = false

        var seq = sequence
        var st = state

        defer {
            print(
                "[T] router.processStream EXIT masked=\(maskedSegments.count) engine=\(engine.tag.rawValue) remaining=\(st.remainingIDs.count)"
            )
        }

        // 마스킹/원본 ID 일치 여부 체크 로그
        if maskedSegments.count == pendingSegments.count {
            for i in 0..<min(maskedSegments.count, 5) {
                if maskedSegments[i].id != pendingSegments[i].id {
                    print("[Router][WARN] masked vs pending ID mismatch at \(i): \(maskedSegments[i].id) vs \(pendingSegments[i].id)")
                }
            }
        } else {
            print("[Router][WARN] masked.count(\(maskedSegments.count)) != pending.count(\(pendingSegments.count))")
        }

        // 스트림 생성도 Task 안에서 수행 → 취소 신속 반응
        let stream = try await engine.translate(runID: runID, maskedSegments, options: options)

        var sawAnyBatch = false
        for try await batch in stream {
            if sawAnyBatch == false {
                print("[T] router.processStream GOT-BATCH count=\(batch.count) engine=\(engine.tag.rawValue)")
                sawAnyBatch = true
            }
            try Task.checkCancellation()
            for result in batch {
                try Task.checkCancellation()
                guard let index = indexByID[result.segmentID] else {
                    st.unexpectedIDs.insert(result.segmentID)
                    continue
                }
                guard st.remainingIDs.remove(result.segmentID) != nil else {
                    st.unexpectedIDs.insert(result.segmentID)
                    continue
                }

                let pack = maskingContext.maskedPacks[index]
                let originalSegment = pendingSegments[index]
                print("[T] router.processStream [\(result.segmentID)] MASKED TEXT: \(maskedSegments[index].originalText)")
                let output = restoreOutput(
                    from: result.text,
                    pack: pack,
                    termMasker: termMasker,
                    nameGlossaries: maskingContext.nameGlossariesPerSegment[index],
                    pieces: maskingContext.segmentPieces[index],
                    shouldNormalizeNames: true
                )

                let hanCount = output.finalText.unicodeScalars.filter { $0.properties.isIdeographic }.count
                let residual = Double(hanCount) / Double(max(output.finalText.count, 1))
                let finalResult = TranslationResult(
                    id: result.id,
                    segmentID: result.segmentID,
                    engine: result.engine,
                    text: output.finalText,
                    residualSourceRatio: residual,
                    createdAt: result.createdAt
                )
                print("[T] router.processStream [\(result.segmentID)] FINAL RESULT: \(output.finalText)")

                let payload = TranslationStreamPayload(
                    segmentID: originalSegment.id,
                    originalText: originalSegment.originalText,
                    translatedText: finalResult.text,
                    preNormalizedText: output.preNormalizedText,
                    engineID: finalResult.engine.rawValue,
                    sequence: seq,
                    highlightMetadata: output.highlightMetadata
                )
                if didLogFirstEmit == false {
                    print("[T] router.processStream FIRST-EMIT seq=\(seq) seg=\(originalSegment.id) engine=\(engine.tag.rawValue)")

                    didLogFirstEmit = true
                }
                seq += 1
                progress(.init(kind: .final(segment: payload), timestamp: Date()))
                await Task.yield()

                st.succeededIDs.append(originalSegment.id)

                let cacheKey = cacheKey(for: pack.seg, options: options, engine: engineTag)
                cache.save(result: finalResult, forKey: cacheKey)
            }
        }
        if sawAnyBatch == false {
            print("[T][WARN] processStream: stream completed with 0 batches (no results)")
        }

        // 종료 검증
        if Task.isCancelled {
            throw CancellationError()
        }
        if let unexpected = st.unexpectedIDs.first {
            throw EngineStreamError.unexpectedID(unexpected)
        }
        if st.remainingIDs.isEmpty == false {
            throw EngineStreamError.missingIDs(st.remainingIDs)
        }

        return (seq, st)
    }

    /// 실패한 세그먼트에 대한 이벤트를 발행하고 실패 목록을 갱신한다.
    func markFailedSegments(
        _ ids: Set<String>,
        existingFailed: Set<String>,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async -> Set<String> {
        var updated = existingFailed
        for segmentID in ids where updated.contains(segmentID) == false {
            updated.insert(segmentID)
            progress(.init(kind: .failed(segmentID: segmentID, error: .engineFailure(code: nil)), timestamp: Date()))
            await Task.yield()
        }
        return updated
    }
}

// MARK: - Streaming helpers

private extension DefaultTranslationRouter {
    struct RestoredOutput {
        let finalText: String
        let preNormalizedText: String?
        let highlightMetadata: TermHighlightMetadata?
    }

    /// 정규화 range를 언마스킹 후 문자열 기준으로 변환한다.
    func translateNormalizationRanges(
        _ ranges: [TermRange],
        deltas: [TermMasker.ReplacementDelta],
        originalText: String,
        finalText: String
    ) -> [TermRange] {
        guard ranges.isEmpty == false else { return [] }
        guard deltas.isEmpty == false else { return ranges }

        func shift(for offset: Int) -> Int {
            deltas
                .filter { $0.offset < offset }
                .reduce(0) { $0 + $1.delta }
        }

        let finalCount = finalText.count

        return ranges.compactMap { range in
            let lowerOffset = originalText.distance(from: originalText.startIndex, to: range.range.lowerBound)
            let upperOffset = originalText.distance(from: originalText.startIndex, to: range.range.upperBound)
            let newLowerOffset = lowerOffset + shift(for: lowerOffset)
            let newUpperOffset = upperOffset + shift(for: upperOffset)
            guard newLowerOffset >= 0, newUpperOffset >= newLowerOffset, newUpperOffset <= finalCount else {
                return nil
            }
            let newLower = finalText.index(finalText.startIndex, offsetBy: newLowerOffset)
            let newUpper = finalText.index(finalText.startIndex, offsetBy: newUpperOffset)
            return TermRange(entry: range.entry, range: newLower..<newUpper, type: range.type)
        }
    }

    /// 마스킹 해제 및 정규화를 수행해 최종 출력 문자열과 메타데이터를 만든다.
    func restoreOutput(
        from text: String,
        pack: MaskedPack,
        termMasker: TermMasker,
        nameGlossaries: [TermMasker.NameGlossary],
        pieces: SegmentPieces,
        shouldNormalizeNames: Bool
    ) -> RestoredOutput {
        print("[T] router.processStream [\(pack.seg.id)] TRANSLATED ORITINAL RESULT: \(text)")
        let cleaned = termMasker.normalizeDamagedETokens(text, locks: pack.locks)

        let originalRanges: [TermRange] = pieces.termRanges().map { item in
            TermRange(
                entry: item.entry,
                range: item.range,
                type: item.entry.preMask ? .masked : .normalized
            )
        }

        let preNormalized = termMasker.unmaskWithOrder(
            in: cleaned,
            pieces: pieces,
            locksByToken: pack.locks,
            tokenEntries: pack.tokenEntries
        )
        let fallbackMaskedRanges = preNormalized.ranges.isEmpty
            ? mapMaskedTerms(from: pieces, in: preNormalized.text)
            : []

        var normalizationRanges: [TermRange] = []
        var preNormalizationRanges: [TermRange] = []
        var normalizedText = preNormalized.text
        if shouldNormalizeNames, nameGlossaries.isEmpty == false {
            let normalized = termMasker.normalizeWithOrder(
                in: normalizedText,
                pieces: pieces,
                nameGlossaries: nameGlossaries
            )
            normalizedText = normalized.text
            normalizationRanges.append(contentsOf: normalized.ranges)
            preNormalizationRanges.append(contentsOf: normalized.preNormalizedRanges)
        }

        let unmasked = termMasker.unmaskWithOrder(
            in: normalizedText,
            pieces: pieces,
            locksByToken: pack.locks,
            tokenEntries: pack.tokenEntries
        )
        let translatedNormalizationRanges = translateNormalizationRanges(
            normalizationRanges,
            deltas: unmasked.deltas,
            originalText: normalizedText,
            finalText: unmasked.text
        )
        let finalMaskedRanges = unmasked.ranges.isEmpty
            ? mapMaskedTerms(from: pieces, in: unmasked.text)
            : unmasked.ranges

        var finalText = unmasked.text
        if pack.locks.values.count == 1,
           let target = pack.locks.values.first?.target {
            finalText = termMasker.collapseSpaces_PunctOrEdge_whenIsolatedSegment(finalText, target: target)
        }

        let metadata = TermHighlightMetadata(
            originalTermRanges: originalRanges,
            finalTermRanges: translatedNormalizationRanges + finalMaskedRanges,
            preNormalizedTermRanges: preNormalized.ranges + fallbackMaskedRanges + preNormalizationRanges
        )

        return RestoredOutput(
            finalText: finalText,
            preNormalizedText: preNormalized.text,
            highlightMetadata: metadata
        )
    }

    /// unmaskWithOrder로 range를 얻지 못했을 때를 대비해 preMask 용어를 텍스트에서 직접 매핑한다.
    func mapMaskedTerms(from pieces: SegmentPieces, in text: String) -> [TermRange] {
        let maskedEntries = pieces.pieces.compactMap { piece -> GlossaryEntry? in
            if case let .term(entry, _) = piece, entry.preMask { return entry }
            return nil
        }
        guard maskedEntries.isEmpty == false else { return [] }

        var ranges: [TermRange] = []
        var searchStart = text.startIndex

        for entry in maskedEntries {
            guard let found = text.range(of: entry.target, range: searchStart..<text.endIndex) ??
                    text.range(of: entry.target) else { continue }
            ranges.append(.init(entry: entry, range: found, type: .masked))
            searchStart = found.upperBound
        }

        return ranges
    }
}

// MARK: - Streaming state

extension DefaultTranslationRouter {
    struct StreamProcessingState {
        var remainingIDs: Set<String>
        var unexpectedIDs: Set<String>
        var succeededIDs: [String]
    }
}
