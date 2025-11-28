//
//  WKWebViewScriptAdapter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import WebKit
import Foundation

@MainActor
public final class WKWebViewScriptAdapter: WebViewScriptExecutor {
    private weak var webView: WKWebView?

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func runJS(_ script: String) async throws -> String {
        guard let webView else { throw NSError(domain: "WebViewDeallocated", code: -1) }
        return try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { any, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: any.map { "\($0)" } ?? "")
            }
        }
    }

    public func currentURL() async -> URL? {
        await MainActor.run { [weak webView] in webView?.url }
    }
}
