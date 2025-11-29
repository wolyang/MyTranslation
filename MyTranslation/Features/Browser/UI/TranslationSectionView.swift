import SwiftUI
import UIKit

struct TranslationSectionView: View {
    let title: String
    let content: SectionContent
    let isLoading: Bool
    let errorMessage: String?
    let availableWidth: CGFloat
    let isSelectable: Bool
    var sectionType: OverlayTextSection?
    var onAddToGlossary: ((String, NSRange, OverlayTextSection) -> Void)?

    enum SectionContent {
        case plain(String?)
        case highlighted(HighlightedText?)
    }

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
            } else {
                switch content {
                case .plain(let text):
                    if let text, text.isEmpty == false {
                        let handler = isSelectable ? onAddToGlossary : nil
                        SelectableTextView(
                            text: text,
                            section: sectionType ?? .primaryFinal,
                            onAddToGlossary: handler
                        )
                            .frame(width: availableWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        emptyPlaceholder
                    }
                case .highlighted(let highlighted):
                    if let highlighted {
                        let handler = isSelectable ? onAddToGlossary : nil
                        SelectableTextView(
                            text: highlighted.plainText,
                            attributedText: highlighted.attributedString,
                            section: sectionType ?? .primaryFinal,
                            onAddToGlossary: handler
                        )
                            .frame(width: availableWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        emptyPlaceholder
                    }
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        Text("표시할 내용이 없습니다.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
