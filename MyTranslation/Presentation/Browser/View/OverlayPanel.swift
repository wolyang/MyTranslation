//
//  OverlayPanel.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import SwiftUI
import UIKit

struct OverlayPanelContainer: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void

    var body: some View {
        OverlayPanelPositioner(
            state: state,
            onAsk: onAsk,
            onClose: onClose
        )
    }
}

private struct OverlayPanelPositioner: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void

    @State private var panelSize: CGSize = .zero

    private let margin: CGFloat = 8
    private let maxWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let widthLimit = max(80, min(maxWidth, containerSize.width - margin * 2))
            OverlayPanelView(
                state: state,
                onAsk: onAsk,
                onClose: onClose
            )
            .frame(maxWidth: widthLimit, alignment: .leading)
            .background(
                GeometryReader { panelGeo in
                    Color.clear
                        .preference(key: OverlayPanelSizePreferenceKey.self, value: panelGeo.size)
                }
            )
            .onPreferenceChange(OverlayPanelSizePreferenceKey.self) { size in
                self.panelSize = size
            }
            .position(position(in: containerSize, fallbackWidth: widthLimit))
        }
    }

    private func position(in containerSize: CGSize, fallbackWidth: CGFloat) -> CGPoint {
        let size = panelSize == .zero ? CGSize(width: fallbackWidth, height: 120) : panelSize
        var x = state.anchor.minX
        var y = state.anchor.minY - size.height - margin

        if y < margin {
            y = state.anchor.maxY + margin
        }
        if x + size.width > containerSize.width - margin {
            x = containerSize.width - margin - size.width
        }
        if x < margin {
            x = margin
        }

        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
}

private struct OverlayPanelView: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void

    @State private var contentWidth: CGFloat = .zero
    @State private var textSize: CGSize = .zero

    private var measurementText: String {
        var blocks: [String] = []
        if state.showsOriginalSection {
            blocks.append(sectionMeasurementText(title: "원문", body: state.selectedText))
        }
        if let improved = state.improvedText, improved.isEmpty == false {
            blocks.append(sectionMeasurementText(title: "AI 개선 번역", body: improved))
        }
        for translation in state.translations {
            let body = displayText(for: translation)
            blocks.append(sectionMeasurementText(title: translation.title, body: body))
        }
        return blocks.joined(separator: "\n\n")
    }

    private var maxScrollHeight: CGFloat { 160 }

    private var requiresScroll: Bool {
        guard textSize != .zero else { return false }
        return textSize.height - maxScrollHeight > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if requiresScroll {
                    ScrollView {
                        contentSection
                    }
                    .frame(height: min(textSize.height, maxScrollHeight))
                } else {
                    contentSection
                }
            }
            .scrollIndicators(.never)
            .scrollDisabled(!requiresScroll)

            HStack(alignment: .center, spacing: 6) {
                Button(action: onAsk) {
                    Text("AI번역")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onClose) {
                    Text("닫기")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.callout)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(radius: 4, x: 0, y: 2)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OverlayPanelWidthPreferenceKey.self,
                    value: max(proxy.size.width - 20, 0) // horizontal padding
                )
            }
        )
        .onPreferenceChange(OverlayPanelWidthPreferenceKey.self) { width in
            if width > 0 {
                contentWidth = width
            }
        }
        .onAppear {
            updateMeasuredSize(width: contentWidth, text: measurementText)
        }
        .onChange(of: contentWidth) { _, newWidth in
            updateMeasuredSize(width: newWidth, text: measurementText)
        }
        .onChange(of: measurementText) { _, newText in
            updateMeasuredSize(width: contentWidth, text: newText)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.showsOriginalSection {
                TranslationSectionView(
                    title: "원문",
                    text: state.selectedText,
                    isLoading: false,
                    errorMessage: nil
                )
            }
            if let improved = state.improvedText, improved.isEmpty == false {
                TranslationSectionView(
                    title: "AI 개선 번역",
                    text: improved,
                    isLoading: false,
                    errorMessage: nil
                )
            }
            ForEach(state.translations) { translation in
                TranslationSectionView(
                    title: translation.title,
                    text: translation.text,
                    isLoading: translation.isLoading,
                    errorMessage: translation.errorMessage
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func sectionMeasurementText(title: String, body: String) -> String {
        "\(title)\n\(body)"
    }

    private func displayText(for translation: BrowserViewModel.OverlayState.Translation) -> String {
        if translation.isLoading {
            return "불러오는 중..."
        }
        if let error = translation.errorMessage, error.isEmpty == false {
            return error
        }
        if let text = translation.text, text.isEmpty == false {
            return text
        }
        return "표시할 내용이 없습니다."
    }
}

private struct TranslationSectionView: View {
    let title: String
    let text: String?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7, anchor: .center)
                    Text("불러오는 중...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let errorMessage, errorMessage.isEmpty == false {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let text, text.isEmpty == false {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            } else {
                Text("표시할 내용이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct OverlayPanelSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct OverlayPanelWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private extension OverlayPanelView {
    func updateMeasuredSize(width: CGFloat, text: String) {
        guard width > 0 else {
            textSize = .zero
            return
        }

        let measuredSize = measureTextSize(for: width, text: text)
        if textSize != measuredSize {
            textSize = measuredSize
        }
    }

    func measureTextSize(for width: CGFloat, text: String) -> CGSize {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .callout),
            .paragraphStyle: paragraphStyle
        ]

        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )

        return CGSize(
            width: ceil(boundingRect.width),
            height: ceil(boundingRect.height)
        )
    }
}
