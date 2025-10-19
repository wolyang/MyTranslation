// File: InlineReplacer.swift

import Foundation

public protocol InlineReplacer {
    func setPairs(_ pairs: [(original: String, translated: String)], using exec: WebViewScriptExecutor)
    func apply(using exec: WebViewScriptExecutor, observe: Bool)
    func upsert(
        payload: TranslationStreamPayload,
        using exec: WebViewScriptExecutor,
        applyImmediately: Bool,
        highlight: Bool
    )
    func restore(using exec: WebViewScriptExecutor)
}
