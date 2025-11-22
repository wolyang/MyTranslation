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
  - 후보 선택 UI (드롭다운/라디오버튼)
  - 또는 "새 용어 추가" 옵션
  ↓
[기존 용어 선택한 경우]
  - 해당 용어의 variants에 선택한 번역문 추가
  - "저장" 버튼 → SwiftData 업데이트
  ↓
[새 용어 추가 선택한 경우]
  - 원문 범위 선택 UI로 전환
  - 사용자가 전체 원문에서 텍스트 범위 선택
  - source, target 입력 필드 표시
  - "저장" 버튼 → SwiftData에 새 Term 추가
  ↓
저장 완료 → 바텀시트 닫기 → 번역 재실행 (선택적)
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
  - 기존 용어 편집 모드로 바텀시트 표시
  - 해당 용어의 source, target, variants 표시
  - 사용자가 variants 추가/수정 가능
  - "저장" 버튼 → SwiftData 업데이트
  ↓
[하이라이팅 범위와 불일치 또는 하이라이팅 없음]
  - 새 용어 추가 모드로 바텀시트 표시
  - 선택한 원문이 source 필드에 자동 입력
  - target 입력 필드 표시
  - "저장" 버튼 → SwiftData에 새 Term 추가
  ↓
저장 완료 → 바텀시트 닫기 → 번역 재실행 (선택적)
```

---

## 3. UI/UX 상세 설계

### 3.1 오버레이 패널 텍스트 선택

**현재 상태**:
- `SelectableTextView` (UITextView 래퍼)가 각 섹션에 사용됨
- 전체 텍스트 선택 가능하지만 컨텍스트 메뉴는 기본 UITextView 메뉴

**변경사항**:
- `UITextView.menuConfiguration` 커스터마이징
- "용어집에 추가" 액션 추가
- 선택된 텍스트와 범위 정보를 ViewModel로 전달

**구현 방법**:
```swift
// SelectableTextView에 커스텀 메뉴 추가
func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isSelectable = true

    // 커스텀 메뉴 액션 등록
    let addToGlossary = UIAction(title: "용어집에 추가", image: UIImage(systemName: "book.closed")) { [weak textView] _ in
        if let selectedRange = textView?.selectedRange,
           let selectedText = textView?.text.substring(with: selectedRange) {
            context.coordinator.onAddToGlossary(selectedText, selectedRange)
        }
    }

    textView.editMenuInteraction?.delegate = context.coordinator
    // ... 메뉴 구성

    return textView
}
```

### 3.2 용어 추가/편집 바텀시트

**레이아웃 구성**:
```
┌─────────────────────────────────────┐
│  용어집에 추가                    [X]│
├─────────────────────────────────────┤
│                                     │
│  선택한 텍스트                        │
│  ┌─────────────────────────────────┐│
│  │ "안녕하세요"                     ││
│  └─────────────────────────────────┘│
│                                     │
│  매칭할 용어 선택                     │
│  ┌─────────────────────────────────┐│
│  │ ▼ 候補1: "你好" → "안녕" (Line 2)││
│  └─────────────────────────────────┘│
│  ○ 候補2: "哈囉" → "안녕" (Line 5)   │
│  ○ 기존 용어: "Hello" → "안녕"       │
│  ○ 새 용어 추가                      │
│                                     │
│  [새 용어 추가 선택 시]                │
│  원문 범위 선택:                      │
│  ┌─────────────────────────────────┐│
│  │ "你好，世界！..." (탭하여 선택)    ││
│  └─────────────────────────────────┘│
│                                     │
│  Source: ________________           │
│  Target: ________________           │
│                                     │
│         [취소]        [저장]         │
└─────────────────────────────────────┘
```

**Presentation Style**:
- `.sheet(isPresented:)` 사용
- `.presentationDetents([.medium, .large])` - 중간 크기 기본, 확장 가능
- `.presentationDragIndicator(.visible)` - 드래그 인디케이터 표시

**바텀시트 상태 관리**:
```swift
// BrowserViewModel에 추가
@Published var glossaryAddSheet: GlossaryAddSheetState? = nil

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

**후보 제시 UI**:
- 최상위 후보 자동 선택 (기본값)
- 라디오 버튼 리스트로 다른 후보 선택 가능
- 각 후보 표시 형식: `"[source]" → "[target]" (Line [line], 우선순위 [rank])`
- 기존 전체 용어 목록도 하단에 표시 (접을 수 있는 섹션)

---

## 4. 기술 구현 계획

### 4.1 아키텍처 흐름

```
SelectableTextView (UITextView)
  ↓ 사용자 선택 + 컨텍스트 메뉴
BrowserViewModel.onGlossaryAddRequested(text:range:section:)
  ↓ 컨텍스트 분석
buildGlossaryAddSheetState(...)
  ↓
- 원문 선택 → 하이라이팅 범위 비교
- 번역문 선택 → 매칭되지 않은 용어 추출
  ↓
glossaryAddSheet 상태 설정
  ↓
GlossaryAddSheet (SwiftUI View)
  ↓ 사용자 입력
GlossaryAddViewModel.save()
  ↓
SwiftData 업데이트 (modelContext)
  ↓
번역 재실행 (선택적)
```

### 4.2 핵심 컴포넌트

#### 4.2.1 SelectableTextView 확장

**파일**: `MyTranslation/Presentation/Browser/View/SelectableTextView.swift`

**변경사항**:
```swift
struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    var onAddToGlossary: ((String, NSRange, SectionType) -> Void)? = nil

    enum SectionType {
        case original
        case primaryFinal
        case primaryPreNormalized
        case alternative(engineID: String)
    }

    // ... 기존 코드

    class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        var parent: SelectableTextView

        func makeUIView(context: Context) -> UITextView {
            // ... 커스텀 메뉴 구성
        }
    }
}
```

#### 4.2.2 BrowserViewModel 확장

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

#### 4.2.3 GlossaryAddSheet (SwiftUI View)

**파일**: `MyTranslation/Presentation/Browser/View/GlossaryAddSheet.swift` (신규)

**구조**:
```swift
struct GlossaryAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let state: GlossaryAddSheetState
    @StateObject private var viewModel: GlossaryAddViewModel

    init(state: GlossaryAddSheetState, modelContext: ModelContext) {
        self.state = state
        _viewModel = StateObject(wrappedValue: GlossaryAddViewModel(
            state: state,
            modelContext: modelContext
        ))
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
            .navigationTitle("용어집에 추가")
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

    @ViewBuilder
    private func originalTextSection(text: String, termID: String?) -> some View {
        if let termID = termID {
            // 기존 용어 편집
            Section("기존 용어 편집") {
                // TermEditorView 임베딩 또는 간소화된 편집 UI
                Text("용어: \(termID)")
                TextField("Variants 추가", text: $viewModel.newVariant)
            }
        } else {
            // 새 용어 추가
            Section("새 용어 추가") {
                TextField("Source (원문)", text: $viewModel.newSource)
                TextField("Target (번역)", text: $viewModel.newTarget)
            }
        }
    }

    @ViewBuilder
    private func translatedTextSection(
        text: String,
        candidates: [UnmatchedTermCandidate],
        existingTerms: [GlossaryEntry]
    ) -> some View {
        Section("매칭할 용어 선택") {
            if !candidates.isEmpty {
                ForEach(candidates.indices, id: \.self) { index in
                    let candidate = candidates[index]
                    HStack {
                        Button {
                            viewModel.selectCandidate(candidate)
                        } label: {
                            HStack {
                                Image(systemName: viewModel.selectedCandidateID == candidate.entry.source ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading) {
                                    Text("\"\(candidate.entry.source)\" → \"\(candidate.entry.target)\"")
                                        .font(.body)
                                    Text("등장 순서: \(candidate.appearanceOrder), 유사도: \(String(format: "%.0f%%", candidate.similarity * 100))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            DisclosureGroup("기존 모든 용어에서 선택") {
                ForEach(existingTerms, id: \.source) { term in
                    Button {
                        viewModel.selectExistingTerm(term)
                    } label: {
                        HStack {
                            Image(systemName: viewModel.selectedCandidateID == term.source ? "largecircle.fill.circle" : "circle")
                            Text("\"\(term.source)\" → \"\(term.target)\"")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                viewModel.selectNewTerm()
            } label: {
                HStack {
                    Image(systemName: viewModel.isCreatingNewTerm ? "largecircle.fill.circle" : "circle")
                    Text("새 용어 추가")
                }
            }
            .buttonStyle(.plain)
        }

        if viewModel.isCreatingNewTerm {
            Section("새 용어 정보") {
                // 원문 범위 선택 UI
                Text("원문에서 범위 선택:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // TODO: 인터랙티브 텍스트 선택 UI 구현
                Text(viewModel.fullOriginalText)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)

                TextField("Source (원문)", text: $viewModel.newSource)
                TextField("Target (번역)", text: $viewModel.newTarget)
            }
        }
    }

    @ViewBuilder
    private var actionButtonsSection: some View {
        Section {
            Button {
                Task {
                    await viewModel.save()
                    dismiss()
                }
            } label: {
                HStack {
                    Spacer()
                    Text("저장")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(!viewModel.canSave)
        }
    }
}
```

#### 4.2.4 GlossaryAddViewModel

**파일**: `MyTranslation/Presentation/Browser/ViewModel/GlossaryAddViewModel.swift` (신규)

```swift
@MainActor
class GlossaryAddViewModel: ObservableObject {
    private let state: GlossaryAddSheetState
    private let modelContext: ModelContext

    @Published var selectedCandidateID: String? = nil
    @Published var isCreatingNewTerm: Bool = false
    @Published var newSource: String = ""
    @Published var newTarget: String = ""
    @Published var newVariant: String = ""

    var fullOriginalText: String {
        // 전체 원문 제공 (ViewModel에서 전달받음)
        ""
    }

    var canSave: Bool {
        if isCreatingNewTerm {
            return !newSource.isEmpty && !newTarget.isEmpty
        } else {
            return selectedCandidateID != nil
        }
    }

    init(state: GlossaryAddSheetState, modelContext: ModelContext) {
        self.state = state
        self.modelContext = modelContext

        // 번역문 선택 시 최상위 후보 자동 선택
        if case .translatedText(_, let candidates, _) = state.context,
           let firstCandidate = candidates.first {
            self.selectedCandidateID = firstCandidate.entry.source
        }
    }

    func selectCandidate(_ candidate: UnmatchedTermCandidate) {
        selectedCandidateID = candidate.entry.source
        isCreatingNewTerm = false
    }

    func selectExistingTerm(_ term: GlossaryEntry) {
        selectedCandidateID = term.source
        isCreatingNewTerm = false
    }

    func selectNewTerm() {
        selectedCandidateID = nil
        isCreatingNewTerm = true
    }

    func save() async {
        if isCreatingNewTerm {
            await createNewTerm()
        } else if let candidateID = selectedCandidateID {
            await addVariantToExistingTerm(candidateID: candidateID)
        }
    }

    private func createNewTerm() async {
        // SwiftData에 새 SDTerm 추가
        let newTerm = SDTerm(context: modelContext)
        newTerm.target = newTarget

        let newSource = SDSource(context: modelContext)
        newSource.text = self.newSource
        newSource.allow = true
        newTerm.addToSourcesOK(newSource)

        try? modelContext.save()
    }

    private func addVariantToExistingTerm(candidateID: String) async {
        // SwiftData에서 해당 Term 조회 및 variants 업데이트
        let descriptor = FetchDescriptor<SDTerm>(
            predicate: #Predicate { term in
                term.sourcesOK.contains { $0.text == candidateID }
            }
        )

        guard let existingTerm = try? modelContext.fetch(descriptor).first else {
            return
        }

        // variants에 선택한 텍스트 추가
        // (variants는 SDSource로 관리하거나 별도 필드 사용)
        // TODO: 실제 데이터 모델에 맞게 구현

        try? modelContext.save()
    }
}
```

### 4.3 데이터 흐름 상세

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

4. UI 표시
   BrowserRootView에서 sheet 바인딩
   → GlossaryAddSheet 표시
   ↓

5. 사용자 입력
   GlossaryAddSheet → GlossaryAddViewModel
   → 후보 선택 또는 새 용어 입력
   ↓

6. 저장
   GlossaryAddViewModel.save()
   → SwiftData 업데이트
   → modelContext.save()
   ↓

7. 후처리
   바텀시트 닫기
   → 번역 재실행 (선택적)
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
1. `MyTranslation/Presentation/Browser/View/SelectableTextView.swift`
   - 컨텍스트 메뉴 추가
   - onAddToGlossary 콜백 추가

2. `MyTranslation/Presentation/Browser/View/OverlayPanelView.swift`
   - SelectableTextView에 onAddToGlossary 콜백 전달

3. `MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel.swift`
   - `@Published var glossaryAddSheet: GlossaryAddSheetState?` 추가

4. `MyTranslation/Presentation/Browser/View/BrowserRootView.swift`
   - `.sheet(item: $vm.glossaryAddSheet)` 바인딩 추가

5. `MyTranslation/Domain/Models/TermHighlightMetadata.swift`
   - `matchingTermID(for:)` 메서드 추가
   - `unmatchedTerms()` 메서드 추가

### 5.3 핵심 메서드 시그니처

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
}

// GlossaryAddViewModel.swift
@MainActor
class GlossaryAddViewModel: ObservableObject {
    func selectCandidate(_ candidate: UnmatchedTermCandidate)
    func selectExistingTerm(_ term: GlossaryEntry)
    func selectNewTerm()
    func save() async

    private func createNewTerm() async
    private func addVariantToExistingTerm(candidateID: String) async
}

// TermHighlightMetadata+Extensions.swift
extension TermHighlightMetadata {
    func matchingTermID(for nsRange: NSRange) -> String?
    func unmatchedTerms() -> [GlossaryEntry]
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
6. "저장" 버튼 클릭
7. 바텀시트 닫힘
8. 번역 재실행 (선택적)
9. 오버레이에서 새 variants 적용 확인
```

#### 시나리오 2: 원문 선택 → 기존 용어 편집
```
1. 오버레이 패널 열기
2. 원문에서 하이라이팅된 용어 선택
3. "용어집에 추가" 선택
4. 바텀시트에서 기존 용어 편집 모드 확인
5. variants 입력 필드에 새 값 입력
6. "저장" 클릭
7. 바텀시트 닫힘
8. 번역 재실행 후 적용 확인
```

#### 시나리오 3: 번역문 선택 → 새 용어 추가
```
1. 오버레이 패널 열기
2. 번역문에서 텍스트 선택
3. "용어집에 추가" 선택
4. 바텀시트에서 "새 용어 추가" 라디오 버튼 선택
5. 원문 범위 선택 UI에서 텍스트 선택
6. source, target 입력
7. "저장" 클릭
8. SwiftData에 새 Term 추가 확인
9. 번역 재실행 후 적용 확인
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
**버전**: 1.0
**상태**: 초안
