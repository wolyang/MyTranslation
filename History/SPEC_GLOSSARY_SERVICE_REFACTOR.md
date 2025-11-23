# Glossary Service 리팩토링 스펙

## 1. 개요

### 1.1 현재 문제점

현재 `Glossary.Service`(데이터 계층)에서 다음 두 가지를 모두 처리하고 있습니다:
- **단독 용어** (`origin == termStandalone`): 하나의 SDTerm을 변환한 GlossaryEntry
- **조합 용어** (`origin == composer`): SDPattern을 이용해 하나 이상의 SDTerm들을 조합한 GlossaryEntry

이로 인한 문제:
1. **책임 분리 위반**: 데이터 계층이 비즈니스 로직(조합 용어 생성)을 담당
2. **비효율성**: 페이지 전체 텍스트로 조합을 미리 생성하지만, 실제로는 각 세그먼트별로 필요
3. **유연성 부족**: 세그먼트별로 다른 조합 전략을 적용하기 어려움
4. **테스트 어려움**: 데이터 조회와 비즈니스 로직이 섞여 있어 단위 테스트 작성이 복잡

### 1.2 목표

**데이터 계층 (Glossary.Service)**
- Term을 웹페이지 전체 텍스트에 나타나는 용어로 필터링만 수행
- 전체 Pattern 목록과 함께 반환
- SwiftData 조회 로직에 집중

**서비스 계층 (TranslationRouter 또는 새로운 서비스)**
- Pattern에 따라 조합 용어를 실제로 생성
- 세그먼트별 컨텍스트에 맞춰 조합 용어 생성
- 번역 파이프라인 흐름에 맞는 타이밍에 조합 수행

**파일 구조 정리**
- Glossary 관련 파일들의 위치와 책임을 명확히 분리
- 도메인/서비스/퍼시스턴스 레이어 경계 명확화

---

## 2. 아키텍처 변경

### 2.1 현재 구조

```
[TranslationRouter]
    ↓ fetchGlossaryEntries(fullText)
[Glossary.Service] (데이터 계층)
    ├─ Recall: Q-gram 기반 후보 Term 리콜
    ├─ Store: Term/Pattern SwiftData 조회
    ├─ Matcher: AhoCorasick로 페이지 전체 텍스트에서 매칭
    ├─ 단독 엔트리 생성 (termStandalone)
    └─ Composer: 조합 엔트리 생성 (composer) ← 문제!
    ↓ [GlossaryEntry] (단독+조합 모두 포함)
[TranslationRouter]
    └─ TermMasker.buildSegmentPieces()
```

### 2.2 목표 구조

```
[TranslationRouter]
    ↓ fetchGlossaryData(fullText)
[GlossaryDataProvider] (새 이름, 데이터 계층)
    ├─ Recall: Q-gram 기반 후보 Term 리콜
    ├─ Store: Term/Pattern SwiftData 조회
    ├─ Matcher: AhoCorasick로 페이지 전체 텍스트에서 매칭
    └─ 필터링된 Term 목록 + 전체 Pattern 목록 반환
    ↓ GlossaryData { matchedTerms: [SDTerm], patterns: [SDPattern] }
[GlossaryComposer] (새로운 서비스 계층)
    ├─ 단독 엔트리 생성 (termStandalone)
    └─ 세그먼트별 조합 엔트리 생성 (composer)
    ↓ [GlossaryEntry] (단독+조합)
[TranslationRouter]
    └─ TermMasker.buildSegmentPieces()
```

---

## 3. 세부 설계

### 3.1 새로운 타입 정의

#### 3.1.1 GlossaryData (Domain/Glossary/Models/)

```swift
/// 데이터 계층에서 서비스 계층으로 전달하는 용어집 데이터
public struct GlossaryData: Sendable {
    /// 페이지 텍스트에서 실제로 매칭된 Term 목록
    public let matchedTerms: [Glossary.SDModel.SDTerm]

    /// 전체 Pattern 목록 (조합 용어 생성에 필요)
    public let patterns: [Glossary.SDModel.SDPattern]

    /// Term key별 매칭된 source 텍스트들
    /// key: termKey, value: 실제로 페이지에 나타난 source 텍스트 집합
    public let matchedSourcesByKey: [String: Set<String>]

    public init(
        matchedTerms: [Glossary.SDModel.SDTerm],
        patterns: [Glossary.SDModel.SDPattern],
        matchedSourcesByKey: [String: Set<String>]
    ) {
        self.matchedTerms = matchedTerms
        self.patterns = patterns
        self.matchedSourcesByKey = matchedSourcesByKey
    }
}
```

### 3.2 데이터 계층 리팩토링

#### 3.2.1 GlossaryDataProvider (Domain/Glossary/Services/)

기존 `Glossary.Service`를 리네임하고 책임 축소:

```swift
extension Glossary {
    /// 데이터 조회 인터페이스
    public protocol DataProviding {
        @MainActor
        func fetchData(for pageText: String) throws -> GlossaryData
    }

    /// SwiftData 기반 용어집 데이터 제공자
    public final class DataProvider: DataProviding {
        private let context: ModelContext
        private let recallOpt: RecallOptions

        public init(context: ModelContext, recallOpt: RecallOptions = .init()) {
            self.context = context
            self.recallOpt = recallOpt
        }

        @MainActor
        public func fetchData(for pageText: String) throws -> GlossaryData {
            // 1) Q-gram 리콜
            let candidateKeys = try Recall.recallTermKeys(
                for: pageText,
                ctx: context,
                opt: recallOpt
            )
            guard !candidateKeys.isEmpty else {
                return GlossaryData(
                    matchedTerms: [],
                    patterns: [],
                    matchedSourcesByKey: [:]
                )
            }

            // 2) Term 로드
            let candidateTerms = try Store.fetchTerms(keys: candidateKeys, ctx: context)
            let oneCharTerms = try Store.fetchOneCharTerms(ctx: context)
            let terms = Array(Set(candidateTerms + oneCharTerms))

            // 3) AC 매칭
            let acBundle = Matcher.makeACBundle(from: terms)
            let hits = acBundle.ac.find(in: pageText)

            // 4) 매칭 테이블 구성
            var matchedSourcesByKey: [String: Set<String>] = [:]
            var matchedTermKeys: Set<String> = []

            for h in hits {
                guard let owner = acBundle.pidToOwner[h.pid] else { continue }
                matchedSourcesByKey[owner.termKey, default: []].insert(acBundle.sources[h.pid])
                matchedTermKeys.insert(owner.termKey)
            }

            // 5) 매칭된 Term만 필터링
            let matchedTerms = terms.filter { matchedTermKeys.contains($0.key) }

            // 6) 전체 Pattern 로드
            let patterns = try Store.fetchPatterns(ctx: context)

            return GlossaryData(
                matchedTerms: matchedTerms,
                patterns: patterns,
                matchedSourcesByKey: matchedSourcesByKey
            )
        }
    }
}
```

**주요 변경점:**
- `buildEntries()` → `fetchData()`: 이름 변경으로 책임 명확화
- 단독/조합 엔트리 생성 로직 제거
- 매칭된 Term과 Pattern만 반환
- `Recall`, `Store`, `Matcher` 유틸은 유지 (내부 구현)

### 3.3 서비스 계층 신규 구현

#### 3.3.1 GlossaryComposer (Services/Translation/Glossary/)

새로운 서비스로 조합 용어 생성 책임 담당:

```swift
/// 용어집 데이터로부터 GlossaryEntry를 생성하는 서비스
public final class GlossaryComposer {

    public init() {}

    /// 페이지 전체용 엔트리 생성 (기존 호환성)
    @MainActor
    public func buildEntries(
        from data: GlossaryData,
        pageText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        // 1) 단독 엔트리 생성
        let standaloneEntries = buildStandaloneEntries(
            from: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey
        )
        entries.append(contentsOf: standaloneEntries)

        // 2) 조합 엔트리 생성
        let composedEntries = buildComposedEntries(
            from: data.patterns,
            terms: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey,
            pageText: pageText
        )

        // 3) 단독 엔트리와 겹치는 조합 제외
        let standaloneSourceSet = Set(standaloneEntries.map { $0.source })
        let filteredComposed = composedEntries.filter {
            !standaloneSourceSet.contains($0.source)
        }
        entries.append(contentsOf: filteredComposed)

        // 4) 중복 제거
        return Deduplicator.deduplicate(entries)
    }

    /// 세그먼트별 엔트리 생성 (향후 최적화용)
    @MainActor
    public func buildEntriesForSegment(
        from data: GlossaryData,
        segmentText: String
    ) -> [GlossaryEntry] {
        // 세그먼트 텍스트 기반으로 필요한 조합만 생성
        // TODO: 향후 구현
        return buildEntries(from: data, pageText: segmentText)
    }

    // MARK: - Private Helpers

    private func buildStandaloneEntries(
        from terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>]
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        for term in terms {
            guard let matchedSourcesForTerm = matchedSources[term.key] else { continue }

            let activatorKeys = Set(term.activators.map { $0.key })
            let activatesKeys = Set(term.activates.map { $0.key })

            for source in term.sources {
                guard matchedSourcesForTerm.contains(source.text) else { continue }

                entries.append(GlossaryEntry(
                    source: source.text,
                    target: term.target,
                    variants: Set(term.variants),
                    preMask: term.preMask,
                    isAppellation: term.isAppellation,
                    prohibitStandalone: source.prohibitStandalone,
                    origin: .termStandalone(termKey: term.key),
                    activatorKeys: activatorKeys,
                    activatesKeys: activatesKeys
                ))
            }
        }

        return entries
    }

    private func buildComposedEntries(
        from patterns: [Glossary.SDModel.SDPattern],
        terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>],
        pageText: String
    ) -> [GlossaryEntry] {
        // 기존 Composer 로직을 여기로 이동
        // (GlossaryEntry.swift의 Composer.composeEntriesForMatched 로직 활용)

        let matchedTermKeys = Set(matchedSources.keys)
        let termsByKey = Dictionary(uniqueKeysWithValues: terms.map { ($0.key, $0) })

        var entries: [GlossaryEntry] = []

        for pattern in patterns {
            let usesR = pattern.sourceTemplates.contains { $0.contains("{R}") }
                     || pattern.targetTemplates.contains { $0.contains("{R}") }

            if usesR {
                // L-R 쌍 매칭
                let pairs = matchedPairs(
                    for: pattern,
                    terms: terms,
                    matched: matchedTermKeys
                )
                entries.append(contentsOf: buildEntriesFromPairs(
                    pairs: pairs,
                    pattern: pattern,
                    pageText: pageText
                ))
            } else {
                // L만 매칭
                let lefts = matchedLeftComponents(
                    for: pattern,
                    terms: terms,
                    matched: matchedTermKeys
                )
                entries.append(contentsOf: buildEntriesFromLefts(
                    lefts: lefts,
                    pattern: pattern,
                    pageText: pageText
                ))
            }
        }

        return entries
    }

    // ... 나머지 헬퍼 메서드들 (기존 Composer 로직 이동)
}
```

**주요 특징:**
- 조합 용어 생성 로직을 서비스 계층으로 이동
- 페이지 전체/세그먼트별 생성 옵션 제공 (향후 최적화)
- 기존 Composer 로직 재사용

#### 3.3.2 중복 제거 유틸 (Services/Translation/Glossary/)

```swift
/// GlossaryEntry 중복 제거 유틸
public enum Deduplicator {
    public static func deduplicate(_ entries: [GlossaryEntry]) -> [GlossaryEntry] {
        struct Key: Hashable {
            let source: String
            let target: String
            let preMask: Bool
            let isAppellation: Bool
        }

        var map: [Key: GlossaryEntry] = [:]

        for entry in entries {
            let key = Key(
                source: entry.source,
                target: entry.target,
                preMask: entry.preMask,
                isAppellation: entry.isAppellation
            )

            if var existing = map[key] {
                // variants 병합
                existing.variants.formUnion(entry.variants)
                existing.prohibitStandalone =
                    existing.prohibitStandalone && entry.prohibitStandalone
                map[key] = existing
            } else {
                map[key] = entry
            }
        }

        return Array(map.values)
    }
}
```

### 3.4 TranslationRouter 수정

#### 3.4.1 DefaultTranslationRouter 변경

```swift
final class DefaultTranslationRouter: TranslationRouter {
    // ...
    private let glossaryDataProvider: Glossary.DataProvider  // ← 리네임
    private let glossaryComposer: GlossaryComposer           // ← 신규

    init(
        afm: TranslationEngine,
        deepl: TranslationEngine,
        google: TranslationEngine,
        cache: CacheStore,
        glossaryDataProvider: Glossary.DataProvider,         // ← 리네임
        glossaryComposer: GlossaryComposer,                  // ← 신규
        postEditor: PostEditor,
        comparer: ResultComparer?,
        reranker: Reranker?
    ) {
        // ...
        self.glossaryDataProvider = glossaryDataProvider
        self.glossaryComposer = glossaryComposer
    }

    public func translateStream(...) async throws -> TranslationStreamSummary {
        // ...

        // 1) 데이터 조회
        let glossaryData = await fetchGlossaryData(
            fullText: segments.map({ $0.originalText }).joined(),
            shouldApply: options.applyGlossary
        )

        // 2) 엔트리 생성
        let glossaryEntries = await buildGlossaryEntries(
            from: glossaryData,
            fullText: segments.map({ $0.originalText }).joined()
        )

        // ... 나머지 로직 동일
    }

    private func fetchGlossaryData(
        fullText: String,
        shouldApply: Bool
    ) async -> GlossaryData? {
        guard shouldApply else { return nil }
        return await MainActor.run {
            try? glossaryDataProvider.fetchData(for: fullText)
        }
    }

    private func buildGlossaryEntries(
        from data: GlossaryData?,
        fullText: String
    ) async -> [GlossaryEntry] {
        guard let data = data else { return [] }
        return await MainActor.run {
            glossaryComposer.buildEntries(from: data, pageText: fullText)
        }
    }
}
```

### 3.5 AppContainer 수정

```swift
final class AppContainer: ObservableObject {
    // ...

    @MainActor
    lazy var glossaryDataProvider: Glossary.DataProvider = {
        Glossary.DataProvider(context: modelContext)
    }()

    lazy var glossaryComposer: GlossaryComposer = {
        GlossaryComposer()
    }()

    @MainActor
    lazy var translationRouter: TranslationRouter = {
        DefaultTranslationRouter(
            afm: afmEngine,
            deepl: deeplEngine,
            google: googleEngine,
            cache: cacheStore,
            glossaryDataProvider: glossaryDataProvider,   // ← 변경
            glossaryComposer: glossaryComposer,           // ← 신규
            postEditor: postEditor,
            comparer: config.enableComparer ? comparer : nil,
            reranker: config.enableRerank ? reranker : nil
        )
    }()
}
```

---

## 4. 파일 구조 정리

### 4.1 현재 파일 구조

```
Domain/Glossary/
├── DTO/
│   └── GlossaryJSON.swift
├── Models/
│   ├── Glossary.swift                    # 네임스페이스
│   ├── GlossaryEntry.swift               # GlossaryEntry + Service (혼재!) ← 문제
│   └── ...
├── Persistence/
│   ├── GlossarySDModel.swift
│   ├── GlossarySDSourceIndexMaintainer.swift
│   └── GlossarySDUpserter.swift
└── Services/
    ├── GlossarySheetImport.swift
    └── GlossaryJSONParser.swift

Services/Translation/Masking/
├── Masker.swift
├── MaskedPack.swift
└── LockInfo.swift
```

### 4.2 목표 파일 구조

```
Domain/Glossary/
├── Models/
│   ├── Glossary.swift                    # 네임스페이스만
│   ├── GlossaryEntry.swift               # GlossaryEntry 타입만
│   ├── GlossaryData.swift                # ← 신규: GlossaryData 타입
│   └── RecallOptions.swift               # ← 분리
│
├── Persistence/
│   ├── Models/
│   │   └── GlossarySDModel.swift
│   ├── Maintenance/
│   │   ├── GlossarySDSourceIndexMaintainer.swift
│   │   └── GlossarySDUpserter.swift
│   └── Providers/
│       └── GlossaryDataProvider.swift    # ← 신규: 데이터 조회 (기존 Service에서 분리)
│
├── Import/
│   ├── DTO/
│   │   └── GlossaryJSON.swift
│   └── Services/
│       ├── GlossarySheetImport.swift
│       └── GlossaryJSONParser.swift
│
└── AutoVariant/
    ├── AutoVariantRecord.swift
    └── AutoVariantStoreManager.swift

Services/Translation/
├── Glossary/                             # ← 신규 디렉토리
│   ├── GlossaryComposer.swift            # ← 신규: 조합 용어 생성 서비스
│   └── Deduplicator.swift                # ← 신규: 중복 제거 유틸
│
└── Masking/
    ├── Masker.swift
    ├── MaskedPack.swift
    └── LockInfo.swift
```

### 4.3 파일 이동 및 분리 계획

#### 4.3.1 GlossaryEntry.swift 분리

**현재 (GlossaryEntry.swift - 629줄):**
- GlossaryEntry 타입 정의 (29줄)
- Glossary.Service 클래스 (142줄)
- Recall/Store/Matcher/Composer/Dedup/Util 등 내부 enum (458줄)

**분리 후:**

1. **GlossaryEntry.swift** (30줄)
   ```swift
   // GlossaryEntry 타입 정의만
   public struct GlossaryEntry: Sendable, Hashable {
       // ...
   }
   ```

2. **GlossaryData.swift** (신규, 30줄)
   ```swift
   // GlossaryData 타입 정의
   public struct GlossaryData: Sendable {
       // ...
   }
   ```

3. **RecallOptions.swift** (신규, 20줄)
   ```swift
   public struct RecallOptions: Sendable {
       // ...
   }
   public enum ScriptKind: Int16, Sendable {
       // ...
   }
   ```

4. **GlossaryDataProvider.swift** (신규, 400줄)
   ```swift
   extension Glossary {
       public protocol DataProviding { ... }

       public final class DataProvider: DataProviding {
           // 기존 Service 로직 중 데이터 조회 부분만
       }

       // Recall, Store, Matcher, AhoCorasick 등 내부 유틸
       enum Recall { ... }
       enum Store { ... }
       enum Matcher { ... }
       final class AhoCorasick { ... }
   }
   ```

5. **GlossaryComposer.swift** (신규, 300줄)
   ```swift
   public final class GlossaryComposer {
       // 기존 Composer 로직 이동
       // buildStandaloneEntries, buildComposedEntries 등
   }
   ```

6. **Deduplicator.swift** (신규, 30줄)
   ```swift
   public enum Deduplicator {
       // 기존 Dedup.run() 로직
   }
   ```

7. **GlossaryUtil.swift** (신규, 100줄)
   ```swift
   extension Glossary {
       enum Util {
           // qgrams, scriptKind, renderSources 등 공통 유틸
       }
   }
   ```

---

## 5. 마이그레이션 계획

### 5.1 Phase 1: 타입 및 파일 분리

**목표**: 파일 구조를 정리하고 새로운 타입 도입

**작업:**
1. ✅ GlossaryData 타입 정의
2. ✅ RecallOptions 분리
3. ✅ GlossaryEntry.swift 분리
   - GlossaryEntry만 남기고 나머지 로직은 임시로 유지
4. ✅ 디렉토리 구조 생성
   - `Domain/Glossary/Persistence/Providers/`
   - `Services/Translation/Glossary/`

**검증:**
- 기존 테스트가 모두 통과하는지 확인

### 5.2 Phase 2: 데이터 계층 리팩토링

**목표**: Glossary.Service → GlossaryDataProvider 전환

**작업:**
1. ✅ GlossaryDataProvider 구현
   - `fetchData(for:)` 메서드 구현
   - 기존 Recall/Store/Matcher 로직 활용
2. ✅ 기존 Glossary.Service와 병행 운영
   - Glossary.Service는 내부적으로 DataProvider 사용
   - `buildEntries()` 메서드는 임시 호환성 유지
3. ✅ AppContainer에 GlossaryDataProvider 등록

**검증:**
- GlossaryDataProvider.fetchData() 단위 테스트 작성
- 기존 통합 테스트 통과 확인

### 5.3 Phase 3: 서비스 계층 구현

**목표**: GlossaryComposer 서비스 구현

**작업:**
1. ✅ GlossaryComposer 구현
   - `buildEntries(from:pageText:)` 구현
   - 기존 Composer 로직 이동
2. ✅ Deduplicator 유틸 분리
3. ✅ 단위 테스트 작성
   - 단독 엔트리 생성 테스트
   - 조합 엔트리 생성 테스트
   - 중복 제거 테스트

**검증:**
- GlossaryComposer 단위 테스트 통과
- 기존 결과와 동일한 GlossaryEntry 배열 생성 확인

### 5.4 Phase 4: TranslationRouter 통합

**목표**: Router가 새로운 구조 사용하도록 전환

**작업:**
1. ✅ DefaultTranslationRouter 수정
   - GlossaryDataProvider + GlossaryComposer 사용
   - `fetchGlossaryData()` + `buildGlossaryEntries()` 분리
2. ✅ AppContainer DI 수정
3. ✅ 통합 테스트 실행

**검증:**
- 번역 파이프라인 end-to-end 테스트
- 기존 동작과 완전히 동일한지 확인

### 5.5 Phase 5: 레거시 코드 제거

**목표**: 기존 Glossary.Service 제거 및 정리

**작업:**
1. ✅ Glossary.Service (buildEntries) 제거
2. ✅ GlossaryEntry.swift에서 Composer/Dedup 등 제거
3. ✅ 사용하지 않는 헬퍼 정리
4. ✅ 문서 업데이트 (PROJECT_OVERVIEW.md, AGENT_RULES.md)

**검증:**
- 모든 테스트 통과
- 빌드 경고 없음
- 코드 커버리지 유지

---

## 6. 테스트 전략

### 6.1 단위 테스트

#### GlossaryDataProvider 테스트
```swift
final class GlossaryDataProviderTests: XCTestCase {
    func testFetchData_withMatchingTerms() async throws {
        // Given: pageText에 매칭되는 Term이 있을 때
        // When: fetchData 호출
        // Then: matchedTerms에 해당 Term이 포함됨
    }

    func testFetchData_withNoMatch() async throws {
        // Given: pageText에 매칭되는 Term이 없을 때
        // When: fetchData 호출
        // Then: 빈 GlossaryData 반환
    }

    func testFetchData_withQGramRecall() async throws {
        // Given: Q-gram 리콜 옵션 설정
        // When: fetchData 호출
        // Then: 적절한 후보 Term이 리콜됨
    }
}
```

#### GlossaryComposer 테스트
```swift
final class GlossaryComposerTests: XCTestCase {
    func testBuildStandaloneEntries() async throws {
        // Given: matchedTerms와 matchedSources
        // When: buildEntries 호출
        // Then: 올바른 standalone 엔트리 생성
    }

    func testBuildComposedEntries_withPairs() async throws {
        // Given: L-R 쌍 패턴과 매칭 Term
        // When: buildEntries 호출
        // Then: 올바른 composed 엔트리 생성
    }

    func testBuildEntries_excludesOverlap() async throws {
        // Given: standalone과 겹치는 source를 가진 composed 엔트리
        // When: buildEntries 호출
        // Then: 겹치는 composed 엔트리 제외됨
    }
}
```

#### Deduplicator 테스트
```swift
final class DeduplicatorTests: XCTestCase {
    func testDeduplicate_mergesVariants() throws {
        // Given: 같은 source/target을 가진 중복 엔트리
        // When: deduplicate 호출
        // Then: variants가 병합된 단일 엔트리 반환
    }
}
```

### 6.2 통합 테스트

```swift
final class GlossaryIntegrationTests: XCTestCase {
    func testEndToEndFlow() async throws {
        // Given: 실제 SwiftData context와 테스트 용어
        // When: DataProvider → Composer → Router 전체 흐름 실행
        // Then: 기존과 동일한 번역 결과 생성
    }
}
```

### 6.3 성능 테스트

```swift
final class GlossaryPerformanceTests: XCTestCase {
    func testFetchDataPerformance() throws {
        measure {
            // 큰 pageText에 대한 fetchData 성능 측정
        }
    }

    func testBuildEntriesPerformance() throws {
        measure {
            // 많은 Term/Pattern에 대한 buildEntries 성능 측정
        }
    }
}
```

---

## 7. 향후 최적화 방향

### 7.1 세그먼트별 조합 생성

현재는 페이지 전체 텍스트 기반으로 조합을 생성하지만, 향후 세그먼트별로 필요한 조합만 생성하도록 최적화 가능:

```swift
// TranslationRouter
for segment in segments {
    let segmentEntries = glossaryComposer.buildEntriesForSegment(
        from: glossaryData,
        segmentText: segment.originalText
    )
    // ... 세그먼트별 마스킹 처리
}
```

**장점:**
- 불필요한 조합 엔트리 생성 방지
- 메모리 사용량 감소
- 성능 향상

### 7.2 조합 결과 캐싱

GlossaryComposer에 캐싱 레이어 추가:

```swift
public final class GlossaryComposer {
    private var cache: [String: [GlossaryEntry]] = [:]

    public func buildEntries(from data: GlossaryData, pageText: String) -> [GlossaryEntry] {
        let cacheKey = makeCacheKey(data: data, pageText: pageText)
        if let cached = cache[cacheKey] {
            return cached
        }

        let entries = // ... 생성 로직
        cache[cacheKey] = entries
        return entries
    }
}
```

### 7.3 병렬 처리

많은 Pattern이 있을 때 병렬 처리로 성능 향상:

```swift
private func buildComposedEntries(...) -> [GlossaryEntry] {
    await withTaskGroup(of: [GlossaryEntry].self) { group in
        for pattern in patterns {
            group.addTask {
                self.buildEntriesForPattern(pattern, ...)
            }
        }

        var allEntries: [GlossaryEntry] = []
        for await entries in group {
            allEntries.append(contentsOf: entries)
        }
        return allEntries
    }
}
```

---

## 8. 문서 업데이트

### 8.1 PROJECT_OVERVIEW.md 수정

**주요 컴포넌트/모듈** 섹션 업데이트:

```markdown
### 4. Glossary System (`Domain/Glossary/`, `Services/Translation/Glossary/`)

용어집 시스템은 데이터 계층과 서비스 계층으로 분리되어 있습니다.

**데이터 계층 (Domain/Glossary/Persistence/)**
* `GlossaryDataProvider`: SwiftData에서 Term/Pattern 조회 및 필터링
* `GlossarySDModel`: SwiftData 모델 (SDTerm, SDPattern, SDComponent 등)
* `GlossarySDSourceIndexMaintainer`: Q-gram 인덱스 자동 유지

**서비스 계층 (Services/Translation/Glossary/)**
* `GlossaryComposer`: 조합 용어 생성 서비스
  * 단독 엔트리 (termStandalone) 생성
  * 패턴 기반 조합 엔트리 (composer) 생성
* `Deduplicator`: 중복 엔트리 병합

**Import (Domain/Glossary/Import/)**
* `GlossarySheetImport`: Google Sheets 연동
* `GlossaryJSONParser`: JSON 형식 파싱
```

**번역 파이프라인 흐름** 섹션 업데이트:

```markdown
2. **Masking & Normalization 준비**
   * `GlossaryDataProvider`가 페이지 텍스트에서 매칭된 Term과 Pattern 조회
   * `GlossaryComposer`가 단독/조합 용어 엔트리 생성
   * `TermMasker`가 `SegmentPieces`를 생성해 용어 위치 식별
   * ...
```

### 8.2 TODO.md 업데이트

리팩토링 작업 항목 추가:

```markdown
## 진행 중/우선 작업

- [ ] (P0) Glossary Service 리팩토링 (`History/SPEC_GLOSSARY_SERVICE_REFACTOR.md` 참조)
  - [ ] Phase 1: 타입 및 파일 분리
  - [ ] Phase 2: 데이터 계층 리팩토링 (GlossaryDataProvider)
  - [ ] Phase 3: 서비스 계층 구현 (GlossaryComposer)
  - [ ] Phase 4: TranslationRouter 통합
  - [ ] Phase 5: 레거시 코드 제거 및 문서 업데이트
```

---

## 9. 리스크 및 고려사항

### 9.1 호환성 리스크

**문제**: 기존 코드가 `Glossary.Service.buildEntries()`를 직접 호출하는 곳이 있을 수 있음

**대응**:
- Phase 2에서 임시 호환성 레이어 유지
- 점진적 마이그레이션 후 Phase 5에서 제거

### 9.2 성능 리스크

**문제**: 데이터 조회와 엔트리 생성을 분리하면 오버헤드 증가 가능

**대응**:
- 성능 테스트로 검증
- 필요시 캐싱 레이어 추가 (7.2절 참조)

### 9.3 테스트 커버리지

**문제**: 기존 테스트가 부족한 상태에서 리팩토링 시 회귀 위험

**대응**:
- Phase별로 단위 테스트 먼저 작성
- 통합 테스트로 기존 동작 검증
- 필요시 golden test 추가

### 9.4 SwiftData 비동기 처리

**문제**: `@MainActor` 제약으로 비동기 흐름 복잡도 증가

**대응**:
- 명시적인 `await MainActor.run` 사용
- 데이터 조회와 비즈니스 로직 분리로 오히려 단순화

---

## 10. 체크리스트

### 10.1 구현 체크리스트

- [ ] GlossaryData 타입 정의
- [ ] RecallOptions 분리
- [ ] GlossaryDataProvider 구현
- [ ] GlossaryComposer 구현
- [ ] Deduplicator 구현
- [ ] DefaultTranslationRouter 수정
- [ ] AppContainer DI 수정
- [ ] 파일 구조 정리
- [ ] 단위 테스트 작성
- [ ] 통합 테스트 작성
- [ ] 성능 테스트 작성
- [ ] 레거시 코드 제거
- [ ] 문서 업데이트

### 10.2 검증 체크리스트

- [ ] 모든 단위 테스트 통과
- [ ] 모든 통합 테스트 통과
- [ ] 기존 번역 결과와 동일한 출력 확인
- [ ] 성능 회귀 없음 확인
- [ ] 빌드 경고 없음
- [ ] 코드 리뷰 완료
- [ ] PROJECT_OVERVIEW.md 업데이트 확인
- [ ] TODO.md 업데이트 확인

---

## 11. 참고

### 11.1 관련 파일

- `Domain/Glossary/Models/GlossaryEntry.swift`
- `Services/Ochestration/DefaultTranslationRouter.swift`
- `Services/Translation/Masking/Masker.swift`
- `Application/AppContainer.swift`
- `MyTranslationTests/UnitTests/GlossaryServiceTests.swift`

### 11.2 관련 문서

- `PROJECT_OVERVIEW.md` - 프로젝트 구조 및 아키텍처
- `AGENT_RULES.md` - 코드 변경 규칙
- `TODO.md` - 작업 목록

### 11.3 설계 원칙

이 리팩토링은 다음 원칙을 따릅니다:

1. **단일 책임 원칙**: 데이터 조회와 비즈니스 로직 분리
2. **의존성 역전 원칙**: 프로토콜 기반 추상화
3. **개방-폐쇄 원칙**: 확장 가능한 구조
4. **점진적 마이그레이션**: Phase별 검증으로 안전성 확보
