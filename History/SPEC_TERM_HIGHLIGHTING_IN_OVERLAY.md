# SPEC: 오버레이 패널 용어 하이라이팅

- **작성일**: 2025-01-22
- **최종 수정**: 2025-01-22
- **상태**: Planning
- **우선순위**: P2
- **관련 TODO**: `TODO.md > 오버레이 패널 기능 확장 > 감지된 용어/마스킹·정규화 결과를 원문/번역문에 색상 표시`

---

## 1. 개요

### 1.1 목적
오버레이 패널에서 감지된 용어와 마스킹/정규화 결과를 시각적으로 구분하여 사용자가 번역 과정에서 어떤 용어가 어떻게 처리되었는지 직관적으로 파악할 수 있도록 한다.

### 1.2 범위
- **원문(selectedText)**: 감지된 용어를 마스킹/정규화 타입별로 색상 표시
- **최종 번역(primaryFinalText)**: 마스킹/정규화가 적용된 위치를 색상 표시
- **정규화 전 번역(primaryPreNormalizedText)**: 정규화 전 상태의 용어를 색상 표시
- **다른 엔진 번역들(translations)**: 각 엔진별 번역 결과의 용어 색상 표시

### 1.3 핵심 요구사항
1. **색상 구분**:
   - 마스킹 대상 용어(preMask=true): **파란색 배경**
   - 정규화 대상 용어(preMask=false): **초록색 배경**
   - 글자색은 유지, 배경색만 적용
2. **적용 범위**: 오버레이 패널의 모든 텍스트 섹션
3. **디버그 모드 독립성**: 디버그 모드와 무관하게 항상 표시
4. **정확한 range 추적**: 마스킹/정규화 과정에서 실제 적용된 위치 정보 보존

---

## 2. 배경 및 동기

### 2.1 현재 상태
- ✅ **완료**: 정규화 전/후 원문 노출 (디버그 모드 플래그 제어)
- ❌ **미구현**: 용어 하이라이팅 (본 스펙의 대상)
- ❌ **미구현**: 번역 결과를 Term variants로 추가 (향후 작업)

### 2.2 문제점
현재 오버레이 패널은 원문과 번역문을 단순 텍스트로 표시하여:
1. **용어 감지 여부 불명확**: 어떤 단어가 용어로 인식되었는지 알 수 없음
2. **처리 방식 불명확**: 마스킹/정규화 중 어느 방식이 적용되었는지 구분 불가
3. **번역 과정 불투명**: 번역 엔진이 실제로 받은 입력과 출력의 변환 과정 불가시
4. **디버깅 어려움**: 용어 관련 번역 오류 발생 시 원인 파악 곤란

### 2.3 기대 효과
1. **번역 과정 가시화**: 용어 처리 과정을 시각적으로 확인
2. **번역 품질 검증**: 용어가 의도대로 번역되었는지 즉시 확인
3. **Glossary 개선**: 잘못된 용어 매칭 발견 및 수정 용이
4. **사용자 이해도 향상**: 번역 시스템의 동작 원리 직관적 파악

---

## 3. 데이터 모델 변경

### 3.1 SegmentPieces 확장

#### 현재 구조
```swift
public struct SegmentPieces: Sendable {
    public let segmentID: String
    public let pieces: [Piece]

    public enum Piece: Sendable {
        case text(String)
        case term(GlossaryEntry)
    }
}
```

#### 문제점
- **Range 정보 없음**: Piece가 원문 텍스트의 어느 위치에 있는지 알 수 없음
- **순차 접근만 가능**: 특정 위치의 term을 찾기 어려움

#### 제안: Range 정보 추가
```swift
public struct SegmentPieces: Sendable {
    public let segmentID: String
    public let pieces: [Piece]
    public let originalText: String  // 원본 텍스트 보존

    public enum Piece: Sendable {
        case text(String, range: Range<String.Index>)
        case term(GlossaryEntry, range: Range<String.Index>)
    }

    // 새로운 헬퍼 메서드
    public func termRanges(preMask: Bool? = nil) -> [(entry: GlossaryEntry, range: Range<String.Index>)] {
        pieces.compactMap { piece in
            guard case let .term(entry, range) = piece else { return nil }
            if let filterPreMask = preMask, entry.preMask != filterPreMask {
                return nil
            }
            return (entry, range)
        }
    }
}
```

**주의**: 이 변경은 `SPEC_SEGMENT_PIECES_REFACTORING.md`의 Phase 7과 연관됨. 해당 스펙이 먼저 구현되면 본 스펙의 구현이 단순해질 수 있음.

### 3.2 TranslationStreamPayload 확장

#### 현재 구조
```swift
public struct TranslationStreamPayload: Sendable {
    public let segmentID: String
    public let engineID: String
    public let originalText: String
    public let translatedText: String?
    public let preNormalizedText: String?
    // ...
}
```

#### 제안: 하이라이팅 메타데이터 추가
```swift
public struct TranslationStreamPayload: Sendable {
    public let segmentID: String
    public let engineID: String
    public let originalText: String
    public let translatedText: String?
    public let preNormalizedText: String?

    // 새로운 필드: 하이라이팅 정보
    public let highlightMetadata: TermHighlightMetadata?

    // ...
}

public struct TermHighlightMetadata: Sendable, Equatable {
    /// 원문의 용어 위치 (SegmentPieces 기반)
    public let originalTermRanges: [TermRange]

    /// 최종 번역문의 용어 위치 (정규화 후)
    public let finalTermRanges: [TermRange]

    /// 정규화 전 번역문의 용어 위치 (있는 경우)
    public let preNormalizedTermRanges: [TermRange]?
}

public struct TermRange: Sendable, Equatable, Hashable {
    public let entry: GlossaryEntry
    public let range: Range<String.Index>
    public let type: TermType

    public enum TermType: Sendable, Equatable {
        case masked      // preMask = true
        case normalized  // preMask = false
    }
}
```

### 3.3 OverlayState 확장

#### 현재 구조
```swift
struct OverlayState: Equatable {
    var segmentID: String
    var selectedText: String
    var improvedText: String?
    var anchor: CGRect
    var primaryEngineTitle: String
    var primaryFinalText: String?
    var primaryPreNormalizedText: String?
    var translations: [Translation]
    var showsOriginalSection: Bool
}
```

#### 제안: 하이라이팅 정보 추가
```swift
struct OverlayState: Equatable {
    var segmentID: String
    var selectedText: String
    var improvedText: String?
    var anchor: CGRect
    var primaryEngineTitle: String
    var primaryFinalText: String?
    var primaryPreNormalizedText: String?
    var translations: [Translation]
    var showsOriginalSection: Bool

    // 새로운 필드
    var primaryHighlightMetadata: TermHighlightMetadata?
    var translationsHighlightMetadata: [String: TermHighlightMetadata]?  // engineID -> metadata
}
```

---

## 4. 새로운 타입 설계

### 4.1 HighlightedText (UI용 래퍼)

```swift
/// NSAttributedString을 SwiftUI에서 사용하기 위한 래퍼
public struct HighlightedText: Equatable {
    public let plainText: String
    public let attributedString: NSAttributedString

    public init(text: String, highlights: [TermRange]) {
        self.plainText = text
        self.attributedString = Self.buildAttributedString(text: text, highlights: highlights)
    }

    private static func buildAttributedString(text: String, highlights: [TermRange]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)

        for highlight in highlights {
            let nsRange = NSRange(highlight.range, in: text)
            let backgroundColor: UIColor = switch highlight.type {
            case .masked:
                UIColor.systemBlue.withAlphaComponent(0.3)  // 파란색 배경
            case .normalized:
                UIColor.systemGreen.withAlphaComponent(0.3) // 초록색 배경
            }

            attributed.addAttribute(.backgroundColor, value: backgroundColor, range: nsRange)
        }

        return attributed
    }

    public static func == (lhs: HighlightedText, rhs: HighlightedText) -> Bool {
        lhs.plainText == rhs.plainText && lhs.attributedString.isEqual(to: rhs.attributedString)
    }
}
```

### 4.2 AttributedTextView (UIKit 래퍼)

```swift
import SwiftUI
import UIKit

/// NSAttributedString을 표시하는 SwiftUI View
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
        textView.font = .systemFont(ofSize: 15)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = attributedText
        textView.isSelectable = isSelectable
    }
}
```

---

## 5. 서비스 계층 수정

### 5.1 TermMasker 수정: Range 추적

#### 현재 구현 (간소화)
```swift
// DefaultTermMasker.swift
func maskFromPieces(_ pieces: SegmentPieces, tokenizer: Tokenizer) -> (masked: String, order: [String]) {
    var result = ""
    var order: [String] = []

    for piece in pieces.pieces {
        switch piece {
        case .text(let str):
            result += str
        case .term(let entry) where entry.preMask:
            let token = generateToken(for: entry)
            result += token
            order.append(token)
        case .term(let entry):
            result += entry.source  // 정규화 대상은 그대로
        }
    }

    return (result, order)
}
```

#### 제안: Range 정보 추적
```swift
func maskFromPieces(_ pieces: SegmentPieces, tokenizer: Tokenizer)
    -> (masked: String, order: [String], ranges: [TermRange]) {

    var result = ""
    var order: [String] = []
    var ranges: [TermRange] = []

    for piece in pieces.pieces {
        switch piece {
        case .text(let str, _):
            result += str

        case .term(let entry, let originalRange) where entry.preMask:
            let token = generateToken(for: entry)
            let startIndex = result.endIndex
            result += token
            let endIndex = result.endIndex

            order.append(token)
            ranges.append(TermRange(
                entry: entry,
                range: startIndex..<endIndex,
                type: .masked
            ))

        case .term(let entry, _):
            let startIndex = result.endIndex
            result += entry.source
            let endIndex = result.endIndex

            ranges.append(TermRange(
                entry: entry,
                range: startIndex..<endIndex,
                type: .normalized
            ))
        }
    }

    return (result, order, ranges)
}
```

### 5.2 Normalization Range 추적

#### 제안: normalizeWithOrder 수정
```swift
func normalizeWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    tokenizer: Tokenizer
) -> (normalized: String, order: [NormalizationEntry], ranges: [TermRange]) {

    var normalized = text
    var order: [NormalizationEntry] = []
    var ranges: [TermRange] = []

    let unmaskedTerms = pieces.unmaskedTerms()

    for entry in unmaskedTerms {
        let variantsToNormalize = entry.variants.filter { variant in
            normalized.contains(variant)
        }

        for variant in variantsToNormalize {
            var searchStartIndex = normalized.startIndex

            while let range = normalized.range(of: variant, range: searchStartIndex..<normalized.endIndex) {
                let beforeLength = normalized.distance(from: normalized.startIndex, to: range.lowerBound)

                normalized.replaceSubrange(range, with: entry.target)

                // 교체 후 range 계산
                let newStartIndex = normalized.index(normalized.startIndex, offsetBy: beforeLength)
                let newEndIndex = normalized.index(newStartIndex, offsetBy: entry.target.count)

                ranges.append(TermRange(
                    entry: entry,
                    range: newStartIndex..<newEndIndex,
                    type: .normalized
                ))

                order.append(NormalizationEntry(
                    original: variant,
                    normalized: entry.target,
                    entry: entry
                ))

                searchStartIndex = newEndIndex
            }
        }
    }

    return (normalized, order, ranges)
}
```

### 5.3 Unmask Range 추적

#### 제안: unmaskWithOrder 수정
```swift
func unmaskWithOrder(
    _ text: String,
    order: [String],
    entries: [String: GlossaryEntry]
) -> (unmasked: String, ranges: [TermRange]) {

    var result = text
    var ranges: [TermRange] = []

    for token in order.reversed() {
        guard let entry = entries[token] else { continue }

        var searchStartIndex = result.startIndex

        while let range = result.range(of: token, range: searchStartIndex..<result.endIndex) {
            let beforeLength = result.distance(from: result.startIndex, to: range.lowerBound)

            result.replaceSubrange(range, with: entry.target)

            // 교체 후 range 계산
            let newStartIndex = result.index(result.startIndex, offsetBy: beforeLength)
            let newEndIndex = result.index(newStartIndex, offsetBy: entry.target.count)

            ranges.append(TermRange(
                entry: entry,
                range: newStartIndex..<newEndIndex,
                type: .masked
            ))

            searchStartIndex = newEndIndex
        }
    }

    return (result, ranges)
}
```

### 5.4 TranslationRouter 수정

#### 제안: TermHighlightMetadata 생성 및 전달
```swift
// DefaultTranslationRouter.swift
func handleTranslationStream(...) async {
    // ... 기존 코드 ...

    // 1. 원문의 용어 range 추출
    let originalTermRanges = pieces.pieces.compactMap { piece -> TermRange? in
        guard case let .term(entry, range) = piece else { return nil }
        return TermRange(
            entry: entry,
            range: range,
            type: entry.preMask ? .masked : .normalized
        )
    }

    // 2. 마스킹/정규화 처리 with range tracking
    let (maskedInput, maskOrder, maskedRanges) = termMasker.maskFromPieces(pieces, tokenizer: tokenizer)

    // 3. 번역 실행
    let rawTranslation = await translateEngine.translate(maskedInput)

    // 4. 정규화 with range tracking
    let (preNormalizedText, normOrder, normRanges) = termMasker.normalizeWithOrder(
        rawTranslation,
        pieces: pieces,
        tokenizer: tokenizer
    )

    // 5. 언마스킹 with range tracking
    let (finalText, unmaskRanges) = termMasker.unmaskWithOrder(
        preNormalizedText,
        order: maskOrder,
        entries: maskEntries
    )

    // 6. 정규화 전 번역의 range (언마스킹만 적용)
    let (preNormWithUnmask, preNormRanges) = termMasker.unmaskWithOrder(
        rawTranslation,
        order: maskOrder,
        entries: maskEntries
    )

    // 7. TermHighlightMetadata 생성
    let highlightMetadata = TermHighlightMetadata(
        originalTermRanges: originalTermRanges,
        finalTermRanges: unmaskRanges + normRanges,  // 언마스킹 + 정규화
        preNormalizedTermRanges: preNormRanges
    )

    // 8. Payload에 포함
    let payload = TranslationStreamPayload(
        segmentID: segmentID,
        engineID: engineID,
        originalText: pieces.originalText,
        translatedText: finalText,
        preNormalizedText: preNormWithUnmask,
        highlightMetadata: highlightMetadata,
        // ...
    )

    await eventStream.send(payload)
}
```

---

## 6. UI 설계

### 6.1 TranslationSectionView 수정

#### 현재 구현
```swift
struct TranslationSectionView: View {
    let title: String
    let text: String?
    let isSelectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let text = text {
                SelectableTextView(text: text, isSelectable: isSelectable)
            } else {
                Text("(번역 중...)")
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
}
```

#### 제안: HighlightedText 지원
```swift
struct TranslationSectionView: View {
    let title: String
    let content: SectionContent
    let isSelectable: Bool

    enum SectionContent {
        case plain(String?)
        case highlighted(HighlightedText?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch content {
            case .plain(let text):
                if let text = text {
                    SelectableTextView(text: text, isSelectable: isSelectable)
                } else {
                    emptyView
                }

            case .highlighted(let highlightedText):
                if let highlightedText = highlightedText {
                    AttributedTextView(highlightedText, isSelectable: isSelectable)
                } else {
                    emptyView
                }
            }
        }
    }

    private var emptyView: some View {
        Text("(번역 중...)")
            .foregroundStyle(.secondary)
            .italic()
    }
}
```

### 6.2 OverlayPanelView 수정

#### 제안: 하이라이팅 적용
```swift
struct OverlayPanelView: View {
    let state: OverlayState
    let onTranslationEngineChange: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            // 1. 원문 섹션 (항상 표시)
            if state.showsOriginalSection {
                TranslationSectionView(
                    title: "원문",
                    content: .highlighted(originalHighlightedText),
                    isSelectable: true
                )
            }

            Divider()

            // 2. 최종 번역 섹션
            TranslationSectionView(
                title: state.primaryEngineTitle,
                content: .highlighted(finalHighlightedText),
                isSelectable: true
            )

            // 3. 정규화 전 번역 섹션 (디버그 모드)
            if isDebugModeEnabled {
                TranslationSectionView(
                    title: "\(state.primaryEngineTitle) 정규화 전",
                    content: .highlighted(preNormalizedHighlightedText),
                    isSelectable: true
                )
            }

            // 4. 다른 엔진 번역들
            ForEach(state.translations) { translation in
                Divider()
                TranslationSectionView(
                    title: translation.engineTitle,
                    content: .highlighted(translationHighlightedText(for: translation)),
                    isSelectable: true
                )
            }
        }
    }

    // MARK: - Highlighted Text Builders

    private var originalHighlightedText: HighlightedText? {
        guard let metadata = state.primaryHighlightMetadata else {
            return HighlightedText(text: state.selectedText, highlights: [])
        }
        return HighlightedText(
            text: state.selectedText,
            highlights: metadata.originalTermRanges
        )
    }

    private var finalHighlightedText: HighlightedText? {
        guard let text = state.primaryFinalText,
              let metadata = state.primaryHighlightMetadata else {
            return state.primaryFinalText.map { HighlightedText(text: $0, highlights: []) }
        }
        return HighlightedText(
            text: text,
            highlights: metadata.finalTermRanges
        )
    }

    private var preNormalizedHighlightedText: HighlightedText? {
        guard let text = state.primaryPreNormalizedText,
              let metadata = state.primaryHighlightMetadata,
              let ranges = metadata.preNormalizedTermRanges else {
            return state.primaryPreNormalizedText.map { HighlightedText(text: $0, highlights: []) }
        }
        return HighlightedText(
            text: text,
            highlights: ranges
        )
    }

    private func translationHighlightedText(for translation: Translation) -> HighlightedText? {
        guard let text = translation.text else { return nil }

        guard let metadata = state.translationsHighlightMetadata?[translation.engineID] else {
            return HighlightedText(text: text, highlights: [])
        }

        return HighlightedText(
            text: text,
            highlights: metadata.finalTermRanges
        )
    }
}
```

### 6.3 색상 정의

```swift
extension UIColor {
    static let termMaskedBackground = UIColor.systemBlue.withAlphaComponent(0.3)
    static let termNormalizedBackground = UIColor.systemGreen.withAlphaComponent(0.3)
}

extension TermRange.TermType {
    var backgroundColor: UIColor {
        switch self {
        case .masked:
            return .termMaskedBackground
        case .normalized:
            return .termNormalizedBackground
        }
    }
}
```

---

## 7. 구현 계획

### Phase 1: 인프라 구축 (Range 추적)
**목표**: SegmentPieces와 TermMasker에 range 정보 추가

#### 작업 항목
- [ ] `SegmentPieces.Piece`에 `range: Range<String.Index>` 추가
- [ ] `SegmentPieces.originalText` 필드 추가
- [ ] `TermMasker.buildSegmentPieces` 수정하여 range 계산
- [ ] `TermRange` 타입 정의
- [ ] `TermHighlightMetadata` 타입 정의
- [ ] 단위 테스트: SegmentPieces range 정확성 검증

**예상 소요**: 4-6시간

**위험 요소**:
- `String.Index` 계산 복잡도 (UTF-8/UTF-16 경계 문제)
- 기존 SegmentPieces 사용처 모두 수정 필요
- SPEC_SEGMENT_PIECES_REFACTORING.md와 충돌 가능성

### Phase 2: 서비스 계층 Range 전파
**목표**: 마스킹/정규화/언마스킹 과정에서 range 정보 유지

#### 작업 항목
- [ ] `maskFromPieces` → range 추적 반환
- [ ] `normalizeWithOrder` → range 추적 반환
- [ ] `unmaskWithOrder` → range 추적 반환
- [ ] `TranslationStreamPayload.highlightMetadata` 필드 추가
- [ ] `DefaultTranslationRouter`에서 metadata 생성 및 전달
- [ ] 단위 테스트: 각 변환 단계별 range 정확성

**예상 소요**: 6-8시간

**주의사항**:
- 문자열 교체 시 range 재계산 정확성 중요
- Reversed order unmask 시 range 계산 복잡도
- Multi-occurrence 용어 처리 (같은 용어가 여러 번 나타날 때)

### Phase 3: UI 렌더링
**목표**: AttributedTextView로 색상 표시

#### 작업 항목
- [ ] `HighlightedText` 타입 구현
- [ ] `AttributedTextView` UIViewRepresentable 구현
- [ ] `TranslationSectionView.SectionContent` enum 추가
- [ ] `OverlayPanelView`에 하이라이팅 적용
- [ ] `OverlayState.primaryHighlightMetadata` 필드 추가
- [ ] `BrowserViewModel`에서 metadata 전달
- [ ] UI 테스트: 색상 표시 확인

**예상 소요**: 4-6시간

**주의사항**:
- `NSAttributedString` ↔ SwiftUI 통합
- Dark mode 대응 (색상 alpha 조정)
- 텍스트 선택 기능 유지

### Phase 4: 다른 엔진 번역 지원
**목표**: 주 엔진 외 다른 엔진들도 하이라이팅 적용

#### 작업 항목
- [ ] `OverlayState.translationsHighlightMetadata` 추가
- [ ] 각 엔진별 metadata 생성 및 저장
- [ ] UI에서 엔진별 metadata 사용
- [ ] 통합 테스트

**예상 소요**: 2-3시간

### Phase 5: 테스트 및 최적화
**목표**: 엣지 케이스 처리 및 성능 최적화

#### 작업 항목
- [ ] 엣지 케이스 테스트 (아래 9절 참조)
- [ ] 성능 프로파일링 (AttributedString 생성 비용)
- [ ] 메모리 사용량 모니터링
- [ ] 문서화

**예상 소요**: 3-4시간

---

## 8. 전체 플로우

### 8.1 데이터 흐름 다이어그램

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Term Detection (TermMasker.buildSegmentPieces)                  │
│                                                                     │
│  Input: "Hello, 최강자님! Nice to meet you."                       │
│  Glossary: [최강자 → Choigangja (preMask=true)]                    │
│                                                                     │
│  Output: SegmentPieces {                                           │
│    pieces: [                                                       │
│      .text("Hello, ", range: 0..<7)                               │
│      .term(최강자, range: 7..<10)  // preMask=true                │
│      .text("님! Nice to meet you.", range: 10..<32)               │
│    ]                                                               │
│    originalTermRanges: [(최강자, 7..<10, .masked)]                │
│  }                                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. Masking (TermMasker.maskFromPieces)                             │
│                                                                     │
│  Input: SegmentPieces (위)                                         │
│                                                                     │
│  Output: {                                                         │
│    masked: "Hello, __E#001__님! Nice to meet you."                │
│    order: ["__E#001__"]                                            │
│    ranges: [(최강자, 7..<16, .masked)]  // 토큰으로 교체된 range   │
│  }                                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. Translation (Engine)                                             │
│                                                                     │
│  Input: "Hello, __E#001__님! Nice to meet you."                    │
│                                                                     │
│  Output: "안녕하세요, __E#001__님! 만나서 반가워요."                │
│                                                                     │
│  (Range 정보는 이 단계에서 변경됨 - 추적 불가)                      │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4a. Normalization (TermMasker.normalizeWithOrder)                  │
│                                                                     │
│  Input: "안녕하세요, __E#001__님! 만나서 반가워요."                 │
│  (이 예시에는 정규화 대상 용어 없음)                                │
│                                                                     │
│  Output: {                                                         │
│    normalized: "안녕하세요, __E#001__님! 만나서 반가워요."          │
│    order: []                                                       │
│    ranges: []                                                      │
│  }                                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4b. Unmasking (TermMasker.unmaskWithOrder)                         │
│                                                                     │
│  Input: "안녕하세요, __E#001__님! 만나서 반가워요."                 │
│  Order: ["__E#001__" → 최강자 entry]                               │
│                                                                     │
│  Output: {                                                         │
│    unmasked: "안녕하세요, Choigangja님! 만나서 반가워요."           │
│    ranges: [(최강자, 7..<17, .masked)]  // Choigangja 위치         │
│  }                                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. Metadata 생성 (TranslationRouter)                               │
│                                                                     │
│  TermHighlightMetadata {                                           │
│    originalTermRanges: [(최강자, 7..<10, .masked)]                 │
│    finalTermRanges: [(최강자, 7..<17, .masked)]                    │
│    preNormalizedTermRanges: [(최강자, 7..<17, .masked)]            │
│  }                                                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. UI 렌더링 (OverlayPanel)                                        │
│                                                                     │
│  원문: "Hello, [최강자]님! Nice to meet you."                      │
│         (7..<10 = 파란 배경)                                       │
│                                                                     │
│  최종 번역: "안녕하세요, [Choigangja]님! 만나서 반가워요."          │
│            (7..<17 = 파란 배경)                                    │
│                                                                     │
│  정규화 전: "안녕하세요, [Choigangja]님! 만나서 반가워요."          │
│            (7..<17 = 파란 배경)                                    │
└─────────────────────────────────────────────────────────────────────┘
```

### 8.2 정규화 포함 예시

```
원문: "My favorite color is grey, I love grey things."
Glossary: [grey → gray (preMask=false, variants={grey})]

1. SegmentPieces:
   pieces: [
     .text("My favorite color is ", 0..<22)
     .term(grey entry, 22..<26)  // "grey"
     .text(", I love ", 26..<36)
     .term(grey entry, 36..<40)  // "grey"
     .text(" things.", 40..<48)
   ]
   originalTermRanges: [
     (grey, 22..<26, .normalized),
     (grey, 36..<40, .normalized)
   ]

2. Masking: (preMask=false이므로 스킵)
   masked: "My favorite color is grey, I love grey things."
   ranges: []

3. Translation:
   "내가 가장 좋아하는 색은 grey이고, grey한 것들을 좋아한다."

4. Normalization:
   normalized: "내가 가장 좋아하는 색은 gray이고, gray한 것들을 좋아한다."
   ranges: [
     (grey, 14..<18, .normalized),  // "gray" (첫 번째)
     (grey, 22..<26, .normalized)   // "gray" (두 번째)
   ]

5. UI:
   원문: "My favorite color is [grey], I love [grey] things."
          (22..<26, 36..<40 = 초록 배경)

   최종 번역: "내가 가장 좋아하는 색은 [gray]이고, [gray]한 것들을 좋아한다."
             (14..<18, 22..<26 = 초록 배경)
```

---

## 9. 테스트 전략

### 9.1 단위 테스트

#### SegmentPieces Range 정확성
```swift
func testSegmentPiecesRangeAccuracy() {
    let text = "Hello 최강자님, welcome!"
    let glossary = [makeEntry(source: "최강자", target: "Choigangja", preMask: true)]

    let pieces = termMasker.buildSegmentPieces(text: text, glossary: glossary)

    XCTAssertEqual(pieces.pieces.count, 3)

    guard case let .text(str1, range1) = pieces.pieces[0] else { XCTFail(); return }
    XCTAssertEqual(str1, "Hello ")
    XCTAssertEqual(text[range1], "Hello ")

    guard case let .term(entry, range2) = pieces.pieces[1] else { XCTFail(); return }
    XCTAssertEqual(entry.source, "최강자")
    XCTAssertEqual(text[range2], "최강자")

    guard case let .text(str3, range3) = pieces.pieces[2] else { XCTFail(); return }
    XCTAssertEqual(str3, "님, welcome!")
    XCTAssertEqual(text[range3], "님, welcome!")
}
```

#### Masking Range 추적
```swift
func testMaskingRangeTracking() {
    let pieces = makeSegmentPieces(
        text: "Hello 최강자님",
        terms: [(source: "최강자", target: "Choigangja", preMask: true, range: 6..<9)]
    )

    let (masked, order, ranges) = termMasker.maskFromPieces(pieces, tokenizer: tokenizer)

    XCTAssertEqual(masked, "Hello __E#001__님")
    XCTAssertEqual(ranges.count, 1)

    let termRange = ranges[0]
    XCTAssertEqual(termRange.type, .masked)
    XCTAssertEqual(masked[termRange.range], "__E#001__")
}
```

#### Normalization Range 추적
```swift
func testNormalizationRangeTracking() {
    let pieces = makeSegmentPieces(
        text: "I love grey and grey",
        terms: [
            (source: "grey", target: "gray", preMask: false, range: 7..<11),
            (source: "grey", target: "gray", preMask: false, range: 16..<20)
        ]
    )

    let translation = "나는 grey와 grey를 좋아함"

    let (normalized, order, ranges) = termMasker.normalizeWithOrder(
        translation,
        pieces: pieces,
        tokenizer: tokenizer
    )

    XCTAssertEqual(normalized, "나는 gray와 gray를 좋아함")
    XCTAssertEqual(ranges.count, 2)

    XCTAssertEqual(ranges[0].type, .normalized)
    XCTAssertEqual(normalized[ranges[0].range], "gray")

    XCTAssertEqual(ranges[1].type, .normalized)
    XCTAssertEqual(normalized[ranges[1].range], "gray")
}
```

#### Unmask Range 추적
```swift
func testUnmaskRangeTracking() {
    let entries = [
        "__E#001__": makeEntry(source: "최강자", target: "Choigangja", preMask: true),
        "__E#002__": makeEntry(source: "용사", target: "Yongsa", preMask: true)
    ]

    let text = "안녕 __E#001__님과 __E#002__님"
    let order = ["__E#001__", "__E#002__"]

    let (unmasked, ranges) = termMasker.unmaskWithOrder(text, order: order, entries: entries)

    XCTAssertEqual(unmasked, "안녕 Choigangja님과 Yongsa님")
    XCTAssertEqual(ranges.count, 2)

    XCTAssertEqual(unmasked[ranges[0].range], "Choigangja")
    XCTAssertEqual(unmasked[ranges[1].range], "Yongsa")
}
```

### 9.2 통합 테스트

#### End-to-End 하이라이팅
```swift
func testEndToEndHighlighting() async {
    let text = "Hello 최강자님, grey is nice."
    let glossary = [
        makeEntry(source: "최강자", target: "Choigangja", preMask: true),
        makeEntry(source: "grey", target: "gray", preMask: false, variants: ["grey"])
    ]

    let router = DefaultTranslationRouter(...)
    let payload = await router.translate(text: text, glossary: glossary)

    XCTAssertNotNil(payload.highlightMetadata)

    let metadata = payload.highlightMetadata!

    // 원문 하이라이팅
    XCTAssertEqual(metadata.originalTermRanges.count, 2)
    XCTAssertTrue(metadata.originalTermRanges.contains { $0.type == .masked })
    XCTAssertTrue(metadata.originalTermRanges.contains { $0.type == .normalized })

    // 최종 번역 하이라이팅
    XCTAssertEqual(metadata.finalTermRanges.count, 2)

    // 정규화 전 번역 하이라이팅
    XCTAssertNotNil(metadata.preNormalizedTermRanges)
}
```

### 9.3 UI 테스트

#### AttributedTextView 렌더링
```swift
func testAttributedTextViewRendering() {
    let text = "Hello Choigangja님"
    let ranges = [
        TermRange(
            entry: makeEntry(source: "최강자", target: "Choigangja", preMask: true),
            range: text.index(text.startIndex, offsetBy: 6)..<text.index(text.startIndex, offsetBy: 16),
            type: .masked
        )
    ]

    let highlighted = HighlightedText(text: text, highlights: ranges)

    XCTAssertEqual(highlighted.plainText, text)

    let attributed = highlighted.attributedString
    let nsRange = NSRange(location: 6, length: 10)

    let bgColor = attributed.attribute(.backgroundColor, at: 6, effectiveRange: nil) as? UIColor
    XCTAssertNotNil(bgColor)
    XCTAssertEqual(bgColor, UIColor.systemBlue.withAlphaComponent(0.3))
}
```

### 9.4 엣지 케이스

#### 중복 용어
```swift
func testMultipleOccurrencesOfSameTerm() {
    let text = "grey grey grey"
    // 모든 "grey" 위치가 정확히 추적되는지 확인
}
```

#### 용어 중첩 (긴 용어가 짧은 용어 포함)
```swift
func testNestedTerms() {
    let text = "최강의 최강자"
    let glossary = [
        makeEntry(source: "최강자", target: "Choigangja", preMask: true),
        makeEntry(source: "최강", target: "Choigang", preMask: false)
    ]
    // filterBySourceOcc에 의해 짧은 용어가 제거되므로 range 충돌 없음
}
```

#### 빈 문자열/nil 처리
```swift
func testEmptyTextHighlighting() {
    let highlighted = HighlightedText(text: "", highlights: [])
    XCTAssertEqual(highlighted.plainText, "")
}

func testNilTextInOverlay() {
    let state = OverlayState(
        // ...
        primaryFinalText: nil,
        primaryHighlightMetadata: nil
    )
    // UI가 크래시 없이 "(번역 중...)" 표시하는지 확인
}
```

#### Emoji/특수문자
```swift
func testEmojiInText() {
    let text = "Hello 👋 최강자님 😊"
    // String.Index가 정확히 계산되는지 (UTF-16 경계)
}
```

#### 정규화 없는 마스킹만
```swift
func testMaskingOnlyNoNormalization() {
    let glossary = [
        makeEntry(source: "최강자", target: "Choigangja", preMask: true)
    ]
    // normRanges가 빈 배열이어도 정상 동작
}
```

#### 마스킹 없는 정규화만
```swift
func testNormalizationOnlyNoMasking() {
    let glossary = [
        makeEntry(source: "grey", target: "gray", preMask: false, variants: ["grey"])
    ]
    // maskRanges가 빈 배열이어도 정상 동작
}
```

---

## 10. 성능 고려사항

### 10.1 NSAttributedString 생성 비용
**문제**: 매 렌더링마다 AttributedString 생성 시 성능 저하 가능

**해결책**:
1. **캐싱**: `HighlightedText` 생성 시 Equatable 구현으로 SwiftUI 자동 캐싱 활용
2. **Lazy 생성**: 섹션이 접혀있을 때는 생성 지연
3. **프로파일링**: Instruments로 실제 병목 확인 후 최적화

### 10.2 Range 계산 복잡도
**문제**: String.Index 계산이 O(n) (UTF-8 경계 탐색)

**해결책**:
1. **사전 계산**: SegmentPieces 생성 시 한 번만 계산
2. **NSRange 변환 최소화**: 필요 시점에만 변환
3. **Substring 재사용**: 불필요한 String 복사 방지

### 10.3 메모리 사용량
**문제**: 모든 번역 결과마다 metadata 보존 시 메모리 증가

**현황**:
- SegmentPieces: 이미 메모리 상주 중
- TermRange 배열: 용어당 ~100 bytes
- 일반적인 세그먼트: 0-5개 용어 → ~500 bytes 추가

**결론**: 메모리 영향 미미, 최적화 불필요

### 10.4 렌더링 성능
**측정 기준**:
- 오버레이 패널 열림 시간: < 100ms
- AttributedString 생성 시간: < 10ms per section
- 스크롤 프레임레이트: 60fps 유지

**최적화 전략**:
- Phase 5에서 프로파일링 후 필요 시 최적화
- 현재는 MVP 구현 우선

---

## 11. 통합 시 주의사항

### 11.1 SPEC_SEGMENT_PIECES_REFACTORING.md 연계
**충돌 가능성**:
- 본 스펙의 Phase 1 (SegmentPieces에 range 추가)는 SPEC_SEGMENT_PIECES_REFACTORING.md의 Phase 7과 중복

**해결책**:
1. **Option A**: SPEC_SEGMENT_PIECES_REFACTORING을 먼저 완료하면 본 스펙의 Phase 1 생략 가능
2. **Option B**: 본 스펙을 먼저 구현하되, 추후 SPEC_SEGMENT_PIECES_REFACTORING과 병합 시 refactoring

**권장**: 독립적으로 진행 가능하도록 본 스펙 내에서 최소한의 SegmentPieces 수정만 진행

### 11.2 기존 코드 영향 범위
**수정 필요 파일**:
- `SegmentPieces.swift`: Piece enum에 range 추가
- `DefaultTermMasker.swift`: 모든 메서드에 range 추적 추가
- `TranslationStreamPayload.swift`: highlightMetadata 필드 추가
- `DefaultTranslationRouter.swift`: metadata 생성 로직 추가
- `BrowserViewModel+State.swift`: OverlayState에 metadata 필드 추가
- `OverlayPanel.swift`: UI 수정

**영향 받는 테스트**:
- SegmentPieces 관련 모든 테스트 (case matching 변경으로 인한 컴파일 오류)

**마이그레이션 전략**:
1. SegmentPieces 변경은 additive (기존 case에 associated value 추가)
2. 모든 switch 문에 range 바인딩 추가 필요
3. 컴파일러 경고를 가이드로 점진적 수정

### 11.3 버전 관리
**Git 전략**:
1. Feature branch: `feature/term-highlighting-in-overlay`
2. 커밋 단위: Phase별로 커밋 분리
3. PR 크기: 가능하면 Phase별로 개별 PR (리뷰 용이성)

---

## 12. 향후 확장 가능성

### 12.1 인터랙티브 하이라이팅
- **용어 클릭 시 상세 정보 표시**: Glossary entry 전체 정보 팝업
- **hover 효과**: 마우스 오버 시 source ↔ target 매핑 표시

### 12.2 색상 커스터마이징
- **사용자 설정**: Settings에서 마스킹/정규화 색상 변경 가능
- **다크 모드 대응**: 배경색 alpha 자동 조정

### 12.3 하이라이팅 토글
- **UI 토글 버튼**: 하이라이팅 on/off 전환
- **DebugConfig 연동**: 디버그 모드에서만 표시하는 옵션 추가

### 12.4 번역 결과 → Glossary 추가
(TODO 항목 3번과 연계)
- **텍스트 선택 → 용어 추가 플로우**
- 하이라이팅된 용어를 선택하여 variants 추가 기능

---

## 13. 참고 문서

- `SPEC_SEGMENT_PIECES_REFACTORING.md`: SegmentPieces 리팩토링 (Phase 7: Range 정보 추가)
- `SPEC_TERM_ACTIVATION.md`: 용어 활성화 시스템
- `SPEC_ORDER_BASED_NORMALIZATION.md`: 순서 기반 정규화
- `TODO.md`: 오버레이 패널 기능 확장 항목
- `PROJECT_OVERVIEW.md`: 프로젝트 아키텍처

---

## 14. 체크리스트

### Phase 1: 인프라 구축
- [ ] SegmentPieces.Piece에 range 추가
- [ ] SegmentPieces.originalText 추가
- [ ] TermMasker.buildSegmentPieces range 계산
- [ ] TermRange 타입 정의
- [ ] TermHighlightMetadata 타입 정의
- [ ] 단위 테스트: SegmentPieces range

### Phase 2: 서비스 계층
- [ ] maskFromPieces range 추적
- [ ] normalizeWithOrder range 추적
- [ ] unmaskWithOrder range 추적
- [ ] TranslationStreamPayload.highlightMetadata
- [ ] DefaultTranslationRouter metadata 생성
- [ ] 단위 테스트: 각 변환 단계 range

### Phase 3: UI 렌더링
- [ ] HighlightedText 구현
- [ ] AttributedTextView 구현
- [ ] TranslationSectionView.SectionContent
- [ ] OverlayPanelView 하이라이팅 적용
- [ ] OverlayState metadata 필드
- [ ] BrowserViewModel metadata 전달
- [ ] UI 테스트

### Phase 4: 다른 엔진 지원
- [ ] OverlayState.translationsHighlightMetadata
- [ ] 엔진별 metadata 생성
- [ ] UI 엔진별 적용
- [ ] 통합 테스트

### Phase 5: 테스트 및 최적화
- [ ] 엣지 케이스 테스트
- [ ] 성능 프로파일링
- [ ] 메모리 모니터링
- [ ] 문서화

---

**문서 끝**
