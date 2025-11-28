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

// AttributedTextView는 SelectableTextView에서 통합 지원하므로 별도 UIViewRepresentable은 제공하지 않는다.
