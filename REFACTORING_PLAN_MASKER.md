# Masker.swift 리팩토링 계획

## 개요

Masker.swift (2,110줄)를 TextEntityProcessing 모듈로 분할하는 리팩토링 계획입니다.

## 현재 상태

### 파일 정보
- **위치**: `MyTranslation/Core/Masking/Masker.swift`
- **라인 수**: 2,110줄
- **주요 클래스**: `TermMasker` (단일 클래스에 모든 로직 집중)
- **변경 후**: `TextEntityProcessor` (Facade 패턴으로 재구성)

### 관련 파일
- `LockInfo.swift` (22줄) - 토큰-용어 매핑 정보
- `MaskedPack.swift` (17줄) - 마스킹 결과 묶음
- `TermActivationFilter.swift` (21줄) - 용어 비활성화 판단

### 주요 책임 영역

현재 TermMasker가 모두 담당:
1. 세그먼트 분석 - 세그먼트에서 용어/패턴 감지
2. SegmentPieces 조립 - 텍스트를 term/text 조각 배열로 분할
3. GlossaryEntry 조합 - 패턴 기반 용어 조합 생성
4. 마스킹/언마스킹 - 토큰 생성 및 복원
5. 정규화 - 변형 → 표준형 정규화
6. 한국어 조사 처리 - 받침 판별 및 조사 선택/보정

## 최종 목표 구조

```
Core/
  TextEntityProcessing/
    Models/
      NameGlossary.swift
      LockInfo.swift
      MaskedPack.swift
      SegmentGlossaryModels/
        AppearedTerm.swift
        AppearedComponent.swift
    Engines/
      SegmentTermMatcher.swift
      SegmentEntriesBuilder.swift
      SegmentPiecesBuilder.swift
      MaskingEngine.swift
      NormalizationEngine.swift
    Rules/
      KoreanParticleRules.swift
    TextEntityProcessor.swift  (Facade)
```

## 실행 계획

### 확정된 옵션
1. **TermActivationFilter 제거**: SegmentTermMatcher 내부로 로직 인라인 이동
2. **실행 범위**: 전체 10단계 순차 진행
3. **폴더명 변경 시점**: Phase 0에서 먼저 변경

### Phase 0: 폴더명 변경

**목표**: 작업 전에 폴더명을 먼저 변경

**변경**:
```
Core/Masking/ → Core/TextEntityProcessing/
```

**영향 파일**:
- Masker.swift → Core/TextEntityProcessing/Masker.swift
- LockInfo.swift → Core/TextEntityProcessing/LockInfo.swift
- MaskedPack.swift → Core/TextEntityProcessing/MaskedPack.swift
- TermActivationFilter.swift → Core/TextEntityProcessing/TermActivationFilter.swift

**검증**:
1. 파일 이동 완료 확인
2. `swift build` 성공
3. 테스트 실행

### Phase 1: Models 분리

#### Phase 1-1: KoreanParticleRules 분리

**파일**: `Core/TextEntityProcessing/Rules/KoreanParticleRules.swift`

**이동 대상**:
- `hangulFinalJongInfo(_:)` 전역 함수
- 조사 규칙: `JosaPair`, `josaPairs`, `chooseJosa()`, `fixParticles()`
- 공백 규칙: `collapseSpaces_...()`, String 확장
- 정규식: `particleTokenAlternation`, `particleTokenRegex` 등

**공개 API**:
```swift
public enum KoreanParticleRules {
    public static func hangulFinalJongInfo(_ s: String) -> (hasBatchim: Bool, isRieul: Bool)
    public static func chooseJosa(basedOn: String, pair: JosaPair) -> String
    public static func fixParticles(in text: String, canonical: String, at range: Range<String.Index>) -> String
    public static func collapseSpaces_PunctOrEdge_whenIsolatedSegment(_ text: String) -> String
}
```

**테스트 이동**:

새 파일: `MyTranslationTests/Core/TextEntityProcessing/Rules/KoreanParticleRulesTests.swift`

TermMaskerUnitTests.swift에서 다음 테스트 이동:
- `chooseJosaResolvesCompositeParticles()` - chooseJosa() 테스트
- `collapseSpacesWhenIsolatedSegmentRemovesExtraSpaces()` - collapseSpaces_PunctOrEdge_whenIsolatedSegment() 테스트
- `collapseSpacesWhenIsolatedSegmentKeepsParticles()` - collapseSpaces_PunctOrEdge_whenIsolatedSegment() 테스트

테스트 업데이트 사항:
- `let masker = TermMasker()` → 직접 KoreanParticleRules 사용
- `masker.chooseJosa()` → `KoreanParticleRules.chooseJosa()`
- `masker.collapseSpaces_...()` → `KoreanParticleRules.collapseSpaces_...()`

#### Phase 1-2: NameGlossary 모델 분리

**파일**: `Core/TextEntityProcessing/Models/NameGlossary.swift`

**이동 대상**:
- `struct NameGlossary`
- `struct NameGlossary.FallbackTerm`

**중요**: 중첩 타입 `TermMasker.NameGlossary` → 독립 타입 `NameGlossary`로 변경

**마이그레이션**:
1. 새 파일 생성 및 타입 정의
2. `DefaultTranslationRouter+Masking.swift` 업데이트: `TermMasker.NameGlossary` → `NameGlossary`
3. `MaskingContext` 타입 업데이트
4. TermMasker에서 중첩 타입 제거

#### Phase 1-3: AppearedTerm/AppearedComponent 분리

**파일**:
- `Core/TextEntityProcessing/Models/SegmentGlossaryModels/AppearedTerm.swift`
- `Core/TextEntityProcessing/Models/SegmentGlossaryModels/AppearedComponent.swift`

**이동 대상**:
- `struct AppearedTerm`
- `struct AppearedComponent`

**접근 제어**: `internal` (TermMasker 내부에서만 사용)

**테스트 이동**: 해당 없음 (internal 타입이므로 직접 테스트 없음)

### Phase 2: 세그먼트 분석 엔진 분리

#### Phase 2-1: SegmentTermMatcher 분리 + TermActivationFilter 제거

**파일**: `Core/TextEntityProcessing/Engines/SegmentTermMatcher.swift`

**이동 대상**:
- `deactivatedContexts(of:)`
- `allOccurrences(of:in:)`
- `makeComponentTerm()`
- AppearedTerm/Component 생성 로직

**TermActivationFilter 제거** (인라인 방식):

현재:
```swift
// TermActivationFilter.swift
public func shouldDeactivate(source: String, deactivatedIn: [String], segmentText: String) -> Bool

// DefaultTranslationRouter+Masking.swift
let termActivationFilter = TermActivationFilter()
termMasker.buildSegmentPieces(..., termActivationFilter: termActivationFilter)
```

변경 후:
```swift
// SegmentTermMatcher.swift - findAppearedTerms 내부
let activeSourcesForTerm = matchedSources[term.key]?.filter { source in
    let deactivatedContexts = term.deactivatedIn
    if deactivatedContexts.isEmpty { return true }
    for ctx in deactivatedContexts where !ctx.isEmpty {
        if segment.originalText.contains(ctx) { return false }
    }
    return true
}

// DefaultTranslationRouter+Masking.swift
termMasker.buildSegmentPieces(...)  // termActivationFilter 파라미터 제거
```

**변경 사항**:
1. TermActivationFilter.swift 파일 삭제
2. 로직을 SegmentTermMatcher 내부로 인라인
3. `buildSegmentPieces()` 시그니처에서 파라미터 제거
4. DefaultTranslationRouter+Masking.swift 업데이트

**검증**: MaskerSpecTests.swift의 SPEC_TERM_DEACTIVATION 테스트 통과

**테스트 이동**: 해당 없음 (internal 엔진이며, buildSegmentPieces 통합 테스트로 검증됨)

#### Phase 2-2: SegmentEntriesBuilder 분리

**파일**: `Core/TextEntityProcessing/Engines/SegmentEntriesBuilder.swift`

**이동 대상**:
- `buildComposerEntries()`
- `matchedPairs()`
- `matchedLeftComponents()`
- `buildEntriesFromPairs()`
- `buildEntriesFromLefts()`
- `filterBySourceOcc()`
- `matchesRole()`

#### Phase 2-3: SegmentPiecesBuilder 분리

**파일**: `Core/TextEntityProcessing/Engines/SegmentPiecesBuilder.swift`

**이동 대상**:
- `buildSegmentPieces()` 핵심 로직 (텍스트 쪼개기, 겹침 조정)

**마이그레이션 전략**:
- TermMasker에 Facade 메서드 유지
- 내부에서 Matcher → EntriesBuilder → PiecesBuilder 순서로 호출

**테스트 이동**:

새 파일: `MyTranslationTests/Core/TextEntityProcessing/Engines/SegmentPiecesBuilderTests.swift`

TermMaskerUnitTests.swift에서 다음 테스트 이동:
- `segmentPiecesTracksRanges()` - buildSegmentPieces() 범위 추적 테스트

참고: 이 테스트는 현재 TermMasker를 통해 호출하고 있으므로, 리팩토링 후에도 TermMasker의 Facade 메서드를 통해 호출 가능 (그대로 유지 가능)

### Phase 3: MaskingEngine 분리

**파일**: `Core/TextEntityProcessing/Engines/MaskingEngine.swift`

**이동 대상**:
- 토큰 관리: `nextIndex`, `tokenSpacingBehavior`, `makeToken()`, `extractTokenIDs()`
- 마스킹: `maskFromPieces()`, `surroundTokenWithNBSP()`, `insertSpacesAroundTokens...()`
- 언마스킹: `unlockTermsSafely()`, `unmaskWithOrder()`, `normalizeTokensAndParticles()`, `normalizeDamagedETokens()`

**공개 API**:
```swift
public final class MaskingEngine {
    public var tokenSpacingBehavior: TokenSpacingBehavior
    public init()
    public func maskFromPieces(pieces: SegmentPieces, segment: Segment) -> MaskedPack
    public func unlockTermsSafely(_ text: String, locks: [String: LockInfo]) -> String
}
```

**마이그레이션**:
- TermMasker가 MaskingEngine 인스턴스 보유
- Facade 메서드로 위임

**테스트 이동**:

새 파일: `MyTranslationTests/Core/TextEntityProcessing/Engines/MaskingEngineTests.swift`

TermMaskerUnitTests.swift에서 다음 테스트 이동:
- `normalizeDamagedETokensRestoresCorruptedPlaceholders()` - normalizeDamagedETokens() 테스트
- `normalizeDamagedETokensIgnoresUnknownIds()` - normalizeDamagedETokens() 테스트
- `surroundTokenWithNBSPAddsSpacingAroundLatin()` - surroundTokenWithNBSP() 테스트
- `insertSpacesAroundTokensOnlyForPunctOnlyParagraphs()` - insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass() 테스트
- `insertSpacesAroundTokensKeepsNormalParagraphsUntouched()` - insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass() 테스트
- `normalizeTokensAndParticlesReplacesMultipleTokens()` - normalizeTokensAndParticles() 테스트
- `insertSpacesAroundTokensAddsSpaceNearPunctuation()` - insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass() 테스트

테스트 업데이트 사항:
- `let masker = TermMasker()` → `let engine = MaskingEngine()`
- `masker.normalizeDamagedETokens()` → `engine.normalizeDamagedETokens()`
- `masker.tokenSpacingBehavior` → `engine.tokenSpacingBehavior`
- 기타 MaskingEngine 메서드 직접 호출

### Phase 4: NormalizationEngine 분리

**파일**: `Core/TextEntityProcessing/Engines/NormalizationEngine.swift`

**이동 대상**:
- `normalizeWithOrder()`
- `normalizeVariantsAndParticles()`
- `makeNameGlossaries()`, `makeNameGlossariesFromPieces()`
- 변형 검색: `makeCandidates()`, `findNextCandidate()`, `replaceWithParticleFix()`, `canonicalFor()`

**공개 API**:
```swift
public struct NormalizationEngine {
    public init()
    public func normalizeWithOrder(in text: String, pieces: SegmentPieces, nameGlossaries: [NameGlossary])
        -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange])
    public func makeNameGlossariesFromPieces(pieces: SegmentPieces, allEntries: [GlossaryEntry]) -> [NameGlossary]
}
```

**의존성**: KoreanParticleRules 사용

**테스트 이동**: 해당 없음 (normalizeWithOrder 등의 복잡한 로직은 통합 테스트로 검증되며, 별도 단위 테스트 없음)

### Phase 5: TextEntityProcessor로 변환 (오케스트레이션 레이어)

**목표**: TermMasker를 TextEntityProcessor로 리네이밍하고, 오케스트레이션 로직만 포함하는 경량 레이어로 전환

**변경 사항**:
1. 클래스명: `TermMasker` → `TextEntityProcessor`
2. 파일명: `Masker.swift` → `TextEntityProcessor.swift`
3. **오케스트레이션 로직만 포함** (단순 위임 메서드 제거)

**설계 원칙 (Option B)**:
- `buildSegmentPieces()`: 여러 엔진을 순차적으로 조율하는 **실제 오케스트레이션 로직**이므로 TextEntityProcessor에 유지
- `maskFromPieces()`, `makeNameGlossariesFromPieces()`: 단일 엔진으로의 **단순 위임**이므로 제거
- 외부 코드는 오케스트레이션이 필요한 경우 TextEntityProcessor를 사용하고, 개별 엔진이 필요한 경우 직접 접근

**최종 TextEntityProcessor 구조**:
```swift
public final class TextEntityProcessor {
    private let matcher = SegmentTermMatcher()
    private let entriesBuilder = SegmentEntriesBuilder()
    private let piecesBuilder = SegmentPiecesBuilder()

    public init() { }

    // 오케스트레이션 메서드 (여러 엔진을 순차 조율)
    public func buildSegmentPieces(
        segment: Segment,
        matchedTerms: [SDTerm],
        patterns: [SDPattern],
        matchedSources: [String: Set<String>]
    ) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry]) {
        // Step 1: 세그먼트에서 용어 감지
        let appearedTerms = matcher.findAppearedTerms(...)

        // Step 2: 컴포넌트 감지
        let appearedComponents = matcher.findAppearedComponents(...)

        // Step 3: 패턴 기반 GlossaryEntry 조합
        let entries = entriesBuilder.buildComposerEntries(...)

        // Step 4: SegmentPieces 조립
        let pieces = piecesBuilder.buildSegmentPieces(...)

        return (pieces, entries)
    }
}
```

**외부 참조 업데이트**:

`DefaultTranslationRouter+Masking.swift`:
```swift
// 변경 전
let termMasker = TermMasker()
termMasker.tokenSpacingBehavior = options.tokenSpacingBehavior

let (pieces, glossaryEntries) = termMasker.buildSegmentPieces(...)
let pack = termMasker.maskFromPieces(pieces: pieces, segment: segment)
let nameGlossaries = termMasker.makeNameGlossariesFromPieces(
    pieces: pieces,
    allEntries: glossaryEntries
)

// 변경 후
let processor = TextEntityProcessor()
let maskingEngine = MaskingEngine()
let normalizationEngine = NormalizationEngine()

maskingEngine.tokenSpacingBehavior = options.tokenSpacingBehavior

// 오케스트레이션 로직은 processor 사용
let (pieces, glossaryEntries) = processor.buildSegmentPieces(...)

// 개별 엔진은 직접 사용
let pack = maskingEngine.maskFromPieces(pieces: pieces, segment: segment)
let nameGlossaries = normalizationEngine.makeNameGlossariesFromPieces(
    pieces: pieces,
    allEntries: glossaryEntries
)
```

**제거되는 것들**:
- `maskFromPieces()` 위임 메서드 → MaskingEngine 직접 사용
- `makeNameGlossariesFromPieces()` 위임 메서드 → NormalizationEngine 직접 사용
- `tokenSpacingBehavior` 프로퍼티 위임 → MaskingEngine 직접 설정
- `normalizationEngine` private 필드 (필요 없음)
- `maskingEngine` private 필드 (필요 없음)

**유지되는 것**:
- `buildSegmentPieces()` - 4단계 엔진 조율 로직 (Matcher → EntriesBuilder → PiecesBuilder)
- private 엔진 필드: `matcher`, `entriesBuilder`, `piecesBuilder` (오케스트레이션에 필요)

**테스트 업데이트**:
- TermMaskerUnitTests.swift → TextEntityProcessorTests.swift (단위 테스트)
- MaskerSpecTests.swift → TextEntityProcessorIntegrationTests.swift (통합 테스트)
- `let masker = TermMasker()` → `let processor = TextEntityProcessor()` + 개별 엔진 인스턴스

**이점**:
- 더 명확한 도메인 이름 (Masker → EntityProcessor)
- 불필요한 간접화 제거 - 개별 엔진은 직접 사용
- 실제 가치 있는 오케스트레이션 로직만 유지
- 각 엔진의 책임이 명확히 드러남
- 외부 코드가 필요한 엔진을 명시적으로 선택 가능

### Phase 6: 문서 및 테스트 업데이트

#### PROJECT_OVERVIEW.md 업데이트

**섹션**: "### 6. Masking & Normalization" → "### 6. Text Entity Processing"

**새 내용**:
```markdown
### 6. Text Entity Processing (`Core/TextEntityProcessing/`)

세그먼트에서 용어를 감지하고 마스킹/정규화하는 모듈.

**Models/**
- `NameGlossary`: 정규화용 이름 정보
- `LockInfo`: 토큰-용어 매핑 정보
- `MaskedPack`: 마스킹 결과 묶음
- `AppearedTerm/AppearedComponent`: 세그먼트 분석 결과 (internal)

**Engines/**
- `SegmentTermMatcher`: 세그먼트에서 용어/패턴 감지
- `SegmentEntriesBuilder`: 패턴 기반 GlossaryEntry 조합
- `SegmentPiecesBuilder`: SegmentPieces 조립
- `MaskingEngine`: 토큰화 및 언마스킹
- `NormalizationEngine`: 변형 → 표준형 정규화

**Rules/**
- `KoreanParticleRules`: 한국어 조사 선택 및 공백 관리

**Orchestration Layer**
- `TextEntityProcessor`: 세그먼트 분석 엔진들을 순차 조율 (구 TermMasker)
  - `buildSegmentPieces()`: Matcher → EntriesBuilder → PiecesBuilder 오케스트레이션
  - 개별 엔진(MaskingEngine, NormalizationEngine)은 외부에서 직접 사용
```

#### 테스트 업데이트

**기존 테스트**: MaskerSpecTests.swift - TermMasker API 유지되므로 대부분 변경 불필요

**테스트 파일 재구성**:

기존: `MyTranslationTests/Core/Masking/`
- TermMaskerUnitTests.swift
- MaskerSpecTests.swift

새 구조: `MyTranslationTests/Core/TextEntityProcessing/`
- Rules/KoreanParticleRulesTests.swift (TermMaskerUnitTests에서 이동)
- Engines/MaskingEngineTests.swift (TermMaskerUnitTests에서 이동)
- Engines/SegmentPiecesBuilderTests.swift (선택사항)
- TextEntityProcessorTests.swift (TermMaskerUnitTests 리네이밍)
- TextEntityProcessorIntegrationTests.swift (MaskerSpecTests 리네이밍 + 통합 테스트)

## 실행 순서 요약

0. **Phase 0**: 폴더명 변경 (Masking → TextEntityProcessing)
1. **Phase 1-1**: KoreanParticleRules 분리
2. **Phase 1-2**: NameGlossary 모델 분리 + 외부 참조 업데이트
3. **Phase 1-3**: AppearedTerm/Component 모델 분리
4. **Phase 2-1**: SegmentTermMatcher 분리 + TermActivationFilter 제거 (인라인)
5. **Phase 2-2**: SegmentEntriesBuilder 분리
6. **Phase 2-3**: SegmentPiecesBuilder 분리
7. **Phase 3-1**: MaskingEngine 분리
8. **Phase 4-1**: NormalizationEngine 분리
9. **Phase 5-1**: TextEntityProcessor로 변환 (Facade + 리네이밍)
10. **Phase 6**: 문서 및 테스트 업데이트

## 검증 계획

**각 Phase 후**:
1. `swift build` 성공 확인
2. `swift test` 실행
3. Git diff 검토
4. Phase별 독립 커밋

**최종**:
1. 전체 번역 파이프라인 동작 확인
2. PROJECT_OVERVIEW.md 최신 상태 확인

## 예상 결과

2,110줄의 단일 파일을 8개의 명확한 책임을 가진 모듈로 분할하며, 기존 테스트 코드와 외부 API를 최대한 보존합니다.
