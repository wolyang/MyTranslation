import SwiftUI
import UIKit

struct OverlayPanelContainer: View {
    let state: BrowserViewModel.OverlayState
    let onAsk: () -> Void
    let onClose: () -> Void
    let onAddToGlossary: (String, NSRange, OverlayTextSection) -> Void
    var onFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        OverlayPanelPositioner(
            state: state,
            onAsk: onAsk,
            onClose: onClose,
            onAddToGlossary: onAddToGlossary,
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
    let onAddToGlossary: (String, NSRange, OverlayTextSection) -> Void
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
                onClose: onClose,
                onAddToGlossary: onAddToGlossary
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
