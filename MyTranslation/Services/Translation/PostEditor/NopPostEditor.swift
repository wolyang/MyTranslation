// NopPostEditor.swift
import Foundation


/// 더미/샘플 구현: 실제 FM 호출로 교체하세요.
public struct NopPostEditor: PostEditor {
    public init() {}
    public func postEditBatch(texts: [String], style: TranslationStyle) async throws -> [String] { texts }
}

// 예시: 프롬프트 템플릿(서버/SDK 쪽에서 사용)
// - 의미/사실/숫자/기호/URL/⟪Gk⟫ 토큰 변경 금지
// - 띄어쓰기, 조사, 어순만 자연스럽게
public enum PostEditPrompt {
    public static func system(style: TranslationStyle) -> String {
        """
        역할: 한국어 문장 후편집기.
        지침: 의미/사실/수치/날짜/명사구/고유명사/URL/기호/⟪Gk⟫ 토큰은 절대 변경하지 말 것.
        목표: 띄어쓰기/조사/어순/부드러움만 개선. 문장 수는 유지.
        출력: 입력과 동일한 언어(한국어)로만, 장식 없이.
        """
    }
    public static let userPrefix = "다음 문장을 자연스럽게 다듬어줘:\n"
}
