//
//  TranslationOptions.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

/// 번역 엔진 호출 시 전달되는 옵션 묶음.
public struct TranslationOptions {
    public let preserveFormatting: Bool
    public let style: TranslationStyle
    public let applyGlossary: Bool
    public let sourceLanguage: SourceLanguageSelection
    public let targetLanguage: AppLanguage
    public let tokenSpacingBehavior: TokenSpacingBehavior
    public let bypassCache: Bool

    /// 각종 플래그와 언어, 마스킹 정책을 받아 옵션 객체를 생성한다.
    public init(
        preserveFormatting: Bool = true,
        style: TranslationStyle = .neutralDictionaryTone,
        applyGlossary: Bool = true,
        sourceLanguage: SourceLanguageSelection,
        targetLanguage: AppLanguage,
        tokenSpacingBehavior: TokenSpacingBehavior = .disabled,
        bypassCache: Bool = false
    ) {
        self.preserveFormatting = preserveFormatting
        self.style = style
        self.applyGlossary = applyGlossary
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.tokenSpacingBehavior = tokenSpacingBehavior
        self.bypassCache = bypassCache
    }
}
