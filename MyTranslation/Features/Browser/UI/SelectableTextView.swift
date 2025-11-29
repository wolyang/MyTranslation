import SwiftUI
import UIKit

struct SelectableTextView: UIViewRepresentable {
    var text: String?
    var attributedText: NSAttributedString? = nil
    var textStyle: UIFont.TextStyle = .callout
    var textColor: UIColor = .label
    var adjustsFontForContentSizeCategory: Bool = true
    var section: OverlayTextSection = .primaryFinal
    var onAddToGlossary: ((String, NSRange, OverlayTextSection) -> Void)?

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        configureStaticProperties(of: textView)
        applyContent(to: textView)
        textView.section = section
        textView.onAddToGlossary = onAddToGlossary
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ uiView: SelectableUITextView, context: Context) {
        applyContent(to: uiView)
        uiView.section = section
        uiView.onAddToGlossary = onAddToGlossary
        uiView.invalidateIntrinsicContentSize()
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableUITextView, context: Context) -> CGSize {
        applyContent(to: uiView)

        if let w = proposal.width, w.isFinite, w > 0 {
            uiView.constrainedWidth = w
        }
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
        let needsAttributed = attributedText != nil

        if needsAttributed {
            if textView.attributedText != attributedText {
                textView.attributedText = attributedText
            }
        } else {
            let value = text ?? ""
            if textView.text != value {
                textView.text = value
            }
            if textView.attributedText?.string != value {
                textView.attributedText = nil
            }
        }

        textView.font = UIFont.preferredFont(forTextStyle: textStyle)
        textView.textColor = textColor
        textView.adjustsFontForContentSizeCategory = adjustsFontForContentSizeCategory
    }
}

final class SelectableUITextView: UITextView {
    var constrainedWidth: CGFloat?
    private var lastWidth: CGFloat = 0
    var section: OverlayTextSection = .primaryFinal
    var onAddToGlossary: ((String, NSRange, OverlayTextSection) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        if w > 0, abs(w - lastWidth) > .ulpOfOne {
            lastWidth = w
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        let w = (constrainedWidth ?? bounds.width)
        let width = w > 0 ? w : UIScreen.main.bounds.width
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) || action == #selector(cut(_:)) || action == #selector(delete(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @available(iOS 16.0, *)
    override func editMenu(
        for textRange: UITextRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let handler = onAddToGlossary else {
            return super.editMenu(for: textRange, suggestedActions: suggestedActions)
        }
        let location = offset(from: beginningOfDocument, to: textRange.start)
        let length = offset(from: textRange.start, to: textRange.end)
        let nsRange = NSRange(location: location, length: length)
        guard nsRange.length > 0,
              let text = text,
              let swiftRange = Range(nsRange, in: text) else {
            return super.editMenu(for: textRange, suggestedActions: suggestedActions)
        }
        let selected = String(text[swiftRange])
        let range = nsRange
        let action = UIAction(title: "용어집에 추가", image: UIImage(systemName: "book.closed")) { [weak self] _ in
            guard let self else { return }
            handler(selected, range, self.section)
        }
        return UIMenu(children: suggestedActions + [action])
    }
}
