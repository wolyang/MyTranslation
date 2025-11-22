// File: URLBarView+Suggestions.swift
import SwiftUI

extension URLBarView {
    /// 입력 중인 문자열을 기반으로 최근 URL을 필터링합니다.
    var filteredRecents: [String] {
        let query = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = storedRecentURLs
        guard !query.isEmpty else { return Array(urls.prefix(max(1, recentURLLimit))) }
        return urls.filter { $0.localizedCaseInsensitiveContains(query) }
            .prefix(max(1, recentURLLimit))
            .map { $0 }
    }

    /// 추천 목록을 표시할지 여부입니다.
    var shouldShowSuggestions: Bool {
        return isFocused && !filteredRecents.isEmpty
    }

    /// `AppStorage`로 보존된 최근 URL 배열 접근자입니다.
    var storedRecentURLs: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: recentURLsData)) ?? []
        }
        nonmutating set {
            recentURLsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// 텍스트 필드 높이를 측정해 추천 목록 위치를 계산합니다.
    var fieldHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { fieldHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newValue in
                    fieldHeight = newValue
                }
        }
    }

    /// 전체 바 높이를 측정해 엔진 옵션 팝업의 위치를 정렬합니다.
    var barHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { barHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, newValue in
                    barHeight = newValue
                }
        }
    }

    /// 최근 방문 목록을 최신 순으로 관리합니다.
    func updateRecents(with newURL: String) {
        guard !newURL.isEmpty else { return }
        var urls = storedRecentURLs
        urls.removeAll { $0.caseInsensitiveCompare(newURL) == .orderedSame }
        urls.insert(newURL, at: 0)
        trimRecentsArray(&urls)
        storedRecentURLs = urls
    }

    /// 저장된 최근 방문 기록을 현재 제한에 맞게 자릅니다.
    func trimRecents(to limit: Int) {
        var urls = storedRecentURLs
        trimRecentsArray(&urls, limit: limit)
        storedRecentURLs = urls
    }

    private func trimRecentsArray(_ urls: inout [String], limit: Int? = nil) {
        let limit = limit ?? recentURLLimit
        let clampedLimit = max(1, limit)
        if urls.count > clampedLimit {
            urls = Array(urls.prefix(clampedLimit))
        }
    }

    /// 현재 입력과 페이지 상태를 바탕으로 새로고침 동작인지 여부를 판단합니다.
    var isRefreshAction: Bool {
        let trimmedCurrent = currentPageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = originalURLBeforeEditing.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return false }
        let isUnchanged = trimmedInput == trimmedOriginal
        let matchesCurrent = trimmedInput == trimmedCurrent && !trimmedCurrent.isEmpty
        return isUnchanged && matchesCurrent
    }

    /// 입력값과 현재 페이지를 비교해 이동/새로고침 아이콘을 결정합니다.
    var goButtonSymbolName: String {
        let trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return "arrow.right.circle.fill" }
        return isRefreshAction ? "arrow.clockwise.circle.fill" : "arrow.right.circle.fill"
    }
}
