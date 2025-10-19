//
//  TranslationRouter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

/// 번역 라우터는 동기 배치 API와 신규 스트리밍 API를 동시에 노출한다.
protocol TranslationRouter {
    @available(*, deprecated, message: "translateStream(_:options:preferredEngine:progress:)를 사용하세요.")
    func translate(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: EngineTag
    ) async throws -> [TranslationResult]

    /// 스트리밍 번역 API. 이벤트 호출 순서는 Docs/streaming-translation-contract.md 참고.
    ///
    /// progress 콜백은 다음 순서를 보장한다:
    /// 1. cachedHit (캐시 적중 시 즉시)
    /// 2. requestScheduled (엔진 호출이 시작될 때)
    /// 3. partial / final (엔진 응답을 받는 즉시)
    /// 4. failed (세그먼트 단위 오류 발생 시)
    /// 5. completed (요청 전체 완료)
    func translateStream(
        segments: [Segment],
        options: TranslationOptions,
        preferredEngine: TranslationEngineID?,
        progress: @escaping (TranslationStreamEvent) -> Void
    ) async throws -> TranslationStreamSummary
}
