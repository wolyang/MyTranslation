// File: InlineReplacer.swift

import Foundation

/// Router 스트리밍 계약에서 정의한 TranslationStreamPayload 를 그대로 사용한다는 점을 명시한다.
/// NOTE: InlineReplacer 와 BrowserViewModel 은 동일한 payload 구조를 공유해야 하므로 수정 시 함께 검토할 것.

public enum InlineObserverBehavior {
    case keep
    case restart
    case disable
}

public protocol InlineReplacer {
    /// 초기 치환 상태를 TranslationStreamPayload 배열 기반으로 세팅한다.
    /// - NOTE: payload.originalText / translatedText 는 JS 브릿지에서도 동일한 키로 사용된다.
    func setPairs(
        _ payloads: [TranslationStreamPayload],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    )
    func apply(using exec: WebViewScriptExecutor, observe: Bool)
    func upsert(
        payload: TranslationStreamPayload,
        using exec: WebViewScriptExecutor,
        applyImmediately: Bool,
        highlight: Bool
    )
    func restore(using exec: WebViewScriptExecutor)
}
