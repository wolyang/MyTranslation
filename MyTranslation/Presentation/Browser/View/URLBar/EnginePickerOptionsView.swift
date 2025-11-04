// File: EnginePickerOptionsView.swift
import SwiftUI

struct EnginePickerOptionsContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                content()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct EnginePickerOptionsView: View {
    @Binding var selectedEngine: EngineTag
    @Binding var showOriginal: Bool
    @Binding var sourceLanguage: SourceLanguageSelection
    @Binding var targetLanguage: AppLanguage
    var onInteract: () -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void
    var onSelectSourceLanguage: (SourceLanguageSelection) -> Void
    var onSelectTargetLanguage: (AppLanguage) -> Void
    var dismiss: () -> Void

    var body: some View {
        let engines = Array(EngineTag.allCases)

        return VStack(spacing: 0) {
            OptionButton(title: "원문 보기", isSelected: showOriginal) {
                onInteract()
                if showOriginal == false {
                    showOriginal = true
                }
                dismiss()
            }

            Divider()

            ForEach(engines.indices, id: \.self) { index in
                let engine = engines[index]
                OptionButton(title: engine.displayName, isSelected: !showOriginal && engine == selectedEngine) {
                    onInteract()
                    let wasShowingOriginal = showOriginal
                    selectedEngine = engine
                    onSelectEngine(engine, wasShowingOriginal)
                    if wasShowingOriginal {
                        showOriginal = false
                    }
                    dismiss()
                }

                if index < engines.count - 1 {
                    Divider()
                }
            }

            Divider()

            LanguageSection(title: "출발 언어") {
                OptionButton(title: autoSourceTitle, isSelected: sourceLanguage.isManual == false) {
                    onInteract()
                    onSelectSourceLanguage(.auto(detected: nil))
                }

                ForEach(LanguageCatalog.manualSourceLanguages) { language in
                    OptionButton(title: language.displayName, isSelected: sourceLanguage == .manual(language)) {
                        onInteract()
                        onSelectSourceLanguage(.manual(language))
                    }
                }

                if case .auto(let detected) = sourceLanguage, let detected {
                    Text("감지된 언어: \(detected.displayName)")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }

            Divider()

            LanguageSection(title: "도착 언어") {
                ForEach(LanguageCatalog.targetLanguages) { language in
                    OptionButton(title: language.displayName, isSelected: targetLanguage == language) {
                        onInteract()
                        onSelectTargetLanguage(language)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 6)
    }

    private struct OptionButton: View {
        let title: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack {
                    Text(title)
                        .foregroundColor(.primary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private struct LanguageSection<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.secondary)
                content()
            }
            .padding(.top, 8)
        }
    }

    private var autoSourceTitle: String {
        if case .auto(let detected) = sourceLanguage, let detected {
            return "자동 감지 (\(detected.displayName))"
        }
        return "자동 감지"
    }
}
