import SwiftUI
import UIKit

/// NSAttributedString 기반 하이라이트 텍스트 래퍼.
struct HighlightedText: Equatable {
    let plainText: String
    let attributedString: NSAttributedString

    init(text: String, highlights: [TermRange]) {
        plainText = text
        attributedString = Self.buildAttributedString(text: text, highlights: highlights)
    }

    private static func buildAttributedString(text: String, highlights: [TermRange]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)

        for highlight in highlights {
            let nsRange = NSRange(highlight.range, in: text)
            let backgroundColor: UIColor = {
                switch highlight.type {
                case .masked:
                    return UIColor.systemBlue.withAlphaComponent(0.3)
                case .normalized:
                    return UIColor.systemGreen.withAlphaComponent(0.3)
                }
            }()
            attributed.addAttribute(.backgroundColor, value: backgroundColor, range: nsRange)
        }

        return attributed
    }

    static func == (lhs: HighlightedText, rhs: HighlightedText) -> Bool {
        lhs.plainText == rhs.plainText && lhs.attributedString.isEqual(to: rhs.attributedString)
    }
}

/// NSAttributedString을 표시하는 SwiftUI 뷰.
struct AttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let isSelectable: Bool

    init(_ highlightedText: HighlightedText, isSelectable: Bool = true) {
        self.attributedText = highlightedText.attributedString
        self.isSelectable = isSelectable
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = isSelectable
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = .preferredFont(forTextStyle: .callout)
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.textContainer.lineBreakMode = .byCharWrapping
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = attributedText
        textView.isSelectable = isSelectable
    }
}
