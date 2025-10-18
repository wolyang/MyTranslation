//
//  OverlayPanel.swift
//  MyTranslation
//
//  Created by sailor.m on 10/16/25.
//

import SwiftUI

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

    private var displayText: String {
        improvedText ?? selectedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("선택된 문장")
                .font(.headline)
            Text(displayText)
                .font(.body)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(alignment: .center, spacing: 8) {
                Button(action: onAsk) {
                    Text("AI에 물어보기")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onApply) {
                    Text("적용")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(improvedText == nil)

                Button(action: onClose) {
                    Text("닫기")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 4, x: 0, y: 2)
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
