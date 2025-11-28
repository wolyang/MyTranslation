# Masker.swift 리팩토링 계획

## 개요

Masker.swift (2,110줄)를 TextEntityProcessing 모듈로 분할하는 리팩토링 계획입니다.

## 현재 상태

### 파일 정보
- **위치**: `MyTranslation/Core/Masking/Masker.swift`
- **라인 수**: 2,110줄
- **주요 클래스**: `TermMasker` (단일 클래스에 모든 로직 집중)

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
    TermMasker.swift  (Facade)
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

### Phase 5: TermMasker를 Facade로 변환

**최종 TermMasker 구조**:
```swift
public final class TermMasker {
    private let matcher = SegmentTermMatcher()
    private let entriesBuilder = SegmentEntriesBuilder()
    private let piecesBuilder = SegmentPiecesBuilder()
    private let maskingEngine = MaskingEngine()
    private let normalizationEngine = NormalizationEngine()

    public var tokenSpacingBehavior: TokenSpacingBehavior {
        get { maskingEngine.tokenSpacingBehavior }
        set { maskingEngine.tokenSpacingBehavior = newValue }
    }

    public init() { }

    // Facade methods
    public func buildSegmentPieces(
        segment: Segment,
        matchedTerms: [SDTerm],
        patterns: [SDPattern],
        matchedSources: [String: Set<String>]
    ) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry]) {
        let appearedTerms = matcher.findAppearedTerms(...)
        let appearedComponents = matcher.findAppearedComponents(...)
        let entries = entriesBuilder.buildComposerEntries(...)
        let pieces = piecesBuilder.buildSegmentPieces(...)
        return (pieces, entries)
    }

    public func maskFromPieces(pieces: SegmentPieces, segment: Segment) -> MaskedPack {
        maskingEngine.maskFromPieces(pieces: pieces, segment: segment)
    }

    public func makeNameGlossariesFromPieces(pieces: SegmentPieces, allEntries: [GlossaryEntry]) -> [NameGlossary] {
        normalizationEngine.makeNameGlossariesFromPieces(pieces: pieces, allEntries: allEntries)
    }
}
```

**이점**:
- 외부 API 변경 최소화
- 기존 테스트 대부분 유지
- 각 엔진 개별 테스트 가능

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

**Facade**
- `TermMasker`: 외부 API용 조정 레이어
```

#### 테스트 업데이트

**기존 테스트**: MaskerSpecTests.swift - TermMasker API 유지되므로 대부분 변경 불필요

**새 테스트 파일**:
- `KoreanParticleRulesTests.swift`
- `MaskingEngineTests.swift`
- `NormalizationEngineTests.swift`

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
9. **Phase 5-1**: TermMasker를 Facade로 변환
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
