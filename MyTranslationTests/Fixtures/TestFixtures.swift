import Foundation
@testable import MyTranslation

enum TestFixtures {
    static let baseURL = URL(string: "https://example.com")!

    static var sampleSegments: [Segment] {
        [
            makeSegment(id: "seg1", text: "Hello world."),
            makeSegment(id: "seg2", text: "Nice to meet you."),
            makeSegment(id: "seg3", text: "Good bye.")
        ]
    }

    static var japaneseSegments: [Segment] {
        [
            makeSegment(id: "jp1", text: "こんにちは"),
            makeSegment(id: "jp2", text: "さようなら")
        ]
    }

    static var koreanSegments: [Segment] {
        [
            makeSegment(id: "ko1", text: "안녕하세요"),
            makeSegment(id: "ko2", text: "다음에 봐요")
        ]
    }

    static var chineseSegments: [Segment] {
        [
            makeSegment(id: "zh1", text: "你好"),
            makeSegment(id: "zh2", text: "再见")
        ]
    }

    static var sampleTranslationResults: [TranslationResult] {
        let now = Date()
        return [
            makeTranslationResult(id: "r1", segmentID: "seg1", text: "안녕 세상.", createdAt: now),
            makeTranslationResult(id: "r2", segmentID: "seg2", text: "만나서 반가워.", createdAt: now.addingTimeInterval(1)),
            makeTranslationResult(id: "r3", segmentID: "seg3", text: "잘 가.", createdAt: now.addingTimeInterval(2))
        ]
    }

    static var defaultOptions: TranslationOptions {
        TranslationOptions(
            preserveFormatting: true,
            style: .neutralDictionaryTone,
            applyGlossary: true,
            sourceLanguage: .manual(AppLanguage(code: "en")),
            targetLanguage: AppLanguage(code: "ko"),
            tokenSpacingBehavior: .disabled
        )
    }

    static func makeSegment(
        id: String = UUID().uuidString,
        text: String,
        index: Int = 0,
        url: URL? = nil
    ) -> Segment {
        Segment(
            id: id,
            url: url ?? baseURL,
            indexInPage: index,
            originalText: text,
            normalizedText: text,
            domRange: nil
        )
    }

    static func makeTranslationResult(
        id: String = UUID().uuidString,
        segmentID: String,
        engine: EngineTag = .google,
        text: String,
        residualSourceRatio: Double = 0,
        createdAt: Date = Date()
    ) -> TranslationResult {
        TranslationResult(
            id: id,
            segmentID: segmentID,
            engine: engine,
            text: text,
            residualSourceRatio: residualSourceRatio,
            createdAt: createdAt
        )
    }

    static func makeTranslationOptions(
        preserveFormatting: Bool = true,
        style: TranslationStyle = .neutralDictionaryTone,
        applyGlossary: Bool = true,
        sourceLanguage: SourceLanguageSelection = .manual(AppLanguage(code: "en")),
        targetLanguage: AppLanguage = AppLanguage(code: "ko"),
        tokenSpacingBehavior: TokenSpacingBehavior = .disabled
    ) -> TranslationOptions {
        TranslationOptions(
            preserveFormatting: preserveFormatting,
            style: style,
            applyGlossary: applyGlossary,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            tokenSpacingBehavior: tokenSpacingBehavior
        )
    }
}
