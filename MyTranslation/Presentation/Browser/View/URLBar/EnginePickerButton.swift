// File: EnginePickerButton.swift
import SwiftUI

struct EnginePickerButton: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var isShowingOptions: Bool
    @Binding var isTranslating: Bool
    @Binding var sourceLanguage: SourceLanguageSelection
    @Binding var targetLanguage: AppLanguage

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
                if showOriginal {
                    Text("원문")
                        .font(.caption2)
                        .foregroundStyle(Color.gray)
                } else {
                    VStack(spacing: 0) {
                        Text(selectedEngine.shortLabel)
                            .font(.caption2)
                        Text("\(sourceAbbreviation)→\(targetAbbreviation)")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 30)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sourceAbbreviation: String {
        switch sourceLanguage {
        case .auto(let detected):
            if let detected { return detected.languageCode?.uppercased() ?? "AUTO" }
            return "AUTO"
        case .manual(let language):
            return language.languageCode?.uppercased() ?? language.code.uppercased()
        }
    }

    private var targetAbbreviation: String {
        targetLanguage.languageCode?.uppercased() ?? targetLanguage.code.uppercased()
    }
}
