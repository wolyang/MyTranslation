//
//  WebViewScriptExecutor.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

import Foundation

@MainActor
public protocol WebViewScriptExecutor {
    /// 주어진 JS 스니펫을 실행하고 결과를 문자열로 반환
    func runJS(_ script: String) async throws -> String

    /// 필요시, 페이지 URL 같은 메타를 얻고 싶다면 선택적으로 확장
    func currentURL() async -> URL?
}
