import Foundation

@MainActor
extension BrowserViewModel {
    func onGlossaryAddRequested(
        selectedText: String,
        selectedRange: NSRange,
        section: OverlayTextSection
    ) {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        let kind: GlossaryAddSheetState.SelectionKind = {
            switch section {
            case .original:
                return .original
            case .improved, .primaryFinal, .primaryPreNormalized, .alternative:
                return .translated
            }
        }()

        var matched: GlossaryAddSheetState.MatchedTerm? = nil
        if kind == .original,
           let overlay = overlayState,
           let metadata = overlay.primaryHighlightMetadata,
           let entry = metadata.matchedEntryForOriginal(nsRange: selectedRange, in: overlay.selectedText) {
            if case let .termStandalone(termKey) = entry.origin {
                matched = .init(key: termKey, entry: entry)
            }
        }

        glossaryAddSheet = GlossaryAddSheetState(
            selectedText: trimmed,
            selectedRange: selectedRange,
            section: section,
            selectionKind: kind,
            matchedTerm: matched
        )
    }
}
