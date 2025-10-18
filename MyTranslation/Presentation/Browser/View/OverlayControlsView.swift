// File: OverlayControlsView.swift
import SwiftUI

struct OverlayControlsView: View {
    @Binding var showOriginal: Bool

    var body: some View {
        Button {
            showOriginal.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: showOriginal ? "eye.slash" : "eye")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(showOriginal ? Color.accentColor : Color.primary)
                Text(showOriginal ? "숨김" : "원문")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showOriginal ? "번역 숨기기" : "원문 보기")
    }
}
