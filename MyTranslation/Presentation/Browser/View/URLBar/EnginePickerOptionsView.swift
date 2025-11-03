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
    var onInteract: () -> Void
    var onSelectEngine: (EngineTag, Bool) -> Void
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
}
