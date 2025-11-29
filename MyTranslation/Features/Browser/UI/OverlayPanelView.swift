import SwiftUI
import UIKit

private let maxScrollHeight: CGFloat = 160

struct OverlayPanelView: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void
    let onAddToGlossary: (String, NSRange, OverlayTextSection) -> Void

    @State private var contentWidth: CGFloat = .zero
    @State private var textSize: CGSize = .zero

    private var primaryFinalTitle: String { "\(state.primaryEngineTitle) 최종 번역" }
    private var primaryPreNormalizedTitle: String { "\(state.primaryEngineTitle) 정규화 전" }
    private var isDebugModeEnabled: Bool { DebugConfig.isDebugModeEnabled }

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

    private var measurementText: String {
        var blocks: [String] = []
        if state.showsOriginalSection {
            blocks.append(sectionMeasurementText(
                title: "원문",
                body: bodyString(for: originalSectionContent, isLoading: false, errorMessage: nil)
            ))
        }
        if let improved = state.improvedText, improved.isEmpty == false {
            blocks.append(sectionMeasurementText(title: "AI 개선 번역", body: improved))
        }
        blocks.append(sectionMeasurementText(
            title: primaryFinalTitle,
            body: bodyString(for: primaryFinalContent, isLoading: false, errorMessage: nil)
        ))
        if isDebugModeEnabled {
            blocks.append(sectionMeasurementText(
                title: primaryPreNormalizedTitle,
                body: bodyString(for: primaryPreNormalizedContent, isLoading: false, errorMessage: nil)
            ))
        }
        for translation in state.translations {
            let body = bodyString(
                for: translationContent(for: translation),
                isLoading: translation.isLoading,
                errorMessage: translation.errorMessage
            )
            blocks.append(sectionMeasurementText(title: translation.title, body: body))
        }
        return blocks.joined(separator: "\n\n")
    }

    private var requiresScroll: Bool {
        guard textSize != .zero else { return false }
        return textSize.height - maxScrollHeight > 1
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.showsOriginalSection {
                TranslationSectionView(
                    title: "원문",
                    content: originalSectionContent,
                    isLoading: false,
                    errorMessage: nil,
                    availableWidth: contentWidth,
                    isSelectable: true,
                    sectionType: .original,
                    onAddToGlossary: onAddToGlossary
                )
            }
            if let improved = state.improvedText, improved.isEmpty == false {
                TranslationSectionView(
                    title: "AI 개선 번역",
                    content: .plain(improved),
                    isLoading: false,
                    errorMessage: nil,
                    availableWidth: contentWidth,
                    isSelectable: true,
                    sectionType: .improved,
                    onAddToGlossary: onAddToGlossary
                )
            }
            TranslationSectionView(
                title: primaryFinalTitle,
                content: primaryFinalContent,
                isLoading: false,
                errorMessage: nil,
                availableWidth: contentWidth,
                isSelectable: true,
                sectionType: .primaryFinal,
                onAddToGlossary: onAddToGlossary
            )
            if isDebugModeEnabled {
                TranslationSectionView(
                    title: primaryPreNormalizedTitle,
                    content: primaryPreNormalizedContent,
                    isLoading: false,
                    errorMessage: nil,
                    availableWidth: contentWidth,
                    isSelectable: true,
                    sectionType: .primaryPreNormalized,
                    onAddToGlossary: onAddToGlossary
                )
            }
            ForEach(state.translations) { translation in
                TranslationSectionView(
                    title: translation.title,
                    content: translationContent(for: translation),
                    isLoading: translation.isLoading,
                    errorMessage: translation.errorMessage,
                    availableWidth: contentWidth,
                    isSelectable: true,
                    sectionType: .alternative(engineID: translation.engineID),
                    onAddToGlossary: onAddToGlossary
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func sectionMeasurementText(title: String, body: String) -> String {
        "\(title)\n\(body)"
    }

    private func bodyString(
        for content: TranslationSectionView.SectionContent,
        isLoading: Bool,
        errorMessage: String?
    ) -> String {
        if isLoading { return "불러오는 중..." }
        if let errorMessage, errorMessage.isEmpty == false { return errorMessage }
        switch content {
        case .plain(let text):
            return text?.isEmpty == false ? text! : "표시할 내용이 없습니다."
        case .highlighted(let highlighted):
            return highlighted?.plainText ?? "표시할 내용이 없습니다."
        }
    }

    private var originalSectionContent: TranslationSectionView.SectionContent {
        let highlights = state.primaryHighlightMetadata?.originalTermRanges ?? []
        return .highlighted(HighlightedText(text: state.selectedText, highlights: highlights))
    }

    private var primaryFinalContent: TranslationSectionView.SectionContent {
        guard let text = state.primaryFinalText else { return .plain(nil) }
        let highlights = state.primaryHighlightMetadata?.finalTermRanges ?? []
        return .highlighted(HighlightedText(text: text, highlights: highlights))
    }

    private var primaryPreNormalizedContent: TranslationSectionView.SectionContent {
        guard let text = state.primaryPreNormalizedText else { return .plain(nil) }
        let highlights = state.primaryHighlightMetadata?.preNormalizedTermRanges ?? []
        return .highlighted(HighlightedText(text: text, highlights: highlights))
    }

    private func translationContent(for translation: BrowserViewModel.OverlayState.Translation) -> TranslationSectionView.SectionContent {
        guard let text = translation.text else {
            return .plain(nil)
        }
        if let metadata = translation.highlightMetadata {
            return .highlighted(HighlightedText(text: text, highlights: metadata.finalTermRanges))
        }
        return .plain(text)
    }

    private func updateMeasuredSize(width: CGFloat, text: String) {
        guard width > 0 else {
            textSize = .zero
            return
        }

        let measuredSize = measureTextSize(for: width, text: text)
        if textSize != measuredSize {
            textSize = measuredSize
        }
    }

    private func measureTextSize(for width: CGFloat, text: String) -> CGSize {
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

struct OverlayPanelSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct OverlayPanelWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}
