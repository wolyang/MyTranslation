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
    let onApply: () -> Void
    let onClose: () -> Void

    var body: some View {
        OverlayPanelPositioner(
            state: state,
            onAsk: onAsk,
            onApply: onApply,
            onClose: onClose
        )
    }
}

private struct OverlayPanelPositioner: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onApply: () -> Void
    let onClose: () -> Void

    @State private var panelSize: CGSize = .zero

    private let margin: CGFloat = 8
    private let maxWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let widthLimit = max(80, min(maxWidth, containerSize.width - margin * 2))
            OverlayPanelView(
                selectedText: state.selectedText,
                improvedText: state.improvedText,
                onAsk: onAsk,
                onApply: onApply,
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
    let selectedText: String
    let improvedText: String?
    let onAsk: () -> Void
    let onApply: () -> Void
    let onClose: () -> Void

    @State private var contentWidth: CGFloat = .zero
    @State private var textSize: CGSize = .zero

    private var displayText: String {
        improvedText ?? selectedText
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
                        textSection
                    }
                    .frame(height: min(textSize.height, maxScrollHeight))
                } else {
                    textSection
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

                Button(action: onApply) {
                    Text("적용")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(improvedText == nil)

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
        .overlay(
            OverlayPanelTextMeasurer(
                text: displayText,
                width: contentWidth,
                onUpdate: { size in
                    if size != .zero {
                        textSize = size
                    }
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var textSection: some View {
        // UILabel 기반 높이 측정기를 사용하지만, 실제 표시는 SwiftUI Text로 유지한다.
        VStack(alignment: .leading, spacing: 6) {
            Text("선택된 문장")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(displayText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 2)
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

private struct OverlayPanelTextMeasurer: UIViewRepresentable {
    let text: String
    let width: CGFloat
    let onUpdate: (CGSize) -> Void

    func makeUIView(context: Context) -> OverlayPanelTextMeasurementView {
        OverlayPanelTextMeasurementView()
    }

    func updateUIView(_ uiView: OverlayPanelTextMeasurementView, context: Context) {
        guard width > 0 else {
            DispatchQueue.main.async {
                onUpdate(.zero)
            }
            return
        }

        uiView.configure(text: text, width: width)

        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.measuringLabel.sizeThatFits(fittingSize)

        DispatchQueue.main.async {
            onUpdate(size)
        }
    }
}

private final class OverlayPanelTextMeasurementView: UIView {
    let measuringLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = UIFont.preferredFont(forTextStyle: .callout)
        label.isHidden = true
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        addSubview(measuringLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, width: CGFloat) {
        measuringLabel.font = UIFont.preferredFont(forTextStyle: .callout)
        measuringLabel.text = text
        measuringLabel.preferredMaxLayoutWidth = width
        measuringLabel.frame = CGRect(origin: .zero, size: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
