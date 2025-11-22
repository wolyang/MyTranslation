# SPEC: 테스트 강화 계획

- **작성일**: 2025-01-22
- **최종 수정**: 2025-01-22
- **상태**: Planning
- **우선순위**: P0 (Critical)
- **관련 TODO**: 프로젝트 전체 테스트 커버리지 향상

---

## 1. 개요

### 1.1 목적
MyTranslation 프로젝트의 테스트 커버리지를 현재 5%에서 70%+로 향상시켜 코드 안정성, 유지보수성, 리팩토링 안전성을 확보한다.

### 1.2 범위
- **Phase 1**: 핵심 비즈니스 로직 (DefaultTranslationRouter, TermMasker)
- **Phase 2**: 번역 엔진 및 캐시
- **Phase 3**: 상태 관리 및 서비스
- **Phase 4**: 통합 및 UI 테스트

### 1.3 핵심 요구사항
1. **Mock 인프라 구축**: 테스트 작성을 위한 재사용 가능한 Mock 클래스
2. **완전한 단위 테스트**: 핵심 로직의 모든 분기 및 Edge case 커버
3. **통합 테스트**: 전체 번역 파이프라인의 end-to-end 검증
4. **UI 테스트**: 주요 사용자 워크플로우 검증

---

## 2. 배경 및 동기

### 2.1 현재 상태
**테스트 파일**: 3개만 존재
- `MyTranslationTests.swift` (663줄): Content Extraction, Term Masking 일부, Glossary Import
- `MyTranslationUITests.swift` (42줄): 빈 UI 테스트
- `MyTranslationUITestsLaunchTests.swift` (34줄): 실행 스크린샷만

**테스트 커버리지**: 약 5%
- ✅ 테스트됨: WKContentExtractor, TermMasker 일부, GlossaryUpserter
- ❌ 미테스트: 번역 엔진, 번역 라우터, 캐시, ViewModel, FM Pipeline, API 클라이언트 등

### 2.2 문제점
1. **낮은 신뢰성**: 핵심 비즈니스 로직이 테스트되지 않아 배포 시 리스크 높음
2. **리팩토링 곤란**: 테스트 부재로 코드 수정 시 회귀 버그 발생 가능성 높음
3. **디버깅 어려움**: 버그 발생 시 원인 파악에 시간 소요
4. **통합 이슈**: 전체 파이프라인 테스트 부재로 컴포넌트 간 통합 오류 사전 탐지 불가

### 2.3 기대 효과
1. **안정성 향상**: 배포 전 80% 버그 탐지, 95% 회귀 방지
2. **개발 속도 향상**: Mock 인프라로 테스트 작성 속도 3배 증가
3. **리팩토링 안전성**: 테스트 커버리지로 70% 안전한 코드 수정
4. **코드 품질**: 테스트 가능한 구조로 설계 개선

---

## 3. 현황 분석

### 3.1 테스트 커버리지 분석

#### 테스트된 영역 (5%)
| 모듈 | 파일 | 테스트 내용 | 커버리지 |
|------|------|------------|---------|
| WKContentExtractor | MyTranslationTests.swift | 세그먼트 추출 로직 (6개 테스트) | 80% |
| TermMasker | MyTranslationTests.swift | 마스킹/정규화 일부 (11개 테스트) | 30% |
| GlossaryUpserter | MyTranslationTests.swift | Glossary import (3개 테스트) | 70% |
| WebViewInlineReplacer | MyTranslationTests.swift | 스크립트 생성 확인 (1개 테스트) | 20% |
| SelectionBridge | MyTranslationTests.swift | 세그먼트 ID 태깅 (1개 테스트) | 20% |

#### 미테스트 영역 (95%)

**P0 (Critical) - 핵심 비즈니스 로직**
| 파일 | 라인 수 | 리스크 | 테스트 우선순위 |
|------|---------|--------|----------------|
| DefaultTranslationRouter.swift | 616 | 매우 높음 | 1 |
| AFMEngine.swift | - | 높음 | 2 |
| GoogleEngine.swift | - | 높음 | 2 |
| DeepLEngine.swift | - | 높음 | 2 |
| TermMasker.swift (미테스트 부분) | ~1200 | 높음 | 1 |
| Glossary.swift (buildEntries) | - | 중간 | 3 |

**P1 (High) - 상태 관리 및 통합**
| 파일 | 라인 수 | 리스크 | 테스트 우선순위 |
|------|---------|--------|----------------|
| BrowserViewModel.swift | 276 | 높음 | 4 |
| BrowserViewModel+Translation.swift | - | 높음 | 4 |
| DefaultCacheStore.swift | 27 | 중간 | 5 |
| FMOrchestrator.swift | - | 중간 | 6 |
| FMPostEditor.swift | - | 중간 | 6 |
| CrossEngineComparer.swift | - | 중간 | 6 |
| Reranker.swift | - | 중간 | 6 |

**P2 (Medium) - UI 및 헬퍼**
| 파일 | 리스크 | 테스트 우선순위 |
|------|--------|----------------|
| OverlayRenderer.swift | 낮음 | 7 |
| GlossaryViewModel.swift | 낮음 | 8 |
| TermEditorViewModel.swift | 낮음 | 8 |
| GlossarySDModel.swift | 낮음 | 9 |
| GoogleTranslateV2Client.swift | 중간 | 9 |
| DeepLTranslateClient.swift | 중간 | 9 |

### 3.2 테스트 품질 이슈

#### 이슈 1: 테스트 격리 부족
- GlossaryImportTests에서 ModelContext 매번 생성하지만 테스트 간 데이터 격리 미확인
- BrowserViewModel 테스트 부재로 Mock 인프라 미구축

#### 이슈 2: Edge Case 테스트 부족
- WKContentExtractor: 정상 케이스만, 오류 상황 (빈 페이지, JS 실행 실패) 미테스트
- TermMasker: 극단적 입력 (빈 문자열, 매우 긴 텍스트, 특수문자) 미테스트

#### 이슈 3: 통합 테스트 부재
- 전체 번역 파이프라인 (추출 → 마스킹 → 번역 → 정규화 → 렌더링) 통합 테스트 없음
- 엔진 전환, 캐시 히트/미스 시나리오 미테스트

#### 이슈 4: 비동기 테스트 패턴 일관성
- 일부 테스트만 `async throws` 사용
- Task 취소, 타임아웃 시나리오 미테스트

#### 이슈 5: UI 테스트 공백
- MyTranslationUITests는 실질적으로 비어있음
- 주요 UI 워크플로우 미테스트

---

## 4. 해결 방안

### 4.1 전체 아키텍처

```
MyTranslationTests/
├── Mocks/                          # Mock 클래스 (Phase 1에서 구축)
│   ├── MockTranslationEngine.swift
│   ├── MockCacheStore.swift
│   └── MockGlossaryService.swift
├── Fixtures/                       # 테스트 데이터
│   └── TestFixtures.swift
├── UnitTests/                      # 단위 테스트
│   ├── TranslationRouterTests.swift
│   ├── TermMaskerTests.swift (기존 확장)
│   ├── TranslationEnginesTests.swift
│   ├── CacheStoreTests.swift
│   ├── BrowserViewModelTests.swift
│   ├── GlossaryServiceTests.swift
│   └── WebRenderingTests.swift
└── IntegrationTests/               # 통합 테스트
    └── TranslationPipelineTests.swift

MyTranslationUITests/
├── BrowserUITests.swift            # 브라우저 UI 테스트
└── GlossaryUITests.swift           # Glossary UI 테스트
```

### 4.2 Phase별 상세 계획

---

## Phase 1: 핵심 비즈니스 로직 테스트 (4-5주)

### 목표
DefaultTranslationRouter와 TermMasker를 완전히 테스트하여 번역 파이프라인의 신뢰성 확보

### 액션 1.1: Mock 인프라 구축

**파일**: `MyTranslationTests/Mocks/MockTranslationEngine.swift`

```swift
final class MockTranslationEngine: TranslationEngine {
    let tag: EngineTag

    // Configuration
    var shouldThrowError: Bool = false
    var errorToThrow: Error?
    var translationDelay: TimeInterval = 0
    var resultsToReturn: [TranslationResult] = []
    var streamedResults: [[TranslationResult]] = []

    // Call tracking
    private(set) var translateCallCount = 0
    private(set) var lastRunID: String?
    private(set) var lastSegments: [Segment]?
    private(set) var lastOptions: TranslationOptions?

    func translate(runID: String, _ segments: [Segment], options: TranslationOptions)
        async throws -> AsyncThrowingStream<[TranslationResult], Error>
}
```

**파일**: `MyTranslationTests/Mocks/MockCacheStore.swift`

```swift
final class MockCacheStore: CacheStore {
    private var store: [String: TranslationResult] = [:]

    // Call tracking
    private(set) var lookupCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var lastLookupKey: String?
    private(set) var lastSaveKey: String?

    // Configuration
    var shouldReturnNil: Bool = false

    func lookup(key: String) -> TranslationResult?
    func save(result: TranslationResult, forKey key: String)
    func clearAll()
    func clearBySegmentIDs(_ ids: [String])
}
```

**파일**: `MyTranslationTests/Fixtures/TestFixtures.swift`

```swift
enum TestFixtures {
    // Sample Segments
    static var sampleSegments: [Segment]
    static var japaneseSegments: [Segment]
    static var koreanSegments: [Segment]

    // Sample Translation Results
    static var sampleTranslationResults: [TranslationResult]

    // Sample Translation Options
    static var defaultOptions: TranslationOptions

    // Helper functions
    static func makeSegment(...) -> Segment
    static func makeTranslationResult(...) -> TranslationResult
    static func makeTranslationOptions(...) -> TranslationOptions
}
```

**기대 효과**:
- 테스트 작성 속도 3배 향상
- 테스트 코드 중복 70% 감소
- 테스트 가독성 향상

### 액션 1.2: TermMasker 완전 커버리지

**파일**: `MyTranslationTests/MyTranslationTests.swift` (기존 파일 확장)

**추가 테스트 케이스**:

```swift
// 1. promoteProhibitedEntries 테스트 (Pattern 기반 활성화)
func testPromoteProhibitedEntries_WithComposerPattern() async throws
func testPromoteProhibitedEntries_EmptyPattern() async throws
func testPromoteProhibitedEntries_MultipleMatches() async throws

// 2. promoteActivatedEntries 테스트 (Term-to-Term 활성화)
func testPromoteActivatedEntries_TermToTerm() async throws
func testPromoteActivatedEntries_NoMatches() async throws
func testPromoteActivatedEntries_CaseInsensitive() async throws

// 3. buildSegmentPieces 전체 파이프라인
func testBuildSegmentPieces_FullPipeline() async throws
func testBuildSegmentPieces_EmptyInput() async throws
func testBuildSegmentPieces_NoGlossary() async throws
func testBuildSegmentPieces_VeryLongText() async throws

// 4. surroundTokenWithNBSP (토큰 공백 삽입)
func testSurroundTokenWithNBSP_CJKContext() async throws
func testSurroundTokenWithNBSP_NonCJKContext() async throws
func testSurroundTokenWithNBSP_EdgeOfString() async throws

// 5. normalizeDamagedETokens (손상된 토큰 복구)
func testNormalizeDamagedETokens_AllPatterns() async throws
func testNormalizeDamagedETokens_NoMatch() async throws
func testNormalizeDamagedETokens_MultipleOccurrences() async throws

// 6. insertSpacesAroundTokens
func testInsertSpacesAroundTokens_IsolatedSegments() async throws
func testInsertSpacesAroundTokens_Disabled() async throws

// 7. collapseSpaces
func testCollapseSpaces_PunctOrEdge() async throws
func testCollapseSpaces_MultipleConsecutiveSpaces() async throws

// 8. Edge Cases
func testTermMasker_EmptySegment() async throws
func testTermMasker_VeryLongSegment() async throws
func testTermMasker_SpecialCharacters() async throws
func testTermMasker_UnicodeEdgeCases() async throws
```

**기대 효과**:
- TermMasker 커버리지: 30% → 90%
- 용어 처리 정확도 90% 보장
- Edge case 버그 사전 탐지

### 액션 1.3: DefaultTranslationRouter 단위 테스트

**파일**: `MyTranslationTests/UnitTests/TranslationRouterTests.swift`

**테스트 케이스**:

```swift
final class TranslationRouterTests: XCTestCase {
    var router: DefaultTranslationRouter!
    var mockEngine: MockTranslationEngine!
    var mockCache: MockCacheStore!

    override func setUp() async throws {
        mockEngine = MockTranslationEngine(tag: .google)
        mockCache = MockCacheStore()
        router = DefaultTranslationRouter(
            engine: mockEngine,
            cache: mockCache
        )
    }

    // MARK: - Cache Tests

    func testCacheHit_ReturnsPayloadImmediately() async throws {
        // Given: 캐시에 결과가 있을 때
        let segment = TestFixtures.sampleSegments[0]
        let cachedResult = TestFixtures.sampleTranslationResults[0]
        let cacheKey = makeCacheKey(segment)
        mockCache.preloadCache(with: [cacheKey: cachedResult])

        // When: 번역 요청
        let results = try await collectStream(
            router.translate([segment], options: TestFixtures.defaultOptions)
        )

        // Then: 캐시 결과 반환, 엔진 호출 없음
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].text, cachedResult.text)
        XCTAssertEqual(mockCache.lookupCallCount, 1)
        XCTAssertEqual(mockEngine.translateCallCount, 0)
    }

    func testCacheMiss_CallsEngine() async throws {
        // Given: 캐시에 결과가 없을 때
        let segment = TestFixtures.sampleSegments[0]
        mockCache.shouldReturnNil = true

        // When: 번역 요청
        let results = try await collectStream(
            router.translate([segment], options: TestFixtures.defaultOptions)
        )

        // Then: 엔진 호출, 결과 캐시 저장
        XCTAssertEqual(mockCache.lookupCallCount, 1)
        XCTAssertEqual(mockEngine.translateCallCount, 1)
        XCTAssertEqual(mockCache.saveCallCount, 1)
    }

    func testCacheKeyGeneration_WithDifferentOptions() async throws {
        // Given: 다른 옵션으로 동일 세그먼트 번역
        let segment = TestFixtures.sampleSegments[0]
        let options1 = TestFixtures.makeTranslationOptions(style: .neutralDictionaryTone)
        let options2 = TestFixtures.makeTranslationOptions(style: .colloquialKo)

        // When: 두 번 번역
        _ = try await collectStream(router.translate([segment], options: options1))
        _ = try await collectStream(router.translate([segment], options: options2))

        // Then: 다른 캐시 키 생성, 엔진 2회 호출
        XCTAssertEqual(mockEngine.translateCallCount, 2)
    }

    // MARK: - Streaming Tests

    func testTranslateStream_EmitsEventsInCorrectOrder() async throws {
        // Given: 스트리밍 결과 설정
        let segments = TestFixtures.sampleSegments
        mockCache.shouldReturnNil = true
        mockEngine.configureTo(streamResults: [
            [TestFixtures.sampleTranslationResults[0]],
            [TestFixtures.sampleTranslationResults[1]],
            [TestFixtures.sampleTranslationResults[2]]
        ])

        // When: 스트림 수집
        var events: [[TranslationResult]] = []
        for try await batch in router.translate(segments, options: TestFixtures.defaultOptions) {
            events.append(batch)
        }

        // Then: 순서대로 수신
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0][0].segmentID, "seg1")
        XCTAssertEqual(events[1][0].segmentID, "seg2")
        XCTAssertEqual(events[2][0].segmentID, "seg3")
    }

    func testTranslateStream_HandlesEngineFailure() async throws {
        // Given: 엔진 오류 설정
        mockCache.shouldReturnNil = true
        mockEngine.configureTo(throwError: TranslationEngineError.emptySegments)

        // When/Then: 오류 전파
        do {
            _ = try await collectStream(
                router.translate(TestFixtures.sampleSegments, options: TestFixtures.defaultOptions)
            )
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error is TranslationEngineError)
        }
    }

    func testTranslateStream_SupportsCancellation() async throws {
        // Given: 지연된 번역 설정
        mockCache.shouldReturnNil = true
        mockEngine.translationDelay = 2.0

        // When: Task 취소
        let task = Task {
            try await collectStream(
                router.translate(TestFixtures.sampleSegments, options: TestFixtures.defaultOptions)
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1초 대기
        task.cancel()

        // Then: Task 취소됨
        do {
            _ = try await task.value
            XCTFail("Should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Masking/Normalization Tests

    func testMaskingContext_BuildsCorrectly() async throws {
        // Given: Glossary 적용 옵션
        let options = TestFixtures.makeTranslationOptions(applyGlossary: true)
        mockCache.shouldReturnNil = true

        // When: 번역 실행
        _ = try await collectStream(router.translate(TestFixtures.sampleSegments, options: options))

        // Then: 마스킹 컨텍스트 전달 확인
        XCTAssertNotNil(mockEngine.lastOptions)
        XCTAssertTrue(mockEngine.lastOptions!.applyGlossary)
    }

    func testRestoreOutput_AppliesUnmaskingAndNormalization() async throws {
        // Given: 마스킹된 번역 결과
        // When: 정규화 적용
        // Then: 올바른 복원 확인
        // (구체적 구현은 실제 TermMasker 통합 필요)
    }

    // MARK: - Engine Selection Tests

    func testEngineSelection_AFM() async throws {
        // Given: AFM 엔진
        let afmEngine = MockTranslationEngine(tag: .afm)
        router = DefaultTranslationRouter(engine: afmEngine, cache: mockCache)
        mockCache.shouldReturnNil = true

        // When: 번역
        _ = try await collectStream(router.translate(TestFixtures.sampleSegments, options: TestFixtures.defaultOptions))

        // Then: AFM 엔진 호출
        XCTAssertEqual(afmEngine.translateCallCount, 1)
    }

    // Helper
    private func collectStream<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
        var results: [T] = []
        for try await item in stream {
            results.append(item)
        }
        return results
    }

    private func makeCacheKey(_ segment: Segment) -> String {
        let options = TestFixtures.defaultOptions
        return "\(segment.id)|\(options.sourceLanguage)|\(options.targetLanguage)|\(options.style)"
    }
}
```

**기대 효과**:
- DefaultTranslationRouter 커버리지: 0% → 85%
- 번역 파이프라인 안정성 70% 향상
- 캐시 관련 버그 사전 탐지

### 액션 1.4: Glossary Service 테스트

**파일**: `MyTranslationTests/UnitTests/GlossaryServiceTests.swift`

**테스트 케이스**:

```swift
final class GlossaryServiceTests: XCTestCase {
    func testBuildEntries_WithStandaloneTerms() async throws
    func testBuildEntries_WithPatternActivation() async throws
    func testBuildEntries_WithTermToTermActivation() async throws
    func testBuildEntries_EmptyInput() async throws
    func testBuildEntries_PerformanceWithLargeGlossary() async throws
}
```

**기대 효과**:
- Glossary 적용 신뢰성 85% 향상

---

## Phase 2: 번역 엔진 및 캐시 (2-3주)

### 목표
번역 엔진 및 캐시 시스템의 안정성 확보

### 액션 2.1: Translation Engines Mock 테스트

**파일**: `MyTranslationTests/UnitTests/TranslationEnginesTests.swift`

**테스트 케이스**:

```swift
final class TranslationEnginesTests: XCTestCase {
    // MARK: - AFMEngine Tests

    func testAFMEngine_SuccessfulTranslation() async throws {
        // Given: AFM 엔진 설정
        // When: 번역 요청
        // Then: 정상 결과 반환
    }

    func testAFMEngine_UnsupportedLanguagePair() async throws {
        // Given: 지원하지 않는 언어 쌍
        // When: 번역 요청
        // Then: 적절한 오류 반환
    }

    func testAFMEngine_Timeout() async throws {
        // Given: 타임아웃 설정
        // When: 번역 요청
        // Then: 타임아웃 오류 반환
    }

    // MARK: - GoogleEngine Tests

    func testGoogleEngine_SuccessfulTranslation() async throws
    func testGoogleEngine_APIKeyError() async throws
    func testGoogleEngine_NetworkError() async throws
    func testGoogleEngine_InvalidJSON() async throws
    func testGoogleEngine_QuotaExceeded() async throws

    // MARK: - DeepLEngine Tests

    func testDeepLEngine_SuccessfulTranslation() async throws
    func testDeepLEngine_QuotaExceeded() async throws
    func testDeepLEngine_FreeVsPro() async throws
    func testDeepLEngine_UnsupportedLanguage() async throws
}
```

**기대 효과**:
- API 통합 신뢰성 80% 향상
- 네트워크 오류 처리 검증

### 액션 2.2: CacheStore 테스트

**파일**: `MyTranslationTests/UnitTests/CacheStoreTests.swift`

**테스트 케이스**:

```swift
final class CacheStoreTests: XCTestCase {
    var cache: DefaultCacheStore!

    override func setUp() {
        cache = DefaultCacheStore()
    }

    func testLookup_Hit() {
        // Given: 캐시에 저장
        let result = TestFixtures.sampleTranslationResults[0]
        cache.save(result: result, forKey: "test-key")

        // When: 조회
        let found = cache.lookup(key: "test-key")

        // Then: 결과 반환
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.text, result.text)
    }

    func testLookup_Miss() {
        // When: 존재하지 않는 키 조회
        let found = cache.lookup(key: "non-existent")

        // Then: nil 반환
        XCTAssertNil(found)
    }

    func testSave_Overwrite() {
        // Given: 동일 키로 2번 저장
        let result1 = TestFixtures.makeTranslationResult(text: "First")
        let result2 = TestFixtures.makeTranslationResult(text: "Second")
        cache.save(result: result1, forKey: "key")
        cache.save(result: result2, forKey: "key")

        // When: 조회
        let found = cache.lookup(key: "key")

        // Then: 최신 값 반환
        XCTAssertEqual(found?.text, "Second")
    }

    func testClearAll_RemovesAllEntries() {
        // Given: 여러 항목 저장
        cache.save(result: TestFixtures.sampleTranslationResults[0], forKey: "key1")
        cache.save(result: TestFixtures.sampleTranslationResults[1], forKey: "key2")

        // When: 전체 삭제
        cache.clearAll()

        // Then: 모두 삭제됨
        XCTAssertNil(cache.lookup(key: "key1"))
        XCTAssertNil(cache.lookup(key: "key2"))
    }

    func testClearBySegmentIDs_SelectiveDeletion() {
        // Given: 세그먼트 ID 기반 캐시 키
        cache.save(result: TestFixtures.sampleTranslationResults[0], forKey: "seg1|en|ko|style")
        cache.save(result: TestFixtures.sampleTranslationResults[1], forKey: "seg2|en|ko|style")
        cache.save(result: TestFixtures.sampleTranslationResults[2], forKey: "seg3|en|ko|style")

        // When: seg1만 삭제
        cache.clearBySegmentIDs(["seg1"])

        // Then: seg1만 삭제, 나머지 유지
        XCTAssertNil(cache.lookup(key: "seg1|en|ko|style"))
        XCTAssertNotNil(cache.lookup(key: "seg2|en|ko|style"))
        XCTAssertNotNil(cache.lookup(key: "seg3|en|ko|style"))
    }

    func testCacheKeyParsing_EdgeCases() {
        // 잘못된 캐시 키 형식 처리
    }
}
```

**기대 효과**:
- 캐시 관련 버그 80% 감소
- 선택적 삭제 로직 검증

---

## Phase 3: 상태 관리 및 서비스 (2-3주)

### 목표
ViewModel 및 서비스 레이어의 상태 관리 안정성 확보

### 액션 3.1: BrowserViewModel 테스트

**파일**: `MyTranslationTests/UnitTests/BrowserViewModelTests.swift`

**테스트 케이스**:

```swift
@MainActor
final class BrowserViewModelTests: XCTestCase {
    var viewModel: BrowserViewModel!
    var mockRouter: MockTranslationRouter!

    override func setUp() async throws {
        mockRouter = MockTranslationRouter()
        viewModel = BrowserViewModel(router: mockRouter)
    }

    // MARK: - Language Change Tests

    func testLanguageChange_UpdatesPreference() async throws {
        // Given: 초기 언어
        let initialLang = viewModel.targetLanguage

        // When: 언어 변경
        let newLang = AppLanguage(code: "ja")
        viewModel.changeTargetLanguage(to: newLang)

        // Then: 업데이트됨
        XCTAssertNotEqual(viewModel.targetLanguage, initialLang)
        XCTAssertEqual(viewModel.targetLanguage, newLang)
    }

    func testLanguageChange_TriggersRetranslation() async throws {
        // Given: 번역된 상태
        // When: 언어 변경
        // Then: 재번역 트리거
    }

    // MARK: - Translation Workflow Tests

    func testRequestTranslation_SuccessfulFlow() async throws {
        // Given: 세그먼트 추출 완료
        // When: 번역 요청
        // Then: 번역 결과 수신
    }

    func testRequestTranslation_HandlesFailure() async throws {
        // Given: 엔진 오류 설정
        // When: 번역 요청
        // Then: 오류 처리
    }

    func testRequestTranslation_CancellationSupport() async throws {
        // Given: 번역 진행 중
        // When: 취소 요청
        // Then: Task 취소
    }

    // MARK: - Page Load Tests

    func testPageLoad_ResetsTranslationState() async throws {
        // Given: 번역된 페이지
        // When: 새 페이지 로드
        // Then: 상태 리셋
    }

    // MARK: - Favorites Tests

    func testAddFavorite_Success() async throws
    func testAddFavorite_Duplicate() async throws
    func testRemoveFavorite_Success() async throws
}
```

**기대 효과**:
- 상태 버그 70% 감소
- 메모리 누수 사전 탐지

---

## Phase 4: 통합 및 UI 테스트 (2-3주)

### 목표
전체 시스템의 통합 안정성 및 UI 워크플로우 검증

### 액션 4.1: 통합 테스트

**파일**: `MyTranslationTests/IntegrationTests/TranslationPipelineTests.swift`

**테스트 케이스**:

```swift
final class TranslationPipelineTests: XCTestCase {
    func testFullPipeline_ExtractionToRendering() async throws {
        // Given: HTML 페이지
        // When: 추출 → 마스킹 → 번역 → 정규화 → 렌더링
        // Then: 각 단계 검증
    }

    func testEngineSwitch_MaintainsConsistency() async throws {
        // Given: Google 엔진으로 번역
        // When: DeepL로 전환
        // Then: 일관성 유지
    }

    func testCacheInvalidation_OnLanguageChange() async throws {
        // Given: 캐시된 번역
        // When: 언어 변경
        // Then: 캐시 무효화
    }

    func testGlossaryApplication_EndToEnd() async throws {
        // Given: Glossary 설정
        // When: 번역 실행
        // Then: 용어 적용 확인
    }
}
```

**기대 효과**:
- 통합 이슈 50% 감소
- 전체 워크플로우 검증

### 액션 4.2: UI 테스트

**파일**: `MyTranslationUITests/BrowserUITests.swift`

**테스트 케이스**:

```swift
final class BrowserUITests: XCTestCase {
    func testPageLoad_ShowsContent() throws {
        // Given: 앱 실행
        // When: URL 입력
        // Then: 페이지 로드
    }

    func testTranslateButton_TriggersTranslation() throws {
        // Given: 페이지 로드 완료
        // When: 번역 버튼 탭
        // Then: 번역 실행
    }

    func testLanguageSelector_ChangesLanguage() throws {
        // Given: 언어 선택기
        // When: 다른 언어 선택
        // Then: 언어 변경
    }

    func testOriginalToggle_ShowsOriginal() throws {
        // Given: 번역된 페이지
        // When: 원문 토글
        // Then: 원문 표시
    }

    func testOverlayPanel_DisplaysMetadata() throws {
        // Given: 텍스트 선택
        // When: 오버레이 패널 표시
        // Then: 메타데이터 확인
    }
}
```

**파일**: `MyTranslationUITests/GlossaryUITests.swift`

**테스트 케이스**:

```swift
final class GlossaryUITests: XCTestCase {
    func testTermCreation_Success() throws
    func testTermEdit_SavesChanges() throws
    func testTermDelete_RemovesTerm() throws
    func testSheetsImport_ImportsData() throws
    func testPatternEditor_CreatesPattern() throws
}
```

**기대 효과**:
- UI 회귀 버그 60% 감소
- 사용자 워크플로우 검증

---

## 5. 구현 전략

### 5.1 우선순위

**즉시 착수 (1주 내)**:
1. Mock 인프라 구축 (액션 1.1)
2. TestFixtures 작성 (액션 1.1)
3. CacheStore 테스트 (액션 2.2) - 가장 간단하여 빠른 성과

**단기 목표 (1개월 내)**:
1. TermMasker 완전 커버리지 (액션 1.2)
2. DefaultTranslationRouter 테스트 (액션 1.3)
3. CI에서 테스트 자동 실행

**중기 목표 (3개월 내)**:
1. 번역 엔진 테스트 (액션 2.1)
2. BrowserViewModel 테스트 (액션 3.1)
3. 통합 테스트 (액션 4.1)

**장기 목표 (6개월 내)**:
1. UI 테스트 (액션 4.2)
2. 전체 코드베이스 70%+ 커버리지
3. 성능 테스트 추가

### 5.2 리소스 및 타임라인

| Phase | 기간 | 주요 작업 | 예상 커버리지 |
|-------|------|----------|--------------|
| Phase 1 | 4-5주 | Mock 인프라, TermMasker, DefaultTranslationRouter, Glossary | 40% |
| Phase 2 | 2-3주 | 번역 엔진, CacheStore | 50% |
| Phase 3 | 2-3주 | BrowserViewModel, 기타 서비스 | 65% |
| Phase 4 | 2-3주 | 통합 테스트, UI 테스트 | 75% |

**총 예상 기간**: 10-15주

### 5.3 측정 지표

**테스트 커버리지**:
- 현재: ~5%
- Phase 1 후: ~40%
- Phase 2 후: ~50%
- Phase 3 후: ~65%
- Phase 4 후: ~75%

**버그 탐지율**:
- 기대: 배포 전 80% 버그 탐지
- 회귀 방지: 95% 회귀 방지

**개발 속도**:
- 테스트 작성: Mock 인프라로 3배 향상
- 리팩토링 안전성: 테스트 커버리지로 70% 향상
- PR 리뷰 시간: 자동화로 40% 단축

---

## 6. 리스크 및 완화 방안

### 리스크 1: 시간 부족
**완화 방안**:
- Phase별로 점진적 진행
- 우선순위 높은 부분부터 착수
- 필요시 Phase 4 일부 지연 가능

### 리스크 2: Mock 복잡도
**완화 방안**:
- 간단한 Mock부터 시작
- 필요한 기능만 구현
- 재사용 가능한 구조 설계

### 리스크 3: 기존 코드 수정 필요
**완화 방안**:
- 테스트 가능한 구조로 점진적 리팩토링
- 기존 동작 변경 최소화
- 리팩토링 전 현재 동작 테스트로 고정

### 리스크 4: CI/CD 통합 복잡도
**완화 방안**:
- 로컬 테스트 먼저 안정화
- GitHub Actions 단순 설정부터 시작
- 커버리지 리포팅은 선택사항

---

## 7. 성공 기준

### Phase 1 성공 기준
- [x] Mock 인프라 완성 (MockTranslationEngine, MockCacheStore)
- [x] TestFixtures 작성
- [x] TermMasker 커버리지 90%+
- [x] DefaultTranslationRouter 커버리지 85%+
- [x] 전체 커버리지 40%+

### Phase 2 성공 기준
- [x] 3개 엔진 각각 80%+ 커버리지
- [x] CacheStore 100% 커버리지
- [x] 전체 커버리지 50%+

### Phase 3 성공 기준
- [x] BrowserViewModel 80%+ 커버리지
- [x] 주요 ViewModel 70%+ 커버리지
- [x] 전체 커버리지 65%+

### Phase 4 성공 기준
- [x] 통합 테스트 5개+ 시나리오 커버
- [x] UI 테스트 주요 워크플로우 커버
- [x] 전체 커버리지 75%+

### 최종 성공 기준
- [x] 전체 테스트 커버리지 70%+
- [x] 모든 테스트 통과
- [x] CI에서 자동 테스트 실행
- [x] 테스트 실행 시간 5분 이내
- [x] 0개 Flaky 테스트

---

## 8. 향후 개선 사항

### 8.1 성능 테스트
- 대량 세그먼트 번역 성능 테스트
- 메모리 사용량 프로파일링
- 네트워크 지연 시뮬레이션

### 8.2 Snapshot 테스트
- UI 컴포넌트 Snapshot 테스트
- 번역 결과 Snapshot 테스트 (회귀 탐지)

### 8.3 E2E 테스트
- 실제 브라우저 환경에서 전체 플로우 테스트
- Selenium/Playwright 통합

### 8.4 코드 품질 도구
- SwiftLint 통합
- SonarQube 코드 품질 분석
- Danger for PR 자동 리뷰

---

## 9. 참고 자료

### 9.1 Swift Testing Best Practices
- Apple: [Testing in Xcode](https://developer.apple.com/documentation/xcode/testing-your-apps-in-xcode)
- Swift.org: [Testing](https://www.swift.org/blog/foundation-preview-now-available/)

### 9.2 Mock Patterns
- [Protocol-Oriented Mocking in Swift](https://www.swiftbysundell.com/articles/mocking-in-swift/)
- [Dependency Injection in Swift](https://www.avanderlee.com/swift/dependency-injection/)

### 9.3 Async Testing
- [Testing Async Code in Swift](https://www.swiftbysundell.com/articles/unit-testing-asynchronous-swift-code/)
- [AsyncStream Testing Patterns](https://www.avanderlee.com/concurrency/asyncstream/)

---

## 10. 부록

### 부록 A: 테스트 파일 구조

```
MyTranslationTests/
├── Mocks/
│   ├── MockTranslationEngine.swift       # 130줄
│   ├── MockCacheStore.swift              # 80줄
│   └── MockGlossaryService.swift         # 60줄
├── Fixtures/
│   └── TestFixtures.swift                # 150줄
├── UnitTests/
│   ├── TranslationRouterTests.swift      # 400줄 (15개 테스트)
│   ├── TermMaskerTests.swift             # 500줄 (25개 테스트, 기존 확장)
│   ├── TranslationEnginesTests.swift     # 350줄 (12개 테스트)
│   ├── CacheStoreTests.swift             # 200줄 (8개 테스트)
│   ├── BrowserViewModelTests.swift       # 300줄 (10개 테스트)
│   ├── GlossaryServiceTests.swift        # 200줄 (7개 테스트)
│   └── WebRenderingTests.swift           # 150줄 (5개 테스트)
├── IntegrationTests/
│   └── TranslationPipelineTests.swift    # 250줄 (5개 테스트)
└── MyTranslationTests.swift              # 663줄 (기존, 확장)

MyTranslationUITests/
├── BrowserUITests.swift                  # 200줄 (5개 테스트)
└── GlossaryUITests.swift                 # 150줄 (5개 테스트)

총 예상 라인 수: ~3,800줄
총 예상 테스트 수: ~100개
```

### 부록 B: CI/CD 설정 예시

```yaml
# .github/workflows/test.yml
name: Test

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v3

    - name: Run Tests
      run: |
        xcodebuild test \
          -scheme MyTranslation \
          -destination 'platform=iOS Simulator,name=iPhone 15' \
          -enableCodeCoverage YES

    - name: Generate Coverage Report
      run: |
        xcrun llvm-cov export \
          -format="lcov" \
          -instr-profile=coverage.profdata \
          Build/Products/Debug-iphonesimulator/MyTranslation.app/MyTranslation \
          > coverage.lcov

    - name: Upload Coverage
      uses: codecov/codecov-action@v3
      with:
        files: ./coverage.lcov
        fail_ci_if_error: true

    - name: Check Coverage Threshold
      run: |
        coverage=$(xcrun llvm-cov report ...)
        if [ "$coverage" -lt "70" ]; then
          echo "Coverage $coverage% is below 70%"
          exit 1
        fi
```

---

**문서 종료**
