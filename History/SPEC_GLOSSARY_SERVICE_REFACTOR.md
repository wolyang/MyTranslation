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
    ↓ fetchGlossaryData(fullText) // 페이지 전체 텍스트로 1회 데이터 조회
[GlossaryDataProvider] (새 이름, 데이터 계층)
    ├─ Recall: Q-gram 기반 후보 Term 리콜
    ├─ Store: Term/Pattern SwiftData 조회
    ├─ Matcher: AhoCorasick로 페이지 전체 텍스트에서 매칭
    └─ 필터링된 Term 목록 + 전체 Pattern 목록 반환
    ↓ GlossaryData { matchedTerms: [SDTerm], patterns: [SDPattern], matchedSourcesByKey }
[TranslationRouter - prepareMaskingContext]
    FOR EACH SEGMENT:  // 핵심: 세그먼트별로 루프
        ↓ buildEntriesForSegment(data, segmentText)
        [GlossaryComposer] (서비스 계층)
            ├─ 단독 엔트리 생성 (termStandalone)
            ├─ 세그먼트 텍스트 기반 조합 엔트리 생성 (composer)
            │  └─ AC 매칭으로 실제 나타나는 조합만 생성 (최적화!)
            └─ 중복 제거
            ↓ [GlossaryEntry] (해당 세그먼트용 단독+조합)
        [TermMasker]
            └─ buildSegmentPieces(segment, glossary: entries)
```

**주요 특징:**
- 데이터 조회는 페이지 레벨로 1회만 수행 (효율성)
- 조합 엔트리 생성은 세그먼트별로 수행 (메모리 최적화)
- 각 세그먼트는 자신에게 필요한 조합만 생성 (10-100배 적은 엔트리)

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

#### 3.1.2 GlossaryEntry.Origin 확장 (Domain/Glossary/Models/)

**중요**: GlossaryAddCandidateUtil 연동을 위해 composer origin에 Term 정보를 보존해야 합니다.

```swift
extension GlossaryEntry {
    public enum Origin: Sendable, Hashable {
        case termStandalone(termKey: String)
        case composer(leftKey: String?, rightKey: String?)  // ← 변경: Term 키 추가
    }
}
```

**설계 근거**:
- `computeUnmatchedCandidates`에서 `origin == .composer`이고 `leftKey/rightKey`가 있을 때, 해당 Term의 source/target으로 `UnmatchedTermCandidate`를 생성해야 함
- `leftKey/rightKey`가 모두 `nil`인 경우에만 후보 추가를 건너뜀 (패턴으로만 생성된 조합)
- TermHighlightMetadata를 통해 Composer → 하이라이팅 → 후보 생성까지 Term 정보 전달

**Composer에서의 사용**:
```swift
// L-R 쌍 조합
let entry = GlossaryEntry(
    source: composedSource,
    target: composedTarget,
    // ...
    origin: .composer(
        leftKey: leftTerm.key,
        rightKey: rightTerm.key
    )
)

// L만 조합 (R 없음)
let entry = GlossaryEntry(
    source: composedSource,
    target: composedTarget,
    // ...
    origin: .composer(
        leftKey: leftTerm.key,
        rightKey: nil
    )
)
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

    /// 세그먼트별 엔트리 생성 (메인 구현)
    @MainActor
    public func buildEntriesForSegment(
        from data: GlossaryData,
        segmentText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        // 1) 단독 엔트리 생성 (세그먼트 텍스트 기준)
        let standaloneEntries = buildStandaloneEntries(
            from: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey,
            targetText: segmentText
        )
        entries.append(contentsOf: standaloneEntries)

        // 2) 세그먼트별 조합 엔트리 생성 (핵심 최적화!)
        let composedEntries = buildComposedEntriesForSegment(
            from: data.patterns,
            terms: data.matchedTerms,
            matchedSources: data.matchedSourcesByKey,
            segmentText: segmentText  // 세그먼트 텍스트만 사용!
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

    /// 페이지 전체용 엔트리 생성 (레거시 호환성)
    @MainActor
    public func buildEntries(
        from data: GlossaryData,
        pageText: String
    ) -> [GlossaryEntry] {
        // 레거시: 페이지 전체를 단일 세그먼트로 처리
        return buildEntriesForSegment(from: data, segmentText: pageText)
    }

    // MARK: - Private Helpers

    private func buildStandaloneEntries(
        from terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>],
        targetText: String
    ) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []

        for term in terms {
            guard let matchedSourcesForTerm = matchedSources[term.key] else { continue }

            let activatorKeys = Set(term.activators.map { $0.key })
            let activatesKeys = Set(term.activates.map { $0.key })

            for source in term.sources {
                guard matchedSourcesForTerm.contains(source.text) else { continue }

                // 세그먼트에 실제로 나타나는지 확인
                guard targetText.contains(source.text) else { continue }

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

    private func buildComposedEntriesForSegment(
        from patterns: [Glossary.SDModel.SDPattern],
        terms: [Glossary.SDModel.SDTerm],
        matchedSources: [String: Set<String>],
        segmentText: String  // 핵심: 세그먼트 텍스트만 사용
    ) -> [GlossaryEntry] {
        // 기존 로직과 유사하지만 중요한 차이점:
        // 1. pageText 대신 segmentText 사용
        // 2. 조합된 source가 segmentText에 실제로 나타나는지 AC 매칭으로 확인
        // 3. 나타나지 않는 조합은 생성하지 않음 (메모리 절약!)

        let matchedTermKeys = Set(matchedSources.keys)
        var candidateEntries: [GlossaryEntry] = []

        // 패턴별로 후보 엔트리 생성
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
                candidateEntries.append(contentsOf: buildEntriesFromPairs(
                    pairs: pairs,
                    pattern: pattern
                ))
            } else {
                // L만 매칭
                let lefts = matchedLeftComponents(
                    for: pattern,
                    terms: terms,
                    matched: matchedTermKeys
                )
                candidateEntries.append(contentsOf: buildEntriesFromLefts(
                    lefts: lefts,
                    pattern: pattern
                ))
            }
        }

        // 핵심 최적화: segmentText에 실제로 나타나는 것만 필터링
        let acBundle = makeACBundleForEntries(candidateEntries)
        let hits = acBundle.ac.find(in: segmentText)
        let matchedSources = Set(hits.map { acBundle.sources[$0.pid] })

        return candidateEntries.filter { matchedSources.contains($0.source) }
    }

    private func makeACBundleForEntries(
        _ entries: [GlossaryEntry]
    ) -> (ac: AhoCorasick, sources: [String], pidToEntry: [Int: GlossaryEntry]) {
        // 엔트리들의 source로 AC 트라이 구성
        var sources: [String] = []
        var pidToEntry: [Int: GlossaryEntry] = [:]

        for (idx, entry) in entries.enumerated() {
            sources.append(entry.source)
            pidToEntry[idx] = entry
        }

        let ac = AhoCorasick(patterns: sources)
        return (ac, sources, pidToEntry)
    }

    // ... 나머지 헬퍼 메서드들 (기존 Composer 로직 이동)
    // matchedPairs, matchedLeftComponents, buildEntriesFromPairs, buildEntriesFromLefts
}
```

**주요 특징:**
- `buildEntriesForSegment()`가 메인 구현 (세그먼트별 최적화)
- `buildEntries()`는 레거시 호환성 유지
- AC 매칭으로 세그먼트에 실제 나타나는 조합만 생성 (10-100배 메모리 절약)
- 세그먼트별 컨텍스트 인식 조합

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

                // prohibitStandalone 병합: AND 연산
                // 의도: 하나라도 허용(false)이면 허용으로 병합
                // Pattern 기반 엔트리는 기본적으로 false이므로,
                // Term standalone + Pattern 조합 시 Pattern이 우선됨
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

**prohibitStandalone 병합 로직 설명**:
- `prohibitStandalone`은 Term이 Pattern에 포함되지 않았을 때 번역을 허용할지 금지할지를 제어하는 플래그
- Pattern 기반 조합 엔트리는 기본적으로 `prohibitStandalone == false` (패턴 검사를 무조건 통과)
- `&&` 연산으로 병합하면: `false && true == false`, `false && false == false`
- 결과: 하나라도 패턴 엔트리가 있으면 허용 상태로 유지 (의도된 동작)
- 예시:
  - Term standalone entry: `prohibitStandalone = true`
  - Pattern composed entry: `prohibitStandalone = false`
  - 병합 결과: `true && false = false` (허용됨)

#### 3.3.3 GlossaryAddCandidateUtil 연동 고려사항

Glossary 추가 패널에서 사용하는 `GlossaryAddCandidateUtil.computeUnmatchedCandidates`는 Composer 기원 엔트리를 다음처럼 처리해야 합니다:

```swift
// GlossaryAddCandidateUtil.swift
func computeUnmatchedCandidates(
    highlights: [TermHighlightMetadata],
    existingTerms: [SDTerm]
) -> [UnmatchedTermCandidate] {
    var candidates: [UnmatchedTermCandidate] = []

    for highlight in highlights {
        switch highlight.entry.origin {
        case .termStandalone(let termKey):
            // 기존 로직: termKey로 SDTerm 조회 후 후보 생성
            if let term = existingTerms.first(where: { $0.key == termKey }) {
                // source/target이 다르면 후보 추가
                if term.sources.contains(where: { $0.text != highlight.source }) {
                    candidates.append(UnmatchedTermCandidate(
                        source: highlight.source,
                        target: term.target,
                        existingTermKey: termKey
                    ))
                }
            }

        case .composer(let leftKey, let rightKey):
            // 핵심: leftKey/rightKey가 있을 때만 후보 생성
            if let leftKey = leftKey {
                if let leftTerm = existingTerms.first(where: { $0.key == leftKey }) {
                    // L Term의 source/target으로 후보 생성
                    candidates.append(UnmatchedTermCandidate(
                        source: leftTerm.sources.first?.text ?? highlight.source,
                        target: leftTerm.target,
                        existingTermKey: leftKey
                    ))
                }
            }

            if let rightKey = rightKey {
                if let rightTerm = existingTerms.first(where: { $0.key == rightKey }) {
                    // R Term의 source/target으로 후보 생성
                    candidates.append(UnmatchedTermCandidate(
                        source: rightTerm.sources.first?.text ?? highlight.source,
                        target: rightTerm.target,
                        existingTermKey: rightKey
                    ))
                }
            }

            // leftKey/rightKey가 모두 nil인 경우:
            // 패턴으로만 생성된 조합이므로 후보 추가하지 않음
        }
    }

    return candidates.deduplicated()
}
```

**설계 원칙**:
1. `origin == .composer(nil, nil)`: 후보 추가 안 함 (패턴으로만 생성)
2. `origin == .composer(leftKey, nil)`: L Term 정보로 후보 생성
3. `origin == .composer(leftKey, rightKey)`: L, R 각각 후보 생성
4. GlossaryEntry 자체의 source/target이 아닌, **원본 Term의 source/target**을 사용
5. Composer → TermHighlightMetadata → computeUnmatchedCandidates까지 Term 정보 전달 보장

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

        // 1) 데이터 조회 (1회만, 페이지 전체 텍스트로)
        let glossaryData = await fetchGlossaryData(
            fullText: segments.map({ $0.originalText }).joined(),
            shouldApply: options.applyGlossary
        )

        // 2) 세그먼트별 마스킹 컨텍스트 준비 (여기서 세그먼트별 조합 수행!)
        let maskingContext = await prepareMaskingContext(
            from: segments,
            glossaryData: glossaryData,  // 엔트리가 아닌 데이터 전달
            engine: selectedEngine,
            termMasker: termMasker
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

    private func prepareMaskingContext(
        from segments: [Segment],
        glossaryData: GlossaryData?,  // 변경: entries → data
        engine: TranslationEngine,
        termMasker: TermMasker
    ) async -> MaskingContext {
        var allSegmentPieces: [SegmentPieces] = []
        var maskedPacks: [MaskedPack] = []
        var nameGlossariesPerSegment: [[TermMasker.NameGlossary]] = []

        for segment in segments {
            // 핵심 변경: 세그먼트별 엔트리 생성!
            let glossaryEntries = await buildEntriesForSegment(
                from: glossaryData,
                segmentText: segment.originalText
            )

            let (pieces, _) = termMasker.buildSegmentPieces(
                segment: segment,
                glossary: glossaryEntries  // 세그먼트별 엔트리 사용
            )
            allSegmentPieces.append(pieces)

            // ... 나머지 마스킹 로직
            let masked = termMasker.maskSegment(
                pieces: pieces,
                engine: engine
            )
            maskedPacks.append(masked.pack)
            nameGlossariesPerSegment.append(masked.nameGlossaries)
        }

        return MaskingContext(
            allSegmentPieces: allSegmentPieces,
            maskedPacks: maskedPacks,
            nameGlossariesPerSegment: nameGlossariesPerSegment
        )
    }

    private func buildEntriesForSegment(
        from data: GlossaryData?,
        segmentText: String
    ) async -> [GlossaryEntry] {
        guard let data = data else { return [] }
        return await MainActor.run {
            glossaryComposer.buildEntriesForSegment(
                from: data,
                segmentText: segmentText
            )
        }
    }
}
```

**주요 변경점:**
- `translateStream()`에서 페이지 레벨 엔트리 생성 제거
- `prepareMaskingContext()` 내에서 세그먼트별 엔트리 생성
- 각 세그먼트가 자신만의 GlossaryEntry 배열 사용
- 데이터 조회는 1회, 조합 생성은 N회 (세그먼트 수만큼)

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

**목표**: GlossaryComposer 서비스 구현 (세그먼트별 조합 포함)

**작업:**
1. ✅ GlossaryComposer 구현
   - `buildEntriesForSegment(from:segmentText:)` 구현 (PRIMARY)
     * `buildStandaloneEntries()` 헬퍼 구현
     * `buildComposedEntriesForSegment()` 헬퍼 구현
       - 패턴별 후보 엔트리 생성
       - AC 매칭으로 세그먼트에 실제 나타나는 조합만 필터링
       - `makeACBundleForEntries()` 유틸 구현
     * `matchedPairs()`, `matchedLeftComponents()` 등 기존 Composer 로직 이동
     * `buildEntriesFromPairs()`, `buildEntriesFromLefts()` 구현
   - `buildEntries(from:pageText:)` 구현 (LEGACY 호환성)
2. ✅ Deduplicator 유틸 분리
3. ✅ 단위 테스트 작성
   - 단독 엔트리 생성 테스트
   - 세그먼트별 조합 생성 테스트 (핵심!)
     * 세그먼트에 나타나는 조합만 생성되는지 검증
     * 불필요한 조합이 생성되지 않는지 검증
   - 페이지 레벨 vs 세그먼트 레벨 결과 비교 테스트
   - 중복 제거 테스트

**검증:**
- GlossaryComposer 단위 테스트 통과
- 세그먼트별 조합이 올바르게 작동하는지 확인
- 메모리 효율성 개선 측정 (페이지 레벨 대비 생성되는 엔트리 수)

### 5.4 Phase 4: TranslationRouter 통합

**목표**: Router가 세그먼트별 조합을 사용하도록 전환

**작업:**
1. ✅ DefaultTranslationRouter 수정
   - GlossaryDataProvider + GlossaryComposer 사용
   - `translateStream()`에서 페이지 레벨 엔트리 생성 제거
   - `prepareMaskingContext()` 수정
     * 세그먼트 루프 내에서 `buildEntriesForSegment()` 호출
     * 각 세그먼트가 자신만의 GlossaryEntry 배열 사용
   - `buildEntriesForSegment()` 헬퍼 메서드 추가
2. ✅ AppContainer DI 수정
   - `glossaryDataProvider` 등록
   - `glossaryComposer` 등록
3. ✅ 통합 테스트 실행
   - 세그먼트별 조합이 올바르게 작동하는지 검증
   - 메모리 사용량 개선 측정

**검증:**
- 번역 파이프라인 end-to-end 테스트
- 세그먼트별 마스킹이 올바르게 작동하는지 확인
- 기존 동작과 동일한 번역 결과 생성 확인
- 성능 회귀 없음 확인 (오히려 개선되어야 함)

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
        // Given: matchedTerms와 matchedSources, 특정 세그먼트 텍스트
        // When: buildEntriesForSegment 호출
        // Then: 세그먼트에 나타나는 standalone 엔트리만 생성
    }

    func testBuildComposedEntries_withPairs() async throws {
        // Given: L-R 쌍 패턴과 매칭 Term, 특정 세그먼트 텍스트
        // When: buildEntriesForSegment 호출
        // Then: 세그먼트에 나타나는 composed 엔트리만 생성
    }

    func testBuildEntries_excludesOverlap() async throws {
        // Given: standalone과 겹치는 source를 가진 composed 엔트리
        // When: buildEntriesForSegment 호출
        // Then: 겹치는 composed 엔트리 제외됨
    }

    // 핵심 추가 테스트
    func testBuildEntriesForSegment_onlyGeneratesNeededCompositions() async throws {
        // Given: 10개 패턴이 있고, 세그먼트에는 2개 조합만 나타남
        // When: buildEntriesForSegment 호출
        // Then: 2개 조합만 생성됨 (8개는 생성 안 됨)
    }

    func testBuildEntriesForSegment_vsPageLevel_efficiency() async throws {
        // Given: 여러 세그먼트를 가진 페이지
        // When: 세그먼트별 vs 페이지 레벨 조합 생성 비교
        // Then: 세그먼트별이 훨씬 적은 엔트리 생성 (10-100배)
    }

    func testBuildEntriesForSegment_handlesEmptySegment() async throws {
        // Given: 빈 세그먼트 텍스트
        // When: buildEntriesForSegment 호출
        // Then: 빈 배열 반환
    }

    func testBuildEntriesForSegment_multipleSegmentsSameData() async throws {
        // Given: 동일한 GlossaryData, 3개 다른 세그먼트
        // When: 각 세그먼트별로 buildEntriesForSegment 호출
        // Then: 각 세그먼트에 맞는 다른 엔트리 배열 생성
    }

    func testBuildEntriesForSegment_noUnnecessaryCompositions() async throws {
        // Given: 패턴은 있지만 세그먼트에 조합 결과가 없음
        // When: buildEntriesForSegment 호출
        // Then: 조합 엔트리 0개 생성 (메모리 낭비 방지)
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

세그먼트별 조합 생성은 이미 메인 구현에 포함되었으므로, 다음은 추가 최적화 기회입니다.

### 7.1 세그먼트별 조합 결과 캐싱

**현재 상황**: 매 세그먼트마다 조합을 새로 생성하지만, 같은 세그먼트가 반복되거나 유사한 패턴이 많을 경우 캐싱으로 성능 향상 가능

**구현 예시**:
```swift
public final class GlossaryComposer {
    // 세그먼트 텍스트 해시 → 생성된 엔트리
    private var segmentCache: [Int: [GlossaryEntry]] = [:]

    @MainActor
    public func buildEntriesForSegment(
        from data: GlossaryData,
        segmentText: String
    ) -> [GlossaryEntry] {
        // 캐시 키 생성 (세그먼트 텍스트 + 데이터 해시)
        let cacheKey = makeCacheKey(text: segmentText, data: data)

        if let cached = segmentCache[cacheKey] {
            return cached
        }

        let entries = // ... 기존 생성 로직
        segmentCache[cacheKey] = entries
        return entries
    }

    private func makeCacheKey(text: String, data: GlossaryData) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(data.matchedTerms.count)
        hasher.combine(data.patterns.count)
        return hasher.finalize()
    }
}
```

**장점:**
- 동일/유사 세그먼트 재처리 시 즉시 반환
- 특히 반복적인 문장 구조에서 효과적

**주의사항:**
- 캐시 크기 제한 필요 (LRU 등)
- 메모리와 성능 트레이드오프 고려

### 7.2 패턴별 병렬 처리

**현재 상황**: 패턴을 순차적으로 처리하지만, 많은 패턴이 있을 때 병렬 처리 가능

**구현 예시**:
```swift
private func buildComposedEntriesForSegment(...) async -> [GlossaryEntry] {
    // 패턴이 많을 때만 병렬 처리
    guard patterns.count > 10 else {
        return buildComposedEntriesSequentially(...)
    }

    return await withTaskGroup(of: [GlossaryEntry].self) { group in
        for pattern in patterns {
            group.addTask {
                await self.buildEntriesForPattern(
                    pattern: pattern,
                    terms: terms,
                    matchedSources: matchedSources,
                    segmentText: segmentText
                )
            }
        }

        var allCandidates: [GlossaryEntry] = []
        for await entries in group {
            allCandidates.append(contentsOf: entries)
        }

        // AC 필터링
        let acBundle = makeACBundleForEntries(allCandidates)
        let hits = acBundle.ac.find(in: segmentText)
        let matchedSources = Set(hits.map { acBundle.sources[$0.pid] })

        return allCandidates.filter { matchedSources.contains($0.source) }
    }
}
```

**장점:**
- 많은 패턴 처리 시 성능 향상
- 멀티코어 활용

**주의사항:**
- 오버헤드로 인해 패턴 수가 적으면 오히려 느릴 수 있음
- 임계값 설정 필요 (예: 10개 이상일 때만)

### 7.3 점진적 조합 생성 (Lazy Composition)

**현재 상황**: 모든 조합을 미리 생성하지만, 실제로 마스킹에 사용되는 것만 생성 가능

**구현 예시**:
```swift
/// 패턴별 조합 생성기 (lazy)
public struct CompositionGenerator {
    private let pattern: SDPattern
    private let terms: [SDTerm]
    private let segmentText: String

    func generateNext() -> GlossaryEntry? {
        // 다음 조합 하나만 생성
        // 세그먼트에 나타나는지 즉시 확인
        // 나타나면 반환, 아니면 다음 시도
    }
}

// 사용
for pattern in patterns {
    var generator = CompositionGenerator(pattern, terms, segmentText)
    while let entry = generator.generateNext() {
        entries.append(entry)
    }
}
```

**장점:**
- 메모리 효율성 극대화
- 불필요한 조합 생성 완전 방지

**단점:**
- 구현 복잡도 증가
- 현재 구조로도 충분히 효율적

### 7.4 AC 트라이 재사용

**현재 상황**: 세그먼트마다 AC 트라이를 새로 생성하지만, 후보 엔트리 패턴이 유사하면 재사용 가능

**구현 예시**:
```swift
public final class GlossaryComposer {
    // 패턴 조합 → AC 트라이 캐시
    private var acTrieCache: [Set<String>: AhoCorasick] = [:]

    private func getOrCreateACTrie(for entries: [GlossaryEntry]) -> AhoCorasick {
        let patternSet = Set(entries.map { $0.source })

        if let cached = acTrieCache[patternSet] {
            return cached
        }

        let ac = AhoCorasick(patterns: Array(patternSet))
        acTrieCache[patternSet] = ac
        return ac
    }
}
```

**장점:**
- AC 트라이 구성 시간 절약 (O(m) where m = 총 패턴 길이)

**주의사항:**
- 캐시 크기 관리 필요
- 패턴이 매번 다르면 효과 없음

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

### 9.5 메인 스레드 부하 (중요!)

**문제**: `fetchData`/`buildEntriesForSegment`가 모두 `@MainActor`에서 실행되면 UI 스터터 발생 가능

현재 설계에서 메인 스레드 부하 발생 지점:
1. `fetchData`: Q-gram 리콜, AC 트라이 구성, 문자열 매칭
2. `buildEntriesForSegment`: 패턴 조합 생성, AC 필터링 (세그먼트 수만큼 반복!)
3. 특히 세그먼트가 많을 때 (10+ 세그먼트) 누적 부하 증가

**대응 전략**:

#### 1. SwiftData 접근 최소화
```swift
extension Glossary {
    public final class DataProvider: DataProviding {
        @MainActor
        public func fetchData(for pageText: String) throws -> GlossaryData {
            // MainActor 필수: SwiftData 접근
            let candidateKeys = try Recall.recallTermKeys(...)
            let candidateTerms = try Store.fetchTerms(keys: candidateKeys, ctx: context)
            let patterns = try Store.fetchPatterns(ctx: context)

            // 여기서 MainActor 탈출!
            return await withCheckedContinuation { continuation in
                Task.detached {
                    // 백그라운드: AC 트라이 구성 및 매칭
                    let acBundle = Matcher.makeACBundle(from: candidateTerms)
                    let hits = acBundle.ac.find(in: pageText)

                    // 매칭 테이블 구성
                    var matchedSourcesByKey: [String: Set<String>] = [:]
                    // ... 매칭 로직

                    let data = GlossaryData(...)
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
```

#### 2. Composer도 백그라운드 처리
```swift
public final class GlossaryComposer {
    // MainActor 제거!
    public func buildEntriesForSegment(
        from data: GlossaryData,
        segmentText: String
    ) async -> [GlossaryEntry] {
        // 모든 문자열 처리는 백그라운드에서 안전
        let standaloneEntries = buildStandaloneEntries(...)
        let composedEntries = buildComposedEntriesForSegment(...)

        return Deduplicator.deduplicate(standaloneEntries + composedEntries)
    }
}
```

#### 3. TranslationRouter 수정
```swift
final class DefaultTranslationRouter: TranslationRouter {
    private func fetchGlossaryData(...) async -> GlossaryData? {
        guard shouldApply else { return nil }

        // MainActor는 fetchData 내부에서만
        return await MainActor.run {
            try? glossaryDataProvider.fetchData(for: fullText)
        }
    }

    private func prepareMaskingContext(...) async -> MaskingContext {
        // 세그먼트 루프는 백그라운드
        for segment in segments {
            let glossaryEntries = await glossaryComposer.buildEntriesForSegment(
                from: glossaryData,
                segmentText: segment.originalText
            )

            // MainActor 필요: TermMasker가 UI 관련일 경우
            let pieces = await MainActor.run {
                termMasker.buildSegmentPieces(segment: segment, glossary: glossaryEntries)
            }
            // ...
        }
        return MaskingContext(...)
    }
}
```

**핵심 원칙**:
1. **SwiftData 접근만 MainActor**: `context.fetch()`, `context.insert()` 등
2. **문자열 처리는 백그라운드**: AC 트라이 구성, 매칭, 조합 생성
3. **세그먼트 루프 전체는 백그라운드**: 10개 세그먼트 * 각 100ms = 1초 UI 프리즈 방지
4. **필요한 경우만 MainActor로 전환**: UI 업데이트, SwiftData 접근

**검증 방법**:
- Instruments의 Time Profiler로 메인 스레드 점유율 측정
- 10+ 세그먼트 페이지에서 UI 반응성 테스트
- 목표: 메인 스레드 점유 < 100ms (프레임 드랍 방지)

### 9.6 페이지 텍스트 결합 시 경계 문제

**문제**: 세그먼트 텍스트를 공백 없이 이어붙이면 경계에서 오탐/미탐 발생 가능

**현재 구현**:
```swift
let fullText = segments.map({ $0.originalText }).joined()
// "Hello world" + "Nice day" → "Hello worldNice day"
```

**발생 가능한 문제**:
1. **오탐 (False Positive)**:
   - 세그먼트 1: "super"
   - 세그먼트 2: "man"
   - 결합: "superman" → 의도하지 않은 매칭

2. **미탐 (False Negative)**:
   - 일반적으로는 문제 없음 (세그먼트는 문장 단위이므로)
   - 하지만 긴 단어가 세그먼트 경계를 넘으면 매칭 실패 가능

**현재 설계의 타당성**:
- 대부분의 경우 세그먼트는 문장 단위로 분리됨
- 문장은 자연스러운 공백으로 구분됨
- 실제 오탐/미탐 확률은 낮음

**대응 방안**:

#### Option 1: 현상 유지 + 명시적 인지
```swift
// 코드 주석으로 명시
let fullText = segments.map({ $0.originalText }).joined()
// 주의: 세그먼트 경계에서 공백 없이 결합됨
// 대부분의 경우 문제 없으나, 드물게 오탐 가능성 존재
```

**장점**:
- 구현 단순
- 실용적 (실제 문제 발생 확률 낮음)

**단점**:
- 이론적 오탐 가능성 존재

#### Option 2: 공백으로 결합 (권장하지 않음)
```swift
let fullText = segments.map({ $0.originalText }).joined(separator: " ")
```

**문제점**:
- 원본 텍스트에 없는 공백 추가
- AC 매칭 결과가 실제 세그먼트와 불일치
- 더 큰 문제 발생 가능

#### Option 3: 세그먼트별 데이터 조회 (과도한 최적화)
```swift
// 각 세그먼트마다 독립적으로 데이터 조회
for segment in segments {
    let data = await fetchGlossaryData(fullText: segment.originalText)
    // ...
}
```

**문제점**:
- 성능 저하 (N회 조회)
- Q-gram 리콜 효율 감소
- 복잡도 증가

**권장 방안**: Option 1 (현상 유지)
- 세그먼트 경계 오탐은 실무에서 거의 발생하지 않음
- 발생하더라도 사용자가 수동으로 수정 가능
- 복잡도 증가 대비 이득이 크지 않음

**모니터링**:
- 사용자 피드백으로 실제 문제 발생 빈도 측정
- 필요시 추후 개선 (세그먼트 경계에 특수 마커 삽입 등)

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
