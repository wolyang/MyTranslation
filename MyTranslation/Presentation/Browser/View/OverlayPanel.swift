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
    var onFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        OverlayPanelPositioner(
            state: state,
            onAsk: onAsk,
            onClose: onClose,
            onFrameChange: onFrameChange
        )
        .onDisappear {
            onFrameChange(.null)
        }
    }
}

private struct OverlayPanelPositioner: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void
    let onFrameChange: (CGRect) -> Void

    @State private var panelSize: CGSize = .zero
    @StateObject private var frameReporter = FrameReporter()

    private let margin: CGFloat = 8
    private let maxWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let containerOrigin = geo.frame(in: .global).origin
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
            .position(position(in: containerSize, containerOrigin: containerOrigin, fallbackWidth: widthLimit))
        }
    }

    private func position(in containerSize: CGSize, containerOrigin: CGPoint, fallbackWidth: CGFloat) -> CGPoint {
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

        let frame = CGRect(origin: CGPoint(x: x + containerOrigin.x, y: y + containerOrigin.y), size: size)
        reportFrameIfNeeded(frame)
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    private func reportFrameIfNeeded(_ frame: CGRect) {
        guard frameReporter.lastFrame != frame else { return }
        frameReporter.lastFrame = frame
        DispatchQueue.main.async {
            onFrameChange(frame)
        }
    }
}

private final class FrameReporter: ObservableObject {
    var lastFrame: CGRect = .null
}

private struct OverlayPanelView: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void

    @State private var contentWidth: CGFloat = .zero
    @State private var textSize: CGSize = .zero

    private var primaryFinalTitle: String { "\(state.primaryEngineTitle) 최종 번역" }
    private var primaryPreNormalizedTitle: String { "\(state.primaryEngineTitle) 정규화 전" }
    private var isDebugModeEnabled: Bool { DebugConfig.isDebugModeEnabled }

    private var measurementText: String {
        var blocks: [String] = []
        if state.showsOriginalSection {
            blocks.append(sectionMeasurementText(title: "원문", body: state.selectedText))
        }
        if let improved = state.improvedText, improved.isEmpty == false {
            blocks.append(sectionMeasurementText(title: "AI 개선 번역", body: improved))
        }
        blocks.append(sectionMeasurementText(title: primaryFinalTitle, body: displayText(for: state.primaryFinalText)))
        if isDebugModeEnabled {
            blocks.append(sectionMeasurementText(title: primaryPreNormalizedTitle, body: displayText(for: state.primaryPreNormalizedText)))
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
                    errorMessage: nil,
                    availableWidth: contentWidth
                )
            }
            if let improved = state.improvedText, improved.isEmpty == false {
                TranslationSectionView(
                    title: "AI 개선 번역",
                    text: improved,
                    isLoading: false,
                    errorMessage: nil,
                    availableWidth: contentWidth
                )
            }
            TranslationSectionView(
                title: primaryFinalTitle,
                text: state.primaryFinalText,
                isLoading: false,
                errorMessage: nil,
                availableWidth: contentWidth
            )
            if isDebugModeEnabled {
                TranslationSectionView(
                    title: primaryPreNormalizedTitle,
                    text: state.primaryPreNormalizedText,
                    isLoading: false,
                    errorMessage: nil,
                    availableWidth: contentWidth
                )
            }
            ForEach(state.translations) { translation in
                TranslationSectionView(
                    title: translation.title,
                    text: translation.text,
                    isLoading: translation.isLoading,
                    errorMessage: translation.errorMessage,
                    availableWidth: contentWidth
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func sectionMeasurementText(title: String, body: String) -> String {
        "\(title)\n\(body)"
    }

    private func displayText(for text: String?) -> String {
        if let text, text.isEmpty == false {
            return text
        }
        return "표시할 내용이 없습니다."
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
    let availableWidth: CGFloat

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
                SelectableTextView(text: text)
                    .frame(width: availableWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("표시할 내용이 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    var text: String
    var textStyle: UIFont.TextStyle = .callout
    var textColor: UIColor = .label
    var adjustsFontForContentSizeCategory: Bool = true

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        configureStaticProperties(of: textView)
        applyContent(to: textView)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ uiView: SelectableUITextView, context: Context) {
        applyContent(to: uiView)
        uiView.invalidateIntrinsicContentSize()
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableUITextView, context: Context) -> CGSize {
        applyContent(to: uiView)

        // SwiftUI 사용처에서 .frame(width: availableWidth)를 꼭 주고,
        // 여기서는 그 폭을 캐시에 전달
        if let w = proposal.width, w.isFinite, w > 0 {
            uiView.constrainedWidth = w
        }

        // intrinsicContentSize 경로도 쓰이므로 여기선 적당히 패스
        return uiView.intrinsicContentSize
    }

    private func configureStaticProperties(of textView: SelectableUITextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textAlignment = .left
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.allowsEditingTextAttributes = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byCharWrapping
    }

    private func applyContent(to textView: SelectableUITextView) {
        if textView.text != text {
            textView.text = text
        }
        textView.font = UIFont.preferredFont(forTextStyle: textStyle)
        textView.textColor = textColor
        textView.adjustsFontForContentSizeCategory = adjustsFontForContentSizeCategory
    }

    final class SelectableUITextView: UITextView {
        // SwiftUI가 제안한 폭을 브리징하기 위한 캐시
            var constrainedWidth: CGFloat?

            private var lastWidth: CGFloat = 0

            override func layoutSubviews() {
                super.layoutSubviews()
                // 폭이 바뀌면 intrinsic 재계산
                let w = bounds.width
                if w > 0, abs(w - lastWidth) > .ulpOfOne {
                    lastWidth = w
                    invalidateIntrinsicContentSize()
                }
            }

            override var intrinsicContentSize: CGSize {
                // 1) 우선 SwiftUI가 내려준 폭(있다면) 사용
                let w = (constrainedWidth ?? bounds.width)
                let width = w > 0 ? w : UIScreen.main.bounds.width

                // 2) 이 폭으로 줄바꿈/측정
                textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
                // 스크롤 끄고 패딩 제거되어 있음
                let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                // 가로는 자동, 세로만 정확히 리턴
                return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
            }
        
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) || action == #selector(cut(_:)) || action == #selector(delete(_:)) {
                return false
            }
            return super.canPerformAction(action, withSender: sender)
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
