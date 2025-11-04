// File: URLBarView+ControlGroup.swift
import SwiftUI

struct URLBarControlGroup: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isShowingEngineOptions: Bool
    @Binding var isTranslating: Bool
    @Binding var sourceLanguage: SourceLanguageSelection
    @Binding var targetLanguage: AppLanguage

    var onInteract: () -> Void
    var onTapMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            EnginePickerButton(
                selectedEngine: $selectedEngine,
                showOriginal: $showOriginal,
                isShowingOptions: $isShowingEngineOptions,
                isTranslating: $isTranslating,
                sourceLanguage: $sourceLanguage,
                targetLanguage: $targetLanguage,
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
                            .frame(height: 16)
                    }
                    .frame(width: 32)
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
