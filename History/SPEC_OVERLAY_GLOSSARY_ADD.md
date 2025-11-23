# 스펙: 오버레이 패널 용어집 추가 기능

## 1. 개요

### 목표
사용자가 오버레이 패널에서 텍스트(원문 또는 번역문)를 선택했을 때, 컨텍스트 메뉴를 통해 바로 용어집에 용어를 추가하거나 기존 용어를 편집할 수 있는 기능을 제공한다.

### 핵심 요구사항
1. 오버레이 패널의 텍스트 부분 선택 지원
2. 컨텍스트 메뉴에 "용어집에 추가" 액션 추가
3. 화면 이동 없이 바텀시트/팝업으로 용어 추가/편집 UI 제공
4. 선택 컨텍스트(원문/번역문)에 따라 적절한 후보 제시 및 UI 분기
5. 취소 가능한 사용자 플로우

---

## 2. 사용자 플로우

### 2.1 번역 결과문 선택 시

```
사용자가 오버레이 패널의 번역 결과문(최종 또는 정규화 전) 일부를 선택
  ↓
컨텍스트 메뉴 표시: "용어집에 추가"
  ↓
사용자가 "용어집에 추가" 선택
  ↓
바텀시트 표시:
  - 선택한 번역문 표시
  - 매칭되지 않은 원문 용어 후보 제시 (우선순위 정렬)
  - 후보 선택 UI (드롭다운 Picker - 뷰 크기 효율적)
  - 또는 "새 용어 추가" 옵션
  ↓
[기존 용어 선택한 경우]
  - 바텀시트에서 선택한 용어의 기존 target, variants 표시
  - "이 용어에 variants 추가" 버튼 클릭
  - 바텀시트 닫기 → TermEditorView로 화면 전환
  - TermEditorView에 해당 용어 로드 + 선택한 번역문이 variants에 미리 추가됨
  - 사용자가 추가 편집 가능 (다른 variants 추가/수정, 기타 설정 변경)
  - "저장" 버튼 → SwiftData 업데이트
  ↓
[새 용어 추가 선택한 경우]
  - 바텀시트 내 원문 범위 선택 UI로 전환
  - 사용자가 전체 원문에서 텍스트 범위 선택 (인터랙티브 또는 수동 입력)
  - "다음" 버튼 클릭
  - 바텀시트 닫기 → TermEditorView로 화면 전환 (새 용어 추가 모드)
  - TermEditorView에 선택한 원문이 source에, 번역문이 variants에 미리 입력됨
  - 사용자가 target 및 추가 설정 (preMask, prohibitStandalone 등)
  - "저장" 버튼 → SwiftData에 새 Term 추가
  ↓
저장 완료 → TermEditorView 닫기 → 번역 재실행 (선택적) → 오버레이 업데이트
```

### 2.2 원문 선택 시

```
사용자가 오버레이 패널의 원문 일부를 선택
  ↓
컨텍스트 메뉴 표시: "용어집에 추가"
  ↓
사용자가 "용어집에 추가" 선택
  ↓
선택 범위와 기존 하이라이팅 범위 비교:
  ↓
[하이라이팅된 기존 용어 범위와 일치]
  - 바텀시트 표시: 해당 용어의 source, target, 기존 variants 표시
  - 바텀시트 내 "번역문 범위 선택" UI로 전환
  - 사용자가 번역 결과문(최종 또는 정규화 전)에서 텍스트 범위 선택
  - "다음" 버튼 클릭
  - 바텀시트 닫기 → TermEditorView로 화면 전환
  - TermEditorView에 해당 용어 로드 + 선택한 번역문이 variants에 미리 추가됨
  - 사용자가 variants 추가/수정, 기타 설정 변경 가능
  - "저장" 버튼 → SwiftData 업데이트
  ↓
[하이라이팅 범위와 불일치 또는 하이라이팅 없음]
  - 바텀시트 표시: 선택한 원문이 표시됨
  - 바텀시트 내 "번역문 범위 선택" UI로 전환
  - 사용자가 번역 결과문(최종 또는 정규화 전)에서 텍스트 범위 선택
  - "다음" 버튼 클릭
  - 바텀시트 닫기 → TermEditorView로 화면 전환 (새 용어 추가 모드)
  - TermEditorView에 선택한 원문이 source에, 선택한 번역문이 variants에 미리 입력됨
  - 사용자가 target 및 기타 설정 입력
  - "저장" 버튼 → SwiftData에 새 Term 추가
  ↓
저장 완료 → TermEditorView 닫기 → 번역 재실행 (선택적) → 오버레이 업데이트
```

---

## 3. UI/UX 상세 설계

### 3.1 오버레이 패널 텍스트 선택

**현재 상태**:
- `OverlayPanel.swift` 내부의 private `SelectableTextView`(UITextView 래퍼)가 각 섹션에 사용됨
- plain 문자열 또는 `NSAttributedString`을 표시하며 선택·복사만 지원
- `canPerformAction`에서 `paste`/`cut`/`delete`를 막아 기본 컨텍스트 메뉴도 복사/조회 위주로 제한됨
- 선택 정보가 외부로 전달되지 않으며 Glossary 연동 콜백이나 섹션 구분 값이 없다

**미구현/필요 작업**:
- "용어집에 추가" 컨텍스트 메뉴 및 `onAddToGlossary` 콜백 추가 필요
- 선택된 텍스트/범위/섹션을 ViewModel로 전달할 Coordinator와 SectionType 설계 필요 (`UIEditMenuInteractionDelegate` 미구현 상태)

**현재 구현 발췌**:
```swift
private struct SelectableTextView: UIViewRepresentable {
    var text: String?
    var attributedText: NSAttributedString? = nil

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        // isEditable = false, isSelectable = true, isScrollEnabled = false 등 기본 설정
        return textView
    }
}

final class SelectableUITextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) || action == #selector(cut(_:)) || action == #selector(delete(_:)) {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
```

### 3.2 용어 선택 바텀시트 (간소화된 프리뷰)

**목적**: 오버레이 패널에서 간단한 선택/확인만 수행하고, 실제 편집은 TermEditorView로 위임

**레이아웃 구성 - 번역문 선택 시**:
```
┌─────────────────────────────────────┐
│  용어집에 추가                    [X]│
├─────────────────────────────────────┤
│                                     │
│  선택한 번역문                        │
│  ┌─────────────────────────────────┐│
│  │ "안녕하세요"                     ││
│  └─────────────────────────────────┘│
│                                     │
│  매칭할 용어 선택                     │
│  ┌─────────────────────────────────┐│
│  │ ▼ 候補1: "你好" → "안녕"         ││
│  │   (등장: 2, 유사도: 85%)         ││
│  └─────────────────────────────────┘│
│  (Picker 드롭다운 - 뷰 크기 효율적)   │
│                                     │
│  [선택한 후보 상세 정보]               │
│  Source: "你好"                      │
│  Target: "안녕"                      │
│  기존 variants: "你好", "妳好"       │
│                                     │
│  또는                                 │
│  [ ] 새 용어 추가                     │
│                                     │
│  [새 용어 추가 체크 시 추가 UI 표시]   │
│  원문 범위 선택:                      │
│  ┌─────────────────────────────────┐│
│  │ "你好，世界！..." (탭하여 선택)    ││
│  └─────────────────────────────────┘│
│  TextField: "____________"          │
│                                     │
│         [취소]        [다음]         │
└─────────────────────────────────────┘
```

**레이아웃 구성 - 원문 선택 시 (기존 용어) - Step 1**:
```
┌─────────────────────────────────────┐
│  용어에 variants 추가              [X]│
├─────────────────────────────────────┤
│                                     │
│  선택한 원문                          │
│  ┌─────────────────────────────────┐│
│  │ "你好"                           ││
│  └─────────────────────────────────┘│
│                                     │
│  기존 용어 정보                       │
│  Source: "你好"                      │
│  Target: "안녕"                      │
│  Variants: "你好", "妳好"            │
│  preMask: OFF                       │
│                                     │
│         [취소]        [다음]         │
└─────────────────────────────────────┘
```

**레이아웃 구성 - 원문 선택 시 (기존 용어) - Step 2**:
```
┌─────────────────────────────────────┐
│  번역문 범위 선택                   [X]│
├─────────────────────────────────────┤
│                                     │
│  번역 결과문 (최종):                  │
│  ┌─────────────────────────────────┐│
│  │ "안녕하세요, 세계입니다!"         ││
│  │ (탭하여 범위 선택)                ││
│  └─────────────────────────────────┘│
│                                     │
│  또는 번역 결과문 (정규화 전):        │
│  ┌─────────────────────────────────┐│
│  │ "안녕, 世界입니다!"               ││
│  │ (탭하여 범위 선택)                ││
│  └─────────────────────────────────┘│
│                                     │
│  선택한 텍스트:                       │
│  TextField: "____________"          │
│                                     │
│         [뒤로]        [다음]         │
└─────────────────────────────────────┘
```

**레이아웃 구성 - 원문 선택 시 (새 용어) - Step 1**:
```
┌─────────────────────────────────────┐
│  새 용어 추가                      [X]│
├─────────────────────────────────────┤
│                                     │
│  선택한 원문                          │
│  ┌─────────────────────────────────┐│
│  │ "世界"                           ││
│  └─────────────────────────────────┘│
│                                     │
│  이 텍스트로 새 용어를 추가합니다.     │
│                                     │
│         [취소]        [다음]         │
└─────────────────────────────────────┘
```

**레이아웃 구성 - 원문 선택 시 (새 용어) - Step 2**:
```
┌─────────────────────────────────────┐
│  번역문 범위 선택                   [X]│
├─────────────────────────────────────┤
│                                     │
│  번역 결과문 (최종):                  │
│  ┌─────────────────────────────────┐│
│  │ "안녕하세요, 세계입니다!"         ││
│  │ (탭하여 범위 선택)                ││
│  └─────────────────────────────────┘│
│                                     │
│  또는 번역 결과문 (정규화 전):        │
│  ┌─────────────────────────────────┐│
│  │ "안녕, 世界입니다!"               ││
│  │ (탭하여 범위 선택)                ││
│  └─────────────────────────────────┘│
│                                     │
│  선택한 텍스트:                       │
│  TextField: "____________"          │
│                                     │
│         [뒤로]        [다음]         │
└─────────────────────────────────────┘
```

**Presentation Style**:
- `.sheet(isPresented:)` 사용
- `.presentationDetents([.medium, .large])` - 중간 크기 기본, 확장 가능
- `.presentationDragIndicator(.visible)` - 드래그 인디케이터 표시

**주요 버튼 액션**:
- **다음** (번역문 선택 → 기존 용어 선택 시):
  - 바텀시트 닫기
  - `BrowserViewModel.openTermEditor(termID:prefilledVariant:)` 호출
  - TermEditorView fullScreenCover로 표시
- **다음** (번역문 선택 → 새 용어 추가 시):
  - 바텀시트 내에서 원문 범위 선택 UI로 전환
  - 사용자가 원문 입력 후 "다음" 클릭
  - 바텀시트 닫기
  - `BrowserViewModel.openTermEditor(newTermSource:newTermVariant:)` 호출
  - TermEditorView fullScreenCover로 표시
- **다음** (원문 선택 시 - Step 1):
  - 바텀시트 내에서 번역문 범위 선택 UI로 전환 (Step 2)
- **다음** (원문 선택 시 - Step 2):
  - 사용자가 번역문 입력 후 "다음" 클릭
  - 바텀시트 닫기
  - `BrowserViewModel.openTermEditor(termID:prefilledVariant:)` 또는 `openTermEditor(newTermSource:newTermVariant:)` 호출
  - TermEditorView fullScreenCover로 표시
- **뒤로** (Step 2에서):
  - 바텀시트 내에서 Step 1로 되돌아감

**바텀시트 상태 관리** (업데이트):
```swift
// BrowserViewModel에 추가
@Published var glossaryAddSheet: GlossaryAddSheetState? = nil

struct GlossaryAddSheetState {
    let selectedText: String
    let selectedRange: Range<String.Index>
    let context: SelectionContext
    var currentStep: Step = .step1  // 다단계 UI 지원

    enum Step {
        case step1  // 초기 선택 화면
        case step2  // 번역문 또는 원문 범위 선택 화면
    }

    enum SelectionContext {
        case originalText(
            String,
            highlightedTermID: String?,
            overlayState: BrowserViewModel.OverlayState  // 번역문 접근용
        )
        case translatedText(
            text: String,
            unmatchedTermCandidates: [UnmatchedTermCandidate],
            existingTerms: [GlossaryEntry],
            fullOriginalText: String  // 원문 범위 선택용
        )
    }
}
```

### 3.3 매칭되지 않은 용어 후보 제시 로직

**후보 추출 알고리즘**:

1. **현재 세그먼트의 SegmentPieces 분석**:
   - 원문에서 검출된 모든 용어 목록 추출
   - 각 용어의 정규화/언마스킹 결과 확인

2. **매칭되지 않은 용어 판별**:
   ```swift
   // 정규화/언마스킹 실패 = 최종 번역문에 용어가 반영되지 않음
   - Phase 1 실패: target/variants가 번역문에 없음
   - Phase 2 실패: Pattern fallback도 매칭 안 됨
   - Phase 3 실패: 전역 검색도 매칭 안 됨
   ```

3. **우선순위 정렬**:
   - 원문에서의 등장 순서 (Range 시작 위치 기준)
   - 선택한 번역문과의 유사도 (편집 거리)
   - preMask 여부 (마스킹된 용어 우선)

4. **후보 데이터 구조**:
   ```swift
   struct UnmatchedTermCandidate {
       let entry: GlossaryEntry
       let rangeInOriginal: Range<String.Index>
       let appearanceOrder: Int
       let similarity: Double  // 0.0 ~ 1.0
   }
   ```

**후보 제시 UI** (업데이트):
- Picker (드롭다운) 형식으로 후보 제시 (뷰 크기 효율적)
- 최상위 후보 자동 선택 (기본값)
- 각 후보 표시 형식: `"[source]" → "[target]" (등장: [order], 유사도: [%])`
- 선택한 후보의 상세 정보 (source, target, 기존 variants) 하단에 표시
- "새 용어 추가" 체크박스 또는 토글

---

## 4. 기술 구현 계획

### 4.1 아키텍처 흐름 (업데이트)

**현재 구현 흐름**:
```
SelectableTextView (UITextView)
  ↓ 사용자 선택 → 기본 컨텍스트 메뉴(복사/조회)
  ↓ Glossary 플로우 진입 지점 없음
```
- `BrowserViewModel`로 전달되는 콜백이 없어서 GlossaryAddSheet/TermEditor 단계로 이어지지 않는다.

**목표 흐름 (미구현, Phase 1에서 시작 필요)**:
> SelectableTextView에 컨텍스트 메뉴와 콜백을 추가해야 아래 단계가 동작한다.
```
SelectableTextView (UITextView)
  ↓ 사용자 선택 + 컨텍스트 메뉴 "용어집에 추가"
BrowserViewModel.onGlossaryAddRequested(text:range:section:)
  ↓ 컨텍스트 분석
buildGlossaryAddSheetState(...)
  ↓
- 원문 선택 → 하이라이팅 범위 비교
- 번역문 선택 → 매칭되지 않은 용어 추출
  ↓
glossaryAddSheet 상태 설정
  ↓
GlossaryAddSheet (SwiftUI View) - 간소화된 선택 UI
  ↓ 사용자 선택 (용어 선택 또는 "새 용어 추가")
사용자가 "이 용어에 variants 추가" / "이 용어 편집" / "다음" 버튼 클릭
  ↓
BrowserViewModel.openTermEditor(...)
  - 기존 용어 편집: termID + prefilledVariant 전달
  - 새 용어 추가: newTermSource + newTermVariant 전달
  ↓
glossaryAddSheet = nil (바텀시트 닫기)
termEditorState 설정
  ↓
TermEditorView fullScreenCover 표시
  - TermEditorViewModel 초기화 (termID 또는 신규)
  - prefilled 데이터 적용 (source, target, variants)
  ↓ 사용자 편집 및 저장
TermEditorViewModel.save()
  ↓
SwiftData 업데이트 (modelContext)
  ↓
TermEditorView 닫기
  ↓
번역 재실행 (선택적)
  ↓
오버레이 업데이트
```

### 4.2 핵심 컴포넌트

#### 4.2.1 SelectableTextView 구현 현황

**파일**: `MyTranslation/Presentation/Browser/View/OverlayPanel.swift` 내부 private struct `SelectableTextView`

**주요 동작**:
- 입력: `text`(String?) 또는 `attributedText`(NSAttributedString?)으로 plain/하이라이트 텍스트 표시
- 스타일: `textStyle`, `textColor`, `adjustsFontForContentSizeCategory`로 폰트/색상 제어
- 레이아웃: `textContainerInset = .zero`, `lineFragmentPadding = 0`, `lineBreakMode = .byCharWrapping`, `SelectableUITextView.constrainedWidth`로 intrinsic height 계산
- 상호작용: `isSelectable = true`, `isEditable = false`, `isScrollEnabled = false`, `canPerformAction`에서 `paste`/`cut`/`delete` 비활성화
- Glossary 연동: 커스텀 메뉴/`onAddToGlossary` 콜백/섹션 구분 enum이 없으며 ViewModel로 이벤트를 보내지 않음

**필요 변경점**:
- Glossary 추가를 위해 Coordinator + 커스텀 메뉴 + 콜백을 새로 도입해야 함 (현재 구조에는 관련 훅 없음)

#### 4.2.2 BrowserViewModel 확장

**상태**: 미구현 설계안 (SelectableTextView에 SectionType/onAddToGlossary 훅이 없어 현재 호출 지점 없음)

**파일**: `MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel+GlossaryAdd.swift` (신규)

**주요 메서드**:
```swift
extension BrowserViewModel {
    /// 오버레이 패널에서 "용어집에 추가" 요청 처리
    func onGlossaryAddRequested(
        selectedText: String,
        selectedRange: NSRange,
        section: SelectableTextView.SectionType
    ) async {
        guard let overlayState = overlayState else { return }

        let context: GlossaryAddSheetState.SelectionContext

        switch section {
        case .original:
            context = await buildOriginalTextContext(
                selectedText: selectedText,
                selectedRange: selectedRange,
                segmentID: overlayState.segmentID,
                highlightMetadata: overlayState.primaryHighlightMetadata
            )

        case .primaryFinal, .primaryPreNormalized:
            context = await buildTranslatedTextContext(
                selectedText: selectedText,
                selectedRange: selectedRange,
                segmentID: overlayState.segmentID,
                isPreNormalized: section == .primaryPreNormalized,
                highlightMetadata: overlayState.primaryHighlightMetadata
            )

        case .alternative:
            // 대체 엔진 번역문은 단순 새 용어 추가로만 처리
            context = .translatedText(
                text: selectedText,
                unmatchedTermCandidates: [],
                existingTerms: []
            )
        }

        glossaryAddSheet = GlossaryAddSheetState(
            selectedText: selectedText,
            selectedRange: selectedRange.toStringRange(in: selectedText),
            context: context
        )
    }

    /// 원문 선택 컨텍스트 구성
    private func buildOriginalTextContext(
        selectedText: String,
        selectedRange: NSRange,
        segmentID: String,
        highlightMetadata: TermHighlightMetadata?
    ) async -> GlossaryAddSheetState.SelectionContext {
        // 하이라이팅된 용어 범위와 비교
        let highlightedTermID = highlightMetadata?.matchingTermID(for: selectedRange)

        return .originalText(
            selectedText,
            highlightedTermID: highlightedTermID
        )
    }

    /// 번역문 선택 컨텍스트 구성
    private func buildTranslatedTextContext(
        selectedText: String,
        selectedRange: NSRange,
        segmentID: String,
        isPreNormalized: Bool,
        highlightMetadata: TermHighlightMetadata?
    ) async -> GlossaryAddSheetState.SelectionContext {
        // 매칭되지 않은 용어 추출
        let unmatchedCandidates = await extractUnmatchedTermCandidates(
            selectedText: selectedText,
            segmentID: segmentID,
            isPreNormalized: isPreNormalized,
            highlightMetadata: highlightMetadata
        )

        // 기존 전체 용어 목록 (선택 가능하도록)
        let existingTerms = await glossaryService.buildEntries(for: overlayState.selectedText)

        return .translatedText(
            text: selectedText,
            unmatchedTermCandidates: unmatchedCandidates,
            existingTerms: existingTerms
        )
    }

    /// 매칭되지 않은 용어 후보 추출
    private func extractUnmatchedTermCandidates(
        selectedText: String,
        segmentID: String,
        isPreNormalized: Bool,
        highlightMetadata: TermHighlightMetadata?
    ) async -> [UnmatchedTermCandidate] {
        guard let segmentPieces = await getSegmentPieces(for: segmentID) else {
            return []
        }

        // 1. 원문에서 검출된 모든 용어
        let detectedTerms: [(GlossaryEntry, Range<String.Index>)] = segmentPieces.pieces.compactMap { piece in
            guard case .term(let entry, let range) = piece else { return nil }
            return (entry, range)
        }

        // 2. 정규화/언마스킹 실패한 용어 필터링
        let unmatchedTerms = detectedTerms.filter { entry, range in
            // highlightMetadata에서 해당 용어가 최종 번역문에 반영되었는지 확인
            let wasNormalized = highlightMetadata?.normalizedRanges.contains { $0.entry.source == entry.source } ?? false
            let wasUnmasked = highlightMetadata?.unmaskedRanges.contains { $0.entry.source == entry.source } ?? false

            return !wasNormalized && !wasUnmasked
        }

        // 3. 우선순위 정렬
        let candidates = unmatchedTerms.enumerated().map { index, (entry, range) in
            UnmatchedTermCandidate(
                entry: entry,
                rangeInOriginal: range,
                appearanceOrder: index + 1,
                similarity: calculateSimilarity(selectedText, entry.target)
            )
        }

        return candidates.sorted { lhs, rhs in
            // 등장 순서 우선, 유사도 보조
            if lhs.appearanceOrder != rhs.appearanceOrder {
                return lhs.appearanceOrder < rhs.appearanceOrder
            }
            return lhs.similarity > rhs.similarity
        }
    }

    /// 편집 거리 기반 유사도 계산 (0.0 ~ 1.0)
    private func calculateSimilarity(_ s1: String, _ s2: String) -> Double {
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    /// Levenshtein Distance 계산
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a1 = Array(s1)
        let a2 = Array(s2)
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: a2.count + 1), count: a1.count + 1)

        for i in 0...a1.count { matrix[i][0] = i }
        for j in 0...a2.count { matrix[0][j] = j }

        for i in 1...a1.count {
            for j in 1...a2.count {
                let cost = a1[i-1] == a2[j-1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,      // 삭제
                    matrix[i][j-1] + 1,      // 삽입
                    matrix[i-1][j-1] + cost  // 교체
                )
            }
        }

        return matrix[a1.count][a2.count]
    }
}
```

#### 4.2.3 GlossaryAddSheet (SwiftUI View) - 간소화된 선택 UI

**파일**: `MyTranslation/Presentation/Browser/View/GlossaryAddSheet.swift` (신규)

**목적**: 용어 후보 선택 및 간단한 정보 표시만 수행. 실제 편집은 TermEditorView로 위임.

**구조**:
```swift
struct GlossaryAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let state: GlossaryAddSheetState
    let onOpenTermEditor: (TermEditorPrefillData) -> Void

    @StateObject private var viewModel: GlossaryAddViewModel

    init(
        state: GlossaryAddSheetState,
        onOpenTermEditor: @escaping (TermEditorPrefillData) -> Void
    ) {
        self.state = state
        self.onOpenTermEditor = onOpenTermEditor
        _viewModel = StateObject(wrappedValue: GlossaryAddViewModel(state: state))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("선택한 텍스트") {
                    Text(state.selectedText)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }

                switch state.context {
                case .originalText(let text, let termID):
                    originalTextSection(text: text, termID: termID)

                case .translatedText(let text, let candidates, let existingTerms):
                    translatedTextSection(
                        text: text,
                        candidates: candidates,
                        existingTerms: existingTerms
                    )
                }

                actionButtonsSection
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var navigationTitle: String {
        switch state.context {
        case .originalText(_, let termID):
            return termID != nil ? "용어 편집" : "새 용어 추가"
        case .translatedText:
            return "용어집에 추가"
        }
    }

    @ViewBuilder
    private func originalTextSection(text: String, termID: String?) -> some View {
        if viewModel.currentStep == .step1 {
            if let termID = termID, let termInfo = viewModel.getTermInfo(termID) {
                // 기존 용어 프리뷰
                Section("기존 용어 정보") {
                    LabeledContent("Source", value: termInfo.source)
                    LabeledContent("Target", value: termInfo.target)
                    if !termInfo.variants.isEmpty {
                        LabeledContent("Variants") {
                            Text(termInfo.variants.joined(separator: ", "))
                                .foregroundColor(.secondary)
                        }
                    }
                    LabeledContent("preMask", value: termInfo.preMask ? "ON" : "OFF")
                }
            } else {
                // 새 용어 추가 안내
                Section {
                    Text("이 텍스트로 새 용어를 추가합니다.")
                        .foregroundColor(.secondary)
                }
            }
        }

        if viewModel.currentStep == .step2 {
            // 번역문 범위 선택 UI
            Section("번역문 범위 선택") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("번역 결과문 (최종):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(viewModel.primaryFinalText)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .onTapGesture {
                            // TODO: 인터랙티브 선택 UI
                        }

                    Text("또는 번역 결과문 (정규화 전):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(viewModel.primaryPreNormalizedText)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .onTapGesture {
                            // TODO: 인터랙티브 선택 UI
                        }

                    TextField("선택한 번역문 (Variant)", text: $viewModel.selectedVariantText)
                }
            }
        }
    }

    @ViewBuilder
    private func translatedTextSection(
        text: String,
        candidates: [UnmatchedTermCandidate],
        existingTerms: [GlossaryEntry]
    ) -> some View {
        if viewModel.currentStep == .step1 {
            Section("매칭할 용어 선택") {
                // Picker 드롭다운으로 후보 제시
                Picker("용어 선택", selection: $viewModel.selectedCandidateID) {
                    ForEach(candidates) { candidate in
                        Text("\"\(candidate.entry.source)\" → \"\(candidate.entry.target)\" (등장: \(candidate.appearanceOrder), 유사도: \(String(format: "%.0f%%", candidate.similarity * 100)))")
                            .tag(candidate.entry.source as String?)
                    }
                }
                .pickerStyle(.menu)

                // 선택한 후보 상세 정보
                if let selectedCandidate = viewModel.selectedCandidate {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Source", value: selectedCandidate.entry.source)
                        LabeledContent("Target", value: selectedCandidate.entry.target)
                        if !selectedCandidate.entry.variants.isEmpty {
                            LabeledContent("기존 variants") {
                                Text(selectedCandidate.entry.variants.joined(separator: ", "))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                // 새 용어 추가 토글
                Toggle("새 용어 추가", isOn: $viewModel.isCreatingNewTerm)
            }
        }

        if viewModel.currentStep == .step2 && viewModel.isCreatingNewTerm {
            Section("원문 범위 선택") {
                Text("전체 원문:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(viewModel.fullOriginalText)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .onTapGesture {
                        // TODO: 인터랙티브 선택 UI
                    }

                TextField("선택한 원문 (Source)", text: $viewModel.selectedSourceText)
            }
        }
    }

    @ViewBuilder
    private var actionButtonsSection: some View {
        Section {
            Button {
                handleNextAction()
            } label: {
                HStack {
                    Spacer()
                    Text(actionButtonTitle)
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!viewModel.canProceed)
        }
    }

    private var actionButtonTitle: String {
        if viewModel.currentStep == .step2 {
            return "다음"
        }

        switch state.context {
        case .originalText:
            return "다음"
        case .translatedText:
            return viewModel.isCreatingNewTerm ? "다음" : "다음"
        }
    }

    private func handleNextAction() {
        // Step 전환 또는 TermEditor 열기
        if viewModel.currentStep == .step1 {
            // 번역문 선택 → 기존 용어: 바로 TermEditor
            // 번역문 선택 → 새 용어: Step 2로 전환 (원문 선택)
            // 원문 선택: Step 2로 전환 (번역문 선택)
            if case .translatedText = state.context, !viewModel.isCreatingNewTerm {
                // 기존 용어에 variants 추가 → 바로 TermEditor
                let prefillData = viewModel.buildPrefillData(selectedText: state.selectedText)
                dismiss()
                onOpenTermEditor(prefillData)
            } else {
                // Step 2로 전환
                viewModel.moveToStep2()
            }
        } else {
            // Step 2 → TermEditor
            let prefillData = viewModel.buildPrefillData(
                selectedText: state.selectedText,
                selectedVariant: viewModel.selectedVariantText,
                selectedSource: viewModel.selectedSourceText
            )
            dismiss()
            onOpenTermEditor(prefillData)
        }
    }
}

/// TermEditor에 전달할 프리필 데이터
struct TermEditorPrefillData {
    let mode: Mode

    enum Mode {
        case editExisting(termID: String, additionalVariant: String?)
        case createNew(source: String, variant: String?)
    }
}
```

#### 4.2.4 GlossaryAddViewModel (업데이트)

**파일**: `MyTranslation/Presentation/Browser/ViewModel/GlossaryAddViewModel.swift` (신규)

**목적**: 바텀시트 UI 상태 관리 및 TermEditorPrefillData 생성

```swift
@MainActor
class GlossaryAddViewModel: ObservableObject {
    private let state: GlossaryAddSheetState

    @Published var currentStep: GlossaryAddSheetState.Step = .step1
    @Published var selectedCandidateID: String? = nil
    @Published var selectedCandidate: UnmatchedTermCandidate? = nil
    @Published var isCreatingNewTerm: Bool = false
    @Published var selectedSourceText: String = ""
    @Published var selectedVariantText: String = ""

    var fullOriginalText: String {
        // state.context에서 전체 원문 추출
        if case .translatedText(_, _, _, let fullText) = state.context {
            return fullText
        }
        return ""
    }

    var primaryFinalText: String {
        // 원문 선택 시 번역문 접근
        if case .originalText(_, _, let overlayState) = state.context {
            return overlayState.primaryFinalText ?? ""
        }
        return ""
    }

    var primaryPreNormalizedText: String {
        // 원문 선택 시 정규화 전 번역문 접근
        if case .originalText(_, _, let overlayState) = state.context {
            return overlayState.primaryPreNormalizedText ?? ""
        }
        return ""
    }

    var canProceed: Bool {
        if currentStep == .step1 {
            switch state.context {
            case .originalText:
                return true  // 원문 선택 시 항상 진행 가능
            case .translatedText:
                return isCreatingNewTerm || selectedCandidateID != nil
            }
        } else {
            // Step 2
            if case .originalText = state.context {
                return !selectedVariantText.isEmpty
            } else {
                return !selectedSourceText.isEmpty
            }
        }
    }

    init(state: GlossaryAddSheetState) {
        self.state = state

        // 번역문 선택 시 최상위 후보 자동 선택
        if case .translatedText(_, let candidates, _, _) = state.context,
           let firstCandidate = candidates.first {
            self.selectedCandidateID = firstCandidate.entry.source
            self.selectedCandidate = firstCandidate
        }
    }

    func selectCandidate(_ candidate: UnmatchedTermCandidate) {
        selectedCandidateID = candidate.entry.source
        selectedCandidate = candidate
        isCreatingNewTerm = false
    }

    func selectExistingTerm(_ term: GlossaryEntry) {
        selectedCandidateID = term.source
        selectedCandidate = nil // 기존 전체 용어에서 선택한 경우
        isCreatingNewTerm = false
    }

    func selectNewTerm() {
        selectedCandidateID = nil
        selectedCandidate = nil
        isCreatingNewTerm = true
    }

    func moveToStep2() {
        currentStep = .step2
    }

    func moveToStep1() {
        currentStep = .step1
    }

    /// 기존 용어 정보 조회 (원문 선택 시 프리뷰용)
    func getTermInfo(_ termID: String) -> TermInfo? {
        // TODO: modelContext에서 SDTerm 조회 후 TermInfo 구성
        // 현재는 state.context에서 추출 가능한 정보만 사용
        return nil
    }

    /// TermEditorPrefillData 생성
    func buildPrefillData(
        selectedText: String,
        selectedVariant: String = "",
        selectedSource: String = ""
    ) -> TermEditorPrefillData {
        switch state.context {
        case .originalText(_, let termID, _):
            if let termID = termID {
                // 기존 용어에 variants 추가 (원문 선택 → 번역문 선택)
                return TermEditorPrefillData(mode: .editExisting(
                    termID: termID,
                    additionalVariant: selectedVariant.isEmpty ? nil : selectedVariant
                ))
            } else {
                // 새 용어 추가 (원문 선택 → 번역문 선택)
                return TermEditorPrefillData(mode: .createNew(
                    source: selectedText,  // 원래 선택한 원문
                    variant: selectedVariant.isEmpty ? nil : selectedVariant
                ))
            }

        case .translatedText:
            if isCreatingNewTerm {
                // 새 용어 추가 (번역문 선택 → 원문 입력)
                return TermEditorPrefillData(mode: .createNew(
                    source: selectedSource.isEmpty ? selectedSourceText : selectedSource,
                    variant: selectedText
                ))
            } else if let candidateID = selectedCandidateID {
                // 기존 용어에 variants 추가
                return TermEditorPrefillData(mode: .editExisting(
                    termID: candidateID,
                    additionalVariant: selectedText
                ))
            } else {
                fatalError("Invalid state: selectedCandidateID is nil")
            }
        }
    }
}

/// 용어 정보 (프리뷰용)
struct TermInfo {
    let source: String
    let target: String
    let variants: [String]
    let preMask: Bool
}
```

### 4.3 데이터 흐름 상세 (업데이트)

**현재 코드 흐름**:
- 사용자 선택 → 기본 컨텍스트 메뉴(복사/조회) 노출
- Glossary 전용 액션/콜백이 없어 ViewModel 단계로 넘어가지 않음 (Step 1에서 종료)

**목표 흐름 (미구현)**:
> SelectableTextView에 컨텍스트 메뉴/콜백을 추가해야 아래 단계가 실행된다.
```
1. 사용자 선택
   SelectableTextView → UITextView 선택 이벤트
   ↓

2. 컨텍스트 메뉴
   "용어집에 추가" 액션 → onAddToGlossary 콜백
   ↓

3. ViewModel 처리
   BrowserViewModel.onGlossaryAddRequested()
   → buildGlossaryAddSheetState()
      → 원문/번역문 판별
      → 하이라이팅 범위 비교 (원문)
      → 매칭되지 않은 용어 추출 (번역문)
   → glossaryAddSheet 상태 설정
   ↓

4. 바텀시트 표시
   BrowserRootView에서 .sheet(item: $vm.glossaryAddSheet)
   → GlossaryAddSheet 표시
   ↓

5. 사용자 선택
   GlossaryAddSheet → GlossaryAddViewModel
   → 후보 선택 또는 "새 용어 추가" 선택
   → (새 용어 추가 시) 원문 범위 입력
   ↓

6. "다음" / "이 용어에 variants 추가" / "이 용어 편집" 버튼 클릭
   GlossaryAddViewModel.buildPrefillData()
   → TermEditorPrefillData 생성
   → onOpenTermEditor(prefillData) 콜백
   ↓

7. TermEditor 열기
   BrowserViewModel.openTermEditor(prefillData)
   → glossaryAddSheet = nil (바텀시트 닫기)
   → termEditorState = prefillData 설정
   ↓

8. TermEditorView 표시
   BrowserRootView에서 .fullScreenCover(item: $vm.termEditorState)
   → TermEditorView 표시
   → TermEditorViewModel 초기화:
      - editExisting 모드: termID로 SwiftData에서 SDTerm 로드
      - createNew 모드: 빈 SDTerm 생성
   → Prefilled 데이터 적용:
      - additionalVariant가 있으면 generalDraft.variants에 추가
      - source/variant가 있으면 generalDraft에 설정
   ↓

9. 사용자 편집 및 저장
   TermEditorView → TermEditorViewModel
   → 사용자가 source, target, variants, preMask 등 편집
   → "저장" 버튼 클릭
   → TermEditorViewModel.save()
   → SwiftData 업데이트 (modelContext.save())
   ↓

10. 후처리
   TermEditorView 닫기 (termEditorState = nil)
   → 번역 재실행 (선택적, BrowserViewModel에서 처리)
   → 오버레이 업데이트
```

### 4.4 TermHighlightMetadata 확장

**현재 구조**:
```swift
struct TermHighlightMetadata {
    let originalRanges: [TermRange]        // 원문에서 검출된 용어
    let maskedRanges: [TermRange]          // 마스킹된 용어
    let normalizedRanges: [TermRange]      // 정규화된 용어
    let unmaskedRanges: [TermRange]        // 언마스킹된 용어
}

struct TermRange {
    let entry: GlossaryEntry
    let range: Range<String.Index>
    let type: TermRangeType
}
```

**확장 메서드 추가**:
```swift
extension TermHighlightMetadata {
    /// 주어진 NSRange에 해당하는 용어 ID 반환
    func matchingTermID(for nsRange: NSRange) -> String? {
        // NSRange → String.Index Range 변환
        // originalRanges에서 매칭되는 용어 검색
        // 매칭되면 entry.source 반환
    }

    /// 정규화/언마스킹되지 않은 용어 목록 반환
    func unmatchedTerms() -> [GlossaryEntry] {
        let normalizedSources = Set(normalizedRanges.map { $0.entry.source })
        let unmaskedSources = Set(unmaskedRanges.map { $0.entry.source })

        return originalRanges
            .map { $0.entry }
            .filter { !normalizedSources.contains($0.source) && !unmaskedSources.contains($0.source) }
    }
}
```

---

## 5. 구현 세부사항

### 5.1 필요한 새 타입 정의

**파일**: `MyTranslation/Domain/Models/GlossaryAddModels.swift` (신규)

```swift
/// 용어집 추가 바텀시트 상태
struct GlossaryAddSheetState {
    let selectedText: String
    let selectedRange: Range<String.Index>
    let context: SelectionContext

    enum SelectionContext {
        case originalText(String, highlightedTermID: String?)
        case translatedText(
            text: String,
            unmatchedTermCandidates: [UnmatchedTermCandidate],
            existingTerms: [GlossaryEntry]
        )
    }
}

/// 매칭되지 않은 용어 후보
struct UnmatchedTermCandidate: Identifiable {
    let id = UUID()
    let entry: GlossaryEntry
    let rangeInOriginal: Range<String.Index>
    let appearanceOrder: Int
    let similarity: Double  // 0.0 ~ 1.0
}
```

### 5.2 수정/추가 파일 목록

**신규 파일**:
1. `MyTranslation/Domain/Models/GlossaryAddModels.swift`
2. `MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel+GlossaryAdd.swift`
3. `MyTranslation/Presentation/Browser/ViewModel/GlossaryAddViewModel.swift`
4. `MyTranslation/Presentation/Browser/View/GlossaryAddSheet.swift`

**수정 파일**:
1. `MyTranslation/Presentation/Browser/View/OverlayPanel.swift`
   - 내부 SelectableTextView에 컨텍스트 메뉴/`onAddToGlossary` 콜백 추가 필요
   - OverlayPanelView에서 콜백 전달 흐름 추가 필요

2. `MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel.swift`
   - `@Published var glossaryAddSheet: GlossaryAddSheetState?` 추가

3. `MyTranslation/Presentation/Browser/View/BrowserRootView.swift`
   - `.sheet(item: $vm.glossaryAddSheet)` 바인딩 추가

4. `MyTranslation/Domain/Models/TermHighlightMetadata.swift`
   - `matchingTermID(for:)` 메서드 추가
   - `unmatchedTerms()` 메서드 추가

### 5.3 핵심 메서드 시그니처 (업데이트)

**상태**: SelectableTextView에 SectionType/onAddToGlossary가 없어 아직 실제 코드에 추가되지 않은 설계안

```swift
// BrowserViewModel+GlossaryAdd.swift
extension BrowserViewModel {
    func onGlossaryAddRequested(
        selectedText: String,
        selectedRange: NSRange,
        section: SelectableTextView.SectionType
    ) async

    func buildOriginalTextContext(
        selectedText: String,
        selectedRange: NSRange,
        segmentID: String,
        highlightMetadata: TermHighlightMetadata?
    ) async -> GlossaryAddSheetState.SelectionContext

    func buildTranslatedTextContext(
        selectedText: String,
        selectedRange: NSRange,
        segmentID: String,
        isPreNormalized: Bool,
        highlightMetadata: TermHighlightMetadata?
    ) async -> GlossaryAddSheetState.SelectionContext

    func extractUnmatchedTermCandidates(
        selectedText: String,
        segmentID: String,
        isPreNormalized: Bool,
        highlightMetadata: TermHighlightMetadata?
    ) async -> [UnmatchedTermCandidate]

    /// TermEditorView 열기
    func openTermEditor(with prefillData: TermEditorPrefillData)
}

// GlossaryAddViewModel.swift
@MainActor
class GlossaryAddViewModel: ObservableObject {
    func selectCandidate(_ candidate: UnmatchedTermCandidate)
    func selectExistingTerm(_ term: GlossaryEntry)
    func selectNewTerm()
    func getTermInfo(_ termID: String) -> TermInfo?
    func buildPrefillData(selectedText: String) -> TermEditorPrefillData
}

// TermHighlightMetadata+Extensions.swift
extension TermHighlightMetadata {
    func matchingTermID(for nsRange: NSRange) -> String?
    func unmatchedTerms() -> [GlossaryEntry]
}

// BrowserViewModel.swift (기존 파일에 추가)
extension BrowserViewModel {
    /// TermEditor 상태 관리
    @Published var termEditorState: TermEditorPrefillData? = nil

    /// TermEditor 열기
    func openTermEditor(with prefillData: TermEditorPrefillData) {
        glossaryAddSheet = nil  // 바텀시트 닫기
        termEditorState = prefillData
    }

    /// TermEditor 닫은 후 번역 재실행 (선택적)
    func onTermEditorDismissed() {
        termEditorState = nil
        // 필요 시 번역 재실행
        Task {
            await retranslateCurrentSegment()
        }
    }
}

// TermEditorViewModel.swift (기존 파일 수정 필요)
extension TermEditorViewModel {
    /// Prefill 데이터 적용
    func applyPrefill(_ prefillData: TermEditorPrefillData) {
        switch prefillData.mode {
        case .editExisting(_, let additionalVariant):
            // 기존 용어 로드 완료 후
            if let variant = additionalVariant {
                // generalDraft.variants에 추가
                // TODO: 실제 구현
            }

        case .createNew(let source, let variant):
            // 새 용어 생성 시
            // generalDraft.sourcesOK에 source 추가
            if let variant = variant {
                // generalDraft.variants에 variant 추가
            }
            // TODO: 실제 구현
        }
    }
}
```

---

## 6. 엣지 케이스 및 예외 처리

### 6.1 텍스트 선택 관련

| 케이스 | 처리 방법 |
|--------|----------|
| 빈 선택 | 컨텍스트 메뉴 비활성화 |
| 공백만 선택 | "용어집에 추가" 액션 비활성화 또는 경고 |
| 매우 긴 텍스트 선택 | UI에서 텍스트 말줄임 표시, 전체는 스크롤 가능 |
| 특수문자/이모지 포함 | 정상 처리 (용어집이 지원하는 문자 범위) |

### 6.2 용어 후보 추출 관련

| 케이스 | 처리 방법 |
|--------|----------|
| 매칭되지 않은 용어가 없음 | "새 용어 추가" 옵션만 표시 |
| 후보가 매우 많음 (10개 이상) | 상위 5개만 기본 표시, "더 보기" 버튼 |
| 하이라이팅 정보 없음 | 전체 용어 목록에서 선택 가능하도록 처리 |
| SegmentPieces 없음 | 경고 메시지 표시 후 바텀시트 닫기 |

### 6.3 데이터 저장 관련

| 케이스 | 처리 방법 |
|--------|----------|
| SwiftData 저장 실패 | 에러 Alert 표시 후 재시도 유도 |
| 중복 용어 추가 시도 | 기존 용어에 variants 추가로 자동 전환 |
| 빈 source/target | 저장 버튼 비활성화 |
| 모델 컨텍스트 없음 | 바텀시트 표시 전 검증, 없으면 경고 |

### 6.4 UI/UX 관련

| 케이스 | 처리 방법 |
|--------|----------|
| 바텀시트 외부 터치 | 기본 dismiss 동작 (취소) |
| 저장 중 로딩 | 저장 버튼에 ProgressView 표시 |
| 네트워크/비동기 지연 | 타임아웃 설정 (5초) 및 에러 처리 |
| 화면 회전 | 바텀시트 크기 자동 조정 (Detents) |

---

## 7. 테스트 시나리오

### 7.1 기본 플로우

#### 시나리오 1: 번역문 선택 → 기존 용어에 variants 추가
```
1. 오버레이 패널 열기 (세그먼트 선택)
2. 최종 번역문에서 텍스트 일부 선택 (예: "안녕하세요")
3. "용어집에 추가" 컨텍스트 메뉴 선택
4. 바텀시트에서 매칭되지 않은 용어 후보 확인
5. 최상위 후보 선택 (자동 선택됨)
6. 후보의 기존 target, variants 정보 확인
7. "이 용어에 variants 추가" 버튼 클릭
8. 바텀시트 닫힘 → TermEditorView fullScreenCover 열림
9. TermEditorView에서 해당 용어 로드됨
10. variants 리스트에 "안녕하세요" 자동 추가됨
11. 사용자가 추가 편집 가능 (다른 variants, preMask 등)
12. "저장" 버튼 클릭 → SwiftData 업데이트
13. TermEditorView 닫힘
14. 번역 재실행 (선택적)
15. 오버레이에서 새 variants 적용 확인
```

#### 시나리오 2: 원문 선택 → 기존 용어 편집
```
1. 오버레이 패널 열기
2. 원문에서 하이라이팅된 용어 선택
3. "용어집에 추가" 선택
4. 바텀시트에서 기존 용어 정보 프리뷰 확인 (source, target, variants, preMask)
5. "이 용어 편집" 버튼 클릭
6. 바텀시트 닫힘 → TermEditorView fullScreenCover 열림
7. TermEditorView에서 해당 용어 로드됨
8. 사용자가 variants 추가/수정, 기타 설정 변경
9. "저장" 클릭 → SwiftData 업데이트
10. TermEditorView 닫힘
11. 번역 재실행 후 적용 확인
```

#### 시나리오 3: 번역문 선택 → 새 용어 추가
```
1. 오버레이 패널 열기
2. 번역문에서 텍스트 선택 (예: "안녕하세요")
3. "용어집에 추가" 선택
4. 바텀시트에서 "새 용어 추가" 라디오 버튼 선택
5. 원문 범위 선택 섹션이 표시됨
6. 전체 원문이 표시됨 → 텍스트 선택 또는 수동 입력 (예: "你好")
7. "다음" 버튼 클릭
8. 바텀시트 닫힘 → TermEditorView fullScreenCover 열림
9. TermEditorView에서 새 용어 생성 모드로 열림
10. source에 "你好", target 입력 필드 표시, variants에 "안녕하세요" 자동 입력됨
11. 사용자가 target 입력 및 기타 설정 (preMask, prohibitStandalone 등)
12. "저장" 클릭 → SwiftData에 새 Term 추가
13. TermEditorView 닫힘
14. 번역 재실행 후 적용 확인
```

### 7.2 엣지 케이스

#### 시나리오 4: 매칭되지 않은 용어가 없는 경우
```
1. 모든 용어가 정규화/언마스킹된 세그먼트 선택
2. 번역문 선택 → "용어집에 추가"
3. 후보 목록이 비어있음 확인
4. "새 용어 추가" 옵션만 표시
5. 새 용어 추가 플로우 진행
```

#### 시나리오 5: 저장 실패
```
1. 용어 추가 플로우 진행
2. SwiftData 저장 시 의도적 에러 발생
3. Alert 표시 확인
4. "재시도" 선택 시 다시 저장 시도
5. "취소" 선택 시 바텀시트 닫기
```

#### 시나리오 6: 취소 버튼
```
1. 용어 추가 플로우 진행
2. 입력 중간에 "취소" 버튼 클릭
3. 바텀시트 즉시 닫힘
4. 데이터 저장 안 됨 확인
```

### 7.3 성능 테스트

#### 시나리오 7: 대량 용어 목록
```
1. 용어집에 1000개 이상의 용어 추가
2. 매칭되지 않은 용어 추출 시간 측정 (< 1초 목표)
3. 바텀시트 UI 렌더링 시간 측정 (< 0.5초 목표)
4. 스크롤 성능 확인
```

#### 시나리오 8: 긴 텍스트 선택
```
1. 매우 긴 번역문 (1000자 이상) 선택
2. 유사도 계산 시간 측정 (< 2초 목표)
3. UI 반응성 확인
```

---

## 8. 향후 개선 사항

### 8.1 원문 범위 인터랙티브 선택 UI
현재 스펙에서는 텍스트 표시 후 수동 입력으로 처리하지만,
향후 드래그로 범위 선택 가능한 인터랙티브 UI 추가 고려.

### 8.2 AI 자동 추천
선택한 번역문에 대해 AI가 최적의 source/target을 자동 추천하는 기능.

### 8.3 배치 추가
여러 용어를 한 번에 추가할 수 있는 배치 모드.

### 8.4 프리뷰 기능
용어 추가 전에 해당 세그먼트에서 어떻게 적용될지 미리보기.

### 8.5 통계 정보
매칭되지 않은 용어가 전체 번역문에서 차지하는 비율 표시 등.

---

## 9. 참고 자료

- 기존 용어집 시스템: `MyTranslation/Services/Glossary/Glossary.Service.swift`
- TermMasker: `MyTranslation/Services/Translation/Masking/Masker.swift`
- BrowserViewModel: `MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel.swift`
- OverlayPanelView: `MyTranslation/Presentation/Browser/View/OverlayPanel.swift`
- TermEditorView: `MyTranslation/Presentation/Glossary/TermEditor/TermEditorView.swift`

---

## 10. 구현 우선순위

### Phase 1: 기본 플로우 (P0)
- [ ] SelectableTextView 컨텍스트 메뉴 추가
- [ ] BrowserViewModel+GlossaryAdd 기본 구조
- [ ] GlossaryAddSheet 기본 UI
- [ ] 번역문 선택 → 기존 용어에 variants 추가

### Phase 2: 원문 선택 지원 (P1)
- [ ] 원문 선택 시 하이라이팅 범위 비교
- [ ] 기존 용어 편집 모드
- [ ] 새 용어 추가 모드

### Phase 3: 고급 기능 (P2)
- [ ] 매칭되지 않은 용어 후보 추출
- [ ] 우선순위 정렬 (등장 순서, 유사도)
- [ ] 원문 범위 선택 UI
- [ ] 에러 처리 및 예외 케이스

### Phase 4: 최적화 및 테스트 (P2)
- [ ] 성능 최적화 (대량 용어 처리)
- [ ] 전체 테스트 시나리오 수행
- [ ] UX 개선 (애니메이션, 피드백 등)

---

**작성일**: 2025-11-22
**수정일**: 2025-11-22
**버전**: 1.2.1
**상태**: SelectableTextView 컨텍스트 메뉴 미구현 (Phase 1 TODO)

---

## 변경 이력

### v1.2.1 (2025-11-22) - SelectableTextView 현행 코드 기준 정리
- SelectableTextView 위치/동작을 실제 코드(OverlayPanel.swift) 기준으로 기술
- Glossary 플로우가 미구현임을 명시하고 현재/목표 흐름을 분리
- 수정 파일 경로 정리 및 설계안/미구현 상태를 명확히 표기

### v1.2 (2025-11-22) - UI/UX 개선
- **핵심 변경사항**:
  1. 번역문 선택 UI를 Picker (드롭다운)으로 변경 - 뷰 크기 효율화
  2. 새 용어 추가 시 번역문을 variants에 입력 (target이 아닌)
  3. 원문 선택 시 2단계 플로우 추가 (번역문 범위 선택 UI)
- **상세 변경**:
  - **번역문 선택 UI**:
    - 라디오 버튼 → Picker 드롭다운으로 변경
    - 선택한 후보의 상세 정보 (source, target, variants) 하단에 표시
    - "새 용어 추가" 체크박스/토글로 변경
  - **원문 선택 플로우**:
    - Step 1: 기존 용어 정보 프리뷰
    - Step 2: 번역문 범위 선택 UI (최종/정규화 전 번역문 표시)
    - "다음" 버튼으로 Step 전환 → TermEditorView로 이동
    - "뒤로" 버튼으로 Step 1로 복귀 가능
  - **데이터 모델 변경**:
    - `GlossaryAddSheetState`에 `currentStep` 추가
    - `SelectionContext.originalText`에 `overlayState` 추가 (번역문 접근용)
    - `SelectionContext.translatedText`에 `fullOriginalText` 추가 (원문 선택용)
  - **ViewModel 변경**:
    - `GlossaryAddViewModel`에 `currentStep`, `selectedVariantText` 추가
    - `moveToStep2()`, `moveToStep1()` 메서드 추가
    - `primaryFinalText`, `primaryPreNormalizedText` computed property 추가
- **새 용어 추가 시 동작 명확화**:
  - 번역문 → variants에 미리 입력
  - source 입력, target 직접 입력 (variants 아님)

### v1.1 (2025-11-22)
- **핵심 변경**: 바텀시트에서 직접 저장 → TermEditorView로 위임하는 플로우로 변경
- **사용자 플로우 업데이트**:
  - 번역문 선택 시: 기존 용어 선택 → variants 프리뷰 → "이 용어에 variants 추가" 버튼 → TermEditorView로 전환
  - 새 용어 추가 시: 바텀시트에서 원문 범위 선택 → "다음" 버튼 → TermEditorView로 전환 (source, variant 미리 입력됨)
  - 원문 선택 시: 기존 용어 정보 프리뷰 → "이 용어 편집" 버튼 → TermEditorView로 전환
- **UI 변경**:
  - GlossaryAddSheet: 간소화된 선택/프리뷰 UI로 역할 축소
  - 기존 variants 정보 표시 추가
  - 버튼 텍스트 명확화 ("이 용어에 variants 추가", "다음", "이 용어 편집")
- **데이터 흐름 변경**:
  - `TermEditorPrefillData` 구조체 추가
  - `BrowserViewModel.openTermEditor()` 메서드 추가
  - `BrowserViewModel.termEditorState` 상태 추가
  - TermEditorViewModel에 `applyPrefill()` 메서드 추가 필요
- **테스트 시나리오 업데이트**: 전체 플로우를 TermEditorView 전환 기준으로 재작성

### v1.0 (2025-11-22)
- 초안 작성
