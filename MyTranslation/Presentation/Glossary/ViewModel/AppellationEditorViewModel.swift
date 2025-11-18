import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppellationEditorViewModel {
    enum Position: String, CaseIterable, Identifiable, Hashable {
        case prefix
        case suffix

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .prefix: return "접두"
            case .suffix: return "접미"
            }
        }
    }

    let context: ModelContext
    private let existingMarker: Glossary.SDModel.SDAppellationMarker?

    var source: String
    var target: String
    var variants: String
    var position: Position
    var prohibitStandalone: Bool

    var errorMessage: String?
    var didSave: Bool = false

    init(context: ModelContext, markerID: String?) throws {
        self.context = context
        if let markerID {
            let descriptor = FetchDescriptor<Glossary.SDModel.SDAppellationMarker>(
                predicate: #Predicate { $0.uid == markerID }
            )
            guard let marker = try context.fetch(descriptor).first else {
                throw NSError(domain: "AppellationEditor", code: 404, userInfo: [NSLocalizedDescriptionKey: "대상 호칭을 찾을 수 없습니다."])
            }
            existingMarker = marker
            source = marker.source
            target = marker.target
            variants = marker.variants.joined(separator: ";")
            position = Position(rawValue: marker.position) ?? .prefix
            prohibitStandalone = marker.prohibitStandalone
        } else {
            existingMarker = nil
            source = ""
            target = ""
            variants = ""
            position = .prefix
            prohibitStandalone = false
        }
    }

    var title: String { existingMarker == nil ? "새 호칭" : "호칭 수정" }

    func save() -> Bool {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            errorMessage = "원문을 입력하세요."
            return false
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else {
            errorMessage = "번역을 입력하세요."
            return false
        }
        let variantList = variants
            .split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            if let marker = existingMarker {
                marker.source = trimmedSource
                marker.target = trimmedTarget
                marker.variants = variantList
                marker.position = position.rawValue
                marker.prohibitStandalone = prohibitStandalone
                marker.uid = "\(trimmedSource)|\(trimmedTarget)|\(position.rawValue)"
            } else {
                let marker = Glossary.SDModel.SDAppellationMarker(
                    source: trimmedSource,
                    target: trimmedTarget,
                    variants: variantList,
                    position: position.rawValue,
                    prohibitStandalone: prohibitStandalone
                )
                context.insert(marker)
            }
            try context.save()
            didSave = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
