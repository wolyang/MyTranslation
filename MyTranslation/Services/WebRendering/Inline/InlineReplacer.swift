// File: InlineReplacer.swift

import Foundation

public enum InlineObserverBehavior {
    case keep
    case restart
    case disable
}

/// NOTE: InlineReplacer는 TranslationStreamPayload 기반으로 데이터를 공유합니다.
/// BrowserViewModel과 후속 브랜치에서도 동일한 payload 구조를 사용하므로,
/// 새 이벤트 계약 변경 시 이곳 주석을 함께 업데이트해야 합니다.
public protocol InlineReplacer {
    func setPairs(
        _ payloads: [TranslationStreamPayload],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    )
    func upsert(
        payload: TranslationStreamPayload,
        using exec: WebViewScriptExecutor,
        applyImmediately: Bool,
        highlight: Bool
    )
    func apply(using exec: WebViewScriptExecutor, observe: Bool)
    func restore(using exec: WebViewScriptExecutor)
}
