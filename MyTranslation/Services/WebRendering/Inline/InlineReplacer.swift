// File: InlineReplacer.swift

import Foundation

public enum InlineObserverBehavior {
    case keep
    case restart
    case disable
}

public protocol InlineReplacer {
    func setPairs(
        _ pairs: [(original: String, translated: String)],
        using exec: WebViewScriptExecutor,
        observer: InlineObserverBehavior
    )
    func upsertPair(
        _ pair: (original: String, translated: String),
        using exec: WebViewScriptExecutor,
        immediateApply: Bool
    )
    func apply(using exec: WebViewScriptExecutor, observe: Bool)
    func restore(using exec: WebViewScriptExecutor)
}
