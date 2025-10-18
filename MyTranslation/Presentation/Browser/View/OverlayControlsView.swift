// File: OverlayControlsView.swift
import SwiftUI

struct OverlayControlsView: View {
    @Binding var showOriginal: Bool

    var body: some View {
        Button {
            showOriginal.toggle()
        } label: {
            Label("원문 보기", systemImage: showOriginal ? "eye.slash" : "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(showOriginal ? Color.accentColor : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
