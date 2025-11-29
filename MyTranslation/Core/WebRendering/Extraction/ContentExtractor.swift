// MARK: - ContentExtractor.swift
import CryptoKit
import Foundation
import WebKit

protocol ContentExtractor {
    func extract(using exec: WebViewScriptExecutor, url: URL, config: SegmentExtractConfig) async throws -> [Segment]
}



