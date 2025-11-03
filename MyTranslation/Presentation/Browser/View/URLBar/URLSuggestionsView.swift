// File: URLSuggestionsView.swift
import SwiftUI

/// 최근 URL 추천 목록을 나타내는 뷰입니다.
struct URLSuggestionsView: View {
    var urls: [String]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(urls, id: \.self) { url in
                Button { onSelect(url) } label: {
                    Text(url)
                        .font(.footnote)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if url != urls.last {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
        )
        .shadow(color: Color.black.opacity(0.1), radius: 10, y: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
