//
//  TranslationOptions.swift
//  MyTranslation
//
//  Created by sailor.m on 10/15/25.
//

public struct TranslationOptions {
    public let preserveFormatting: Bool
    public let style: TranslationStyle
    public let applyGlossary: Bool
    public init(preserveFormatting: Bool = true, style: TranslationStyle = .colloquialKo, applyGlossary: Bool = true) {
        self.preserveFormatting = preserveFormatting
        self.style = style
        self.applyGlossary = applyGlossary
    }
}
