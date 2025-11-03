// File: URLBarView+ControlGroup.swift
import SwiftUI

struct URLBarControlGroup: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isShowingEngineOptions: Bool
    @Binding var isTranslating: Bool

    var onInteract: () -> Void
    var onTapMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            EnginePickerButton(
                selectedEngine: $selectedEngine,
                showOriginal: $showOriginal,
                isShowingOptions: $isShowingEngineOptions,
                isTranslating: $isTranslating,
                onInteract: onInteract
            )

            if let onTapMore {
                Button(action: onTapMore) {
                    VStack(spacing: 2) {
                        Image(systemName: "ellipsis.circle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Color.accentColor)
                        Text("더보기")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("더보기 메뉴 열기")
            }
        }
    }
}
