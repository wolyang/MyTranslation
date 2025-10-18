// File: OverlayControlsView.swift
import SwiftUI

struct OverlayControlsView: View {
    @Binding var showOriginal: Bool

    var body: some View {
        Button {
            showOriginal.toggle()
        } label: {
            Label(showOriginal ? "번역 숨기기" : "원문 보기", systemImage: showOriginal ? "eye.slash" : "eye")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(showOriginal ? Color.accentColor : Color.primary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(showOriginal ? Color.accentColor.opacity(0.18) : Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(showOriginal ? Color.accentColor : Color(.systemGray4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showOriginal ? "번역 숨기기" : "원문 보기")
    }
}
