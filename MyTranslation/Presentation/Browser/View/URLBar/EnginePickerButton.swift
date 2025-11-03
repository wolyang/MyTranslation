// File: EnginePickerButton.swift
import SwiftUI

struct EnginePickerButton: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isShowingOptions: Bool
    @Binding var isTranslating: Bool

    var onInteract: () -> Void = {}

    var body: some View {
        Button {
            onInteract()
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingOptions.toggle()
            }
        } label: {
            VStack(spacing: 2) {
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "globe")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(showOriginal ? Color.gray : Color.accentColor)
                }
                Text(showOriginal ? "원문" : selectedEngine.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(showOriginal ? Color.gray : Color.accentColor)
            }
            .frame(width: 30)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
