# SPEC: Term 문맥 기반 비활성화 (Context Deactivation)

## 문서 정보

- **작성일**: 2025-01-26
- **버전**: 2.0 (통합 아키텍처)
- **상태**: 설계 완료

---

## 1. 기능 개요

### 1.1 문제점

현재 Term 정규화는 **부분 문자열 매칭**으로 인한 오역이 발생합니다.

**예시:**
```
Term "sorato":
  sources: ["宙人"]
  target: "소라토"
  variants: ["주인"]

세그먼트: "我是宇宙人。" (나는 우주인이다)

현재 동작:
  - "宙人"이 "宇宙人" 내부에서 매칭됨
  - 잘못된 정규화: "나는 우소라토이다" ❌

기대 동작:
  - "宙人"이 "宇宙人" 안에 있을 때는 비활성화
  - 올바른 번역: "나는 우주인이다" ✓
```

### 1.2 해결 방안

Term에 `deactivatedIn` 필드를 추가하여, **특정 문맥 내부에서는 해당 Term을 비활성화**합니다.

### 1.3 핵심 개념

**Deactivation Context:**
- Term의 source가 특정 텍스트 **안에 포함될 때** 비활성화
- 예: source "宙人"이 context "宇宙人" 안에 있으면 비활성화

**Source별 판단:**
- Term의 각 source마다 독립적으로 deactivation 체크
- 하나의 source라도 활성화되면 해당 Term 사용 가능

### 1.4 표준 예시

이 문서 전체에서 사용하는 통일된 예시:

```swift
SDTerm "sorato":
  key: "sorato"
  sources: [SDSource(text: "宙人", prohibitStandalone: false)]
  target: "소라토"
  variants: ["주인"]
  deactivatedIn: ["宇宙人"]
```

**테스트 세그먼트:**

**케이스 1: 활성화**
```
세그먼트: "宙人是地球人。" (소라토는 지구인이다)

처리:
  - "宙人" 매칭 (offset 0)
  - "宇宙人" 검색 → 세그먼트에 없음
  - 활성화 ✓
  - 번역: "소라토는 지구인이다"
```

**케이스 2: 비활성화**
```
세그먼트: "我是宇宙人。" (나는 우주인이다)

처리:
  - "宙人" 매칭 (offset 2)
  - "宇宙人" 검색 → offset 2에서 발견
  - "宙人"이 "宇宙人" 안에 포함됨 (offset 2 >= 2, end 4 <= 5)
  - 비활성화 ✓
  - 번역: "나는 우주인이다"
```

---

## 2. 데이터 모델

### 2.1 SDTerm 확장

```swift
@Model
public final class SDTerm {
    var key: String
    var target: String
    var variants: [String]
    @Relationship var sources: [SDSource]
    var components: [SDComponent]
    var preMask: Bool
    var isAppellation: Bool
    @Relationship var activators: [SDTerm]
    @Relationship var activates: [SDTerm]

    // 신규: 비활성화 문맥 목록
    var deactivatedIn: [String] = []

    public init(
        key: String,
        target: String,
        variants: [String] = [],
        sources: [SDSource] = [],
        components: [SDComponent] = [],
        preMask: Bool = false,
        isAppellation: Bool = false,
        deactivatedIn: [String] = []
    ) {
        self.key = key
        self.target = target
        self.variants = variants
        self.sources = sources
        self.components = components
        self.preMask = preMask
        self.isAppellation = isAppellation
        self.deactivatedIn = deactivatedIn
    }
}
```

**필드 설명:**
- `deactivatedIn`: 이 배열의 문자열 안에 source가 포함되면 비활성화
- 빈 배열 = 비활성화 조건 없음

**SDSource는 변경 없음:**
```swift
@Model
public final class SDSource {
    var text: String
    var prohibitStandalone: Bool
    @Relationship var term: SDTerm?

    // deactivation 필드 없음 (Term 단위로 관리)
}
```

### 2.2 GlossaryEntry 확장

```swift
public struct GlossaryEntry: Hashable, Sendable {
    public var source: String
    public var target: String
    public var variants: [String]
    public var preMask: Bool
    public var isAppellation: Bool
    public var origin: Origin
    public var componentTerms: [ComponentTerm]

    public init(
        source: String,
        target: String,
        variants: [String] = [],
        preMask: Bool = false,
        isAppellation: Bool = false,
        origin: Origin,  // required - 기본값 없음
        componentTerms: [ComponentTerm] = []
    ) {
        self.source = source
        self.target = target
        self.variants = variants
        self.preMask = preMask
        self.isAppellation = isAppellation
        self.origin = origin
        self.componentTerms = componentTerms
    }
}
```

**변경 사항 (생성 시 주입 금지 필드 포함):**
- `activatorKeys` 제거: Phase 2에서 `SDTerm.activators`를 직접 사용
- `activatesKeys` 제거: 활성화는 SDTerm 단계에서 완료, Entry는 최종 결과물일 뿐
- `deactivatedIn` 제거: Phase 0에서 필터링 완료
- **GlossaryEntry는 활성화 계산에 사용되지 않음** - Phase 4에서 즉석 생성되는 최종 산출물
- 생성 코드에서도 위 필드들을 넣지 않는다. Phase 4 레거시 정리 시 전체 코드베이스에서 제거된 필드를 참조/주입하는 곳을 추가로 청소한다(중복 체크를 위해 후순위 수행).

### 2.3 ComponentTerm (단순화)

```swift
public extension GlossaryEntry {
    struct ComponentTerm: Hashable, Sendable {
        public let key: String
        public let target: String
        public let variants: [String]  // 사용된 변형(리스트)
        public let source: String        // 단일 source 텍스트만

        public init(key: String, target: String, variants: [String], source: String) {
            self.key = key
            self.target = target
            self.variants = variants
            self.source = source
        }

        public static func make(from appearedTerm: AppearedTerm) -> ComponentTerm {
            let sourceText = appearedTerm.appearedSources.first?.text ?? ""
            return ComponentTerm(
                key: appearedTerm.key,
                target: appearedTerm.target,
                variants: appearedTerm.variants,
                source: sourceText
            )
        }
    }
}
```

**변경 사항:**
- **단순화**: key, target, variants, source만 유지
- **제거된 필드**: sources, matchedSources, preMask, isAppellation, Source 중첩 구조
- **용도**: UI/디버깅 - "이 Entry는 어떤 source들로 조합되었는가" 표시
- **AppearedTerm 기반**: 필터링된 appearedSources 사용
- **호환성**: `BrowserViewModel+GlossaryAdd.makeCandidateEntry`에서 variants를 사용하므로 필드를 유지합니다. 해당 ViewModel이 리팩토링되기 전까지는 GlossaryEntry 생성 시 필수 필드를 임시 값으로 채워 빌드 오류를 막으면 됩니다.

### 2.4 AppearedTerm

`buildSegmentPieces` 내부에서 사용하는 중간 데이터 구조로, **세그먼트에 실제로 등장하면서 비활성화되지 않은 sources**만 포함합니다.

```swift
public struct AppearedTerm {
    public let sdTerm: SDTerm
    public let appearedSources: [SDSource]  // 세그먼트에 등장 + 비활성화 안 됨

    // SDTerm의 편의 프로퍼티들
    public var key: String { sdTerm.key }
    public var target: String { sdTerm.target }
    public var variants: [String] { sdTerm.variants }
    public var components: [SDComponent] { sdTerm.components }
    public var preMask: Bool { sdTerm.preMask }
    public var isAppellation: Bool { sdTerm.isAppellation }
    public var activators: [SDTerm] { sdTerm.activators }
    public var activates: [SDTerm] { sdTerm.activates }

    public init(sdTerm: SDTerm, appearedSources: [SDSource]) {
        self.sdTerm = sdTerm
        self.appearedSources = appearedSources
    }
}
```

**목적:**
- Phase 0에서 한 번 필터링한 후, Phase 1-3에서 재사용
- matchedTerms를 여러 번 순회하는 비효율 제거

**예시:**
```swift
// 세그먼트: "我是宇宙人。"
// matchedTerms: [sorato, ginga, ...]

// Phase 0 후:
AppearedTerm(
    sdTerm: sorato,
    appearedSources: []  // "宙人"이 deactivatedIn에 의해 필터링됨
)
// → Phase 1-3에서 제외됨

// 세그먼트: "宙人是地球人。"
AppearedTerm(
    sdTerm: sorato,
    appearedSources: [SDSource(text: "宙人", prohibitStandalone: false)]
)
// → Phase 1-3에서 사용됨
```

### 2.5 AppearedComponent

Phase 3 Composer에서 사용하는 중간 데이터 구조로, **SDComponent + AppearedTerm** 조합입니다.

```swift
public struct AppearedComponent {
    public let appearedTerm: AppearedTerm
    public let pattern: String
    public let role: String?
    public let srcTplIdx: Int?
    public let tgtTplIdx: Int?
    public let groupLinks: [SDGroupLink]

    public init(from component: SDComponent, appearedTerm: AppearedTerm) {
        self.appearedTerm = appearedTerm
        self.pattern = component.pattern
        self.role = component.role
        self.srcTplIdx = component.srcTplIdx
        self.tgtTplIdx = component.tgtTplIdx
        self.groupLinks = component.groupLinks
    }
}
```

**목적:**
- SDComponent의 term(원본 SDTerm) 대신 AppearedTerm 사용
- matchedPairs/matchedLeftComponents가 이 타입 반환
- 필터링된 appearedSources 기반으로 ComponentTerm 생성

### 2.6 Deduplicator 병합 정책

`Deduplicator.deduplicate()`는 동일한 `(source, target, preMask, isAppellation)` 키를 가진 Entry를 병합합니다.

**병합 전략: Array Union (중복 제거)**

```swift
// Deduplicator.swift의 병합 블록 내부:
// variants가 이제 Array이므로 Set으로 변환 후 union, 다시 Array로
let combinedVariants = Set(existing.variants).union(entry.variants)
existing.variants = Array(combinedVariants)
```

**근거:**
- 여러 경로로 생성된 Entry가 합쳐질 수 있음
- Union으로 모든 정보 보존 (중복 제거)
- variants는 Array로 저장하되 병합 시 Set union 적용

---

## 3. Google Sheets Import

### 3.1 포맷

**권장 방식: `deactivated_in` 컬럼 추가**

| key | target | sources | deactivated_in |
|-----|--------|---------|----------------|
| sorato | 소라토 | 宙人 | 宇宙人 |
| hikaru | 히카루 | 光 | 光波,光線 |
| ginga | 긴가 | 银河 | |

**컬럼 형식:**
- **deactivated_in**: 쉼표(`,`)로 구분된 비활성화 문맥 목록
- 각 문자열 안에 source가 포함되면 비활성화
- 빈 값: 비활성화 조건 없음
- 공백: 자동 trim 처리

**예시:**
```
deactivated_in: "宇宙人"           → ["宇宙人"]
deactivated_in: "光波, 光線"       → ["光波", "光線"]
deactivated_in: ""                → []
deactivated_in: "宇宙人,火星人"    → ["宇宙人", "火星人"]
```

### 3.2 파싱 로직

**Glossary.Sheet 확장:**

```swift
extension Glossary.Sheet {
    struct ParsedTerm {
        let key: String
        let target: String
        let variants: [String]
        let sources: [ParsedSource]
        let isAppellation: Bool
        let preMask: Bool
        let activatedByKeys: [String]
        let deactivatedIn: [String]  // 신규
    }

    struct ParsedSource {
        let text: String
        let prohibitStandalone: Bool
    }

    static func parseTermRow(_ row: [String], headers: [String]) -> ParsedTerm? {
        // 기존 파싱 (key, target, variants, sources 등)
        guard let keyIndex = headers.firstIndex(of: "key"),
              let targetIndex = headers.firstIndex(of: "target"),
              keyIndex < row.count, targetIndex < row.count else {
            return nil
        }

        let key = row[keyIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let target = row[targetIndex].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty, !target.isEmpty else { return nil }

        // variants 파싱
        let variantsStr = getColumnValue(row, headers, "variants")
        let variants = parseDelimitedList(variantsStr)

        // sources 파싱
        let sourcesStr = getColumnValue(row, headers, "sources")
        let sourceParts = sourcesStr.split(separator: "|").map { String($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var parsedSources: [ParsedSource] = []
        for sourcePart in sourceParts {
            let (sourceText, prohibit) = parseSourceWithProhibit(sourcePart)
            parsedSources.append(
                ParsedSource(text: sourceText, prohibitStandalone: prohibit)
            )
        }

        // deactivated_in 파싱 (신규)
        let deactivatedInStr = getColumnValue(row, headers, "deactivated_in")
        let deactivatedIn = parseDelimitedList(deactivatedInStr)

        // 기타 필드 파싱
        let isAppellation = getColumnValue(row, headers, "is_appellation").lowercased() == "true"
        let preMask = getColumnValue(row, headers, "pre_mask").lowercased() == "true"

        let activatedByStr = getColumnValue(row, headers, "activated_by")
        let activatedByKeys = parseDelimitedList(activatedByStr)

        return ParsedTerm(
            key: key,
            target: target,
            variants: variants,
            sources: parsedSources,
            isAppellation: isAppellation,
            preMask: preMask,
            activatedByKeys: activatedByKeys,
            deactivatedIn: deactivatedIn  // 신규
        )
    }

    /// 쉼표 구분 리스트 파싱
    private static func parseDelimitedList(_ str: String) -> [String] {
        guard !str.isEmpty else { return [] }

        return str.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 헬퍼: 컬럼 값 가져오기
    private static func getColumnValue(_ row: [String], _ headers: [String], _ columnName: String) -> String {
        guard let index = headers.firstIndex(of: columnName), index < row.count else {
            return ""
        }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Source와 prohibit 파싱
    private static func parseSourceWithProhibit(_ sourcePart: String) -> (text: String, prohibit: Bool) {
        if sourcePart.hasPrefix("!") {
            return (String(sourcePart.dropFirst()), true)
        } else {
            return (sourcePart, false)
        }
    }
}
```

### 3.3 Upsert 로직

**GlossarySDUpserter 수정:**

```swift
extension Glossary.SDUpserter {
    func upsertTermsFromSheet(_ parsedTerms: [Glossary.Sheet.ParsedTerm], context: ModelContext) async throws {
        for parsed in parsedTerms {
            let term: SDTerm

            // 기존 Term 찾기 또는 생성
            if let existing = try? context.fetch(
                FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == parsed.key })
            ).first {
                term = existing
            } else {
                term = SDTerm(key: parsed.key)
                context.insert(term)
            }

            // 기본 필드 업데이트
            term.target = parsed.target
            term.variants = parsed.variants
            term.isAppellation = parsed.isAppellation
            term.preMask = parsed.preMask
            term.deactivatedIn = parsed.deactivatedIn  // 신규

            // Sources 업데이트
            term.sources.removeAll()
            for parsedSource in parsed.sources {
                let source = SDSource(
                    text: parsedSource.text,
                    prohibitStandalone: parsedSource.prohibitStandalone,
                    term: term
                )
                context.insert(source)
                term.sources.append(source)
            }

            // activator 관계 설정 (기존 로직)
            // ...
        }

        try context.save()
    }
}
```

---

## 4. TermActivationFilter

### 4.1 역할

Source 단위 deactivation 판단만 담당합니다. `buildSegmentPieces` 내부에서 호출됩니다.

### 4.2 구현

```swift
public final class TermActivationFilter {

    /// Source가 deactivated context 안에 있는지 판단
    /// - Returns: true면 비활성화해야 함, false면 활성화 유지
    public func shouldDeactivate(
        source: String,
        deactivatedIn: [String],
        segmentText: String
    ) -> Bool {
        guard !deactivatedIn.isEmpty else { return false }

        // Deactivated context가 세그먼트에 한 번이라도 나타나면 비활성화
        for deactivatedText in deactivatedIn {
            if segmentText.contains(deactivatedText) {
                return true
            }
        }

        return false
    }
}
```

**단순화된 로직:**
- Deactivated context가 세그먼트 어디든 나타나면 즉시 비활성화
- Source의 위치나 범위 체크 불필요
- 성능 개선: `contains()` 만 사용

**예외 케이스 (유저 에러):**
```swift
// source == deactivatedText인 케이스
SDTerm "bad_example":
  sources: ["宇宙人"]
  deactivatedIn: ["宇宙人"]

// 이 경우 shouldDeactivate는 true를 반환합니다.
// 이는 본 기능의 의도된 사용 방법이 아니며, 유저가 잘못 입력한 경우입니다.
// 정상적인 사용에서는 source가 deactivatedText의 부분 문자열이어야 합니다.
```

### 4.3 예시 실행

**케이스 1: "我是宇宙人。"**

```swift
shouldDeactivate(source: "宙人", deactivatedIn: ["宇宙人"], segmentText: "我是宇宙人。")

1. deactivatedIn.isEmpty → false, 계속
2. for deactivatedText in ["宇宙人"]:
   - segmentText.contains("宇宙人") → true
3. return true (비활성화)
```

**케이스 2: "宙人是地球人。"**

```swift
shouldDeactivate(source: "宙人", deactivatedIn: ["宇宙人"], segmentText: "宙人是地球人。")

1. deactivatedIn.isEmpty → false, 계속
2. for deactivatedText in ["宇宙人"]:
   - segmentText.contains("宇宙人") → false
3. return false (활성화)
```

---

## 5. TermMasker 통합 구현

### 5.1 새 시그니처

```swift
public final class TermMasker {
    func buildSegmentPieces(
        segment: Segment,
        matchedTerms: [SDTerm],
        patterns: [SDPattern],
        matchedSources: [String: Set<String>],
        termActivationFilter: TermActivationFilter
    ) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry])
}
```

**변경 사항:**
- ❌ `glossary: [GlossaryEntry]` 파라미터 제거
- ✅ 원시 데이터 직접 받음 (`matchedTerms`, `patterns`, `matchedSources`)
- ✅ `termActivationFilter` 의존성 주입
- ✅ **SegmentPieces와 [GlossaryEntry] 모두 반환**
  - `pieces`: makeNameGlossariesFromPieces에 전달
  - `glossaryEntries`: Deduplicator에 전달

### 5.2 통합 로직 구현

**핵심 변경사항:**
- **Phase 0 추가**: 등장 체크 + 비활성화 필터링을 한 번만 수행
- **AppearedTerm 사용**: Phase 1-3에서 matchedTerms 대신 appearedTerms 사용
- **빈 세그먼트 처리**: matchedTerms가 비어도 `[.text(text)]` 반환
- **SegmentPieces와 [GlossaryEntry] 모두 반환**: 반환한 glossaryEntries도 prepareMaskingContext에서 사용

```swift
func buildSegmentPieces(
    segment: Segment,
    matchedTerms: [SDTerm],
    patterns: [SDPattern],
    matchedSources: [String: Set<String>],
    termActivationFilter: TermActivationFilter
) -> (pieces: SegmentPieces, glossaryEntries: [GlossaryEntry]) {
    let text = segment.originalText

    // 빈 세그먼트 처리: 항상 최소한 .text 조각 반환
    guard !text.isEmpty, !matchedTerms.isEmpty else {
        return (
            pieces: SegmentPieces(segmentID: segment.id, originalText: text, pieces: [.text(text, range: text.startIndex..<text.endIndex)]),
            glossaryEntries: []
        )
    }

    // 초기화
    var pieces: [SegmentPieces.Piece] = [.text(text, range: text.startIndex..<text.endIndex)]
    var usedTermKeys: Set<String> = []
    var sourceToEntry: [String: GlossaryEntry] = [:]  // source → GlossaryEntry 매핑

    // === Phase 0: Appearance Check & Deactivation Filtering ===

    let appearedTerms: [AppearedTerm] = matchedTerms.compactMap { term in
        // 1. 세그먼트에 등장하는 sources 필터링
        let appearedSources = term.sources.filter { source in
            // matchedSources에 포함되지 않으면 제외
            guard let matchedSourceTexts = matchedSources[term.key],
                  matchedSourceTexts.contains(source.text) else {
                return false
            }

            // 세그먼트에 실제로 등장하는지 확인
            guard text.contains(source.text) else {
                return false
            }

            // 2. Deactivation 체크
            return !termActivationFilter.shouldDeactivate(
                source: source.text,
                deactivatedIn: term.deactivatedIn,
                segmentText: text
            )
        }

        // 등장한 source가 하나도 없으면 제외
        guard !appearedSources.isEmpty else { return nil }

        return AppearedTerm(sdTerm: term, appearedSources: appearedSources)
    }

    // === Phase 1: Standalone Activation ===

    for appearedTerm in appearedTerms {
        for source in appearedTerm.appearedSources {
            // prohibitStandalone=false인 source만 즉시 사용
            if !source.prohibitStandalone {
                sourceToEntry[source.text] = GlossaryEntry(
                    source: source.text,
                    target: appearedTerm.target,
                    variants: appearedTerm.variants,
                    preMask: appearedTerm.preMask,
                    isAppellation: appearedTerm.isAppellation,
                    origin: .termStandalone(termKey: appearedTerm.key),
                    componentTerms: [
                        GlossaryEntry.ComponentTerm.make(from: appearedTerm)
                    ]
                )
                usedTermKeys.insert(appearedTerm.key)
            }
        }
    }

    // === Phase 2: Term-to-Term Activation ===

    for appearedTerm in appearedTerms {
        guard !usedTermKeys.contains(appearedTerm.key) else { continue }

        // Activator 체크
        let activatorKeys = Set(appearedTerm.activators.map { $0.key })
        guard !activatorKeys.isEmpty && !activatorKeys.isDisjoint(with: usedTermKeys) else {
            continue
        }

        // 활성화됨 → prohibitStandalone=true인 source도 사용
        for source in appearedTerm.appearedSources {
            guard source.prohibitStandalone else { continue }  // true만

            sourceToEntry[source.text] = GlossaryEntry(
                source: source.text,
                target: appearedTerm.target,
                variants: appearedTerm.variants,
                preMask: appearedTerm.preMask,
                isAppellation: appearedTerm.isAppellation,
                origin: .termStandalone(termKey: appearedTerm.key),
                componentTerms: [
                    GlossaryEntry.ComponentTerm.make(from: appearedTerm)
                ]
            )
        }

        usedTermKeys.insert(appearedTerm.key)
    }

    // === Phase 3: Composer Entries ===

    let composerEntries = buildComposerEntries(
        patterns: patterns,
        appearedTerms: appearedTerms,
        segmentText: text
    )

    // Composer sources를 sourceToEntry에 병합 (standalone 우선)
    for entry in composerEntries {
        if sourceToEntry[entry.source] == nil {
            sourceToEntry[entry.source] = entry
        }
    }

    // === Phase 4: Longest-First Segmentation ===

    // Source를 길이 순으로 정렬
    let sortedSources = sourceToEntry.keys.sorted { $0.count > $1.count }

    for source in sortedSources {
        guard let entry = sourceToEntry[source] else { continue }
        var newPieces: [SegmentPieces.Piece] = []

        for piece in pieces {
            switch piece {
            case .text(let str, let pieceRange):
                guard str.contains(source) else {
                    newPieces.append(.text(str, range: pieceRange))
                    continue
                }

                // 분할 로직
                var searchStart = str.startIndex
                while let foundRange = str.range(of: source, range: searchStart..<str.endIndex) {
                    // 앞쪽 텍스트 조각
                    if foundRange.lowerBound > searchStart {
                        let prefixLower = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: searchStart)
                        )
                        let prefixUpper = text.index(
                            pieceRange.lowerBound,
                            offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                        )
                        let prefix = String(str[searchStart..<foundRange.lowerBound])
                        newPieces.append(.text(prefix, range: prefixLower..<prefixUpper))
                    }

                    // 용어 조각 (Entry 즉석 생성)
                    let originalLower = text.index(
                        pieceRange.lowerBound,
                        offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                    )
                    let originalUpper = text.index(originalLower, offsetBy: source.count)
                    newPieces.append(.term(entry, range: originalLower..<originalUpper))

                    searchStart = foundRange.upperBound
                }

                // 남은 텍스트 조각
                if searchStart < str.endIndex {
                    let suffixLower = text.index(
                        pieceRange.lowerBound,
                        offsetBy: str.distance(from: str.startIndex, to: searchStart)
                    )
                    let suffix = String(str[searchStart...])
                    newPieces.append(.text(suffix, range: suffixLower..<pieceRange.upperBound))
                }

            case .term:
                newPieces.append(piece)
            }
        }

        pieces = newPieces
    }

    // === 반환: SegmentPieces + [GlossaryEntry] ===

    let segmentPieces = SegmentPieces(
        segmentID: segment.id,
        originalText: text,
        pieces: pieces
    )

    let glossaryEntries = Array(sourceToEntry.values)

    return (pieces: segmentPieces, glossaryEntries: glossaryEntries)
}
```

### 5.3 Composer 헬퍼 메서드 (GlossaryEntry 생성)

**buildComposerEntries:**

```swift
private func buildComposerEntries(
    patterns: [SDPattern],
    appearedTerms: [AppearedTerm],
    segmentText: String
) -> [GlossaryEntry] {
    var allEntries: [GlossaryEntry] = []

    for pattern in patterns {
        let usesR = pattern.sourceTemplates.contains { $0.contains("{R}") }
            || pattern.targetTemplates.contains { $0.contains("{R}") }

        if usesR {
            // Pair patterns
            let pairs = matchedPairs(for: pattern, appearedTerms: appearedTerms)
            allEntries.append(contentsOf: buildEntriesFromPairs(
                pairs: pairs,
                pattern: pattern,
                segmentText: segmentText
            ))
        } else {
            // Left-only patterns
            let lefts = matchedLeftComponents(for: pattern, appearedTerms: appearedTerms)
            allEntries.append(contentsOf: buildEntriesFromLefts(
                lefts: lefts,
                pattern: pattern,
                segmentText: segmentText
            ))
        }
    }

    return allEntries
}
```

**matchedPairs (AppearedComponent 반환):**

```swift
private func matchedPairs(
    for pattern: SDPattern,
    appearedTerms: [AppearedTerm]
) -> [(AppearedComponent, AppearedComponent)] {
    var lefts: [AppearedComponent] = []
    var rights: [AppearedComponent] = []
    var hasAnyGroup = false

    // appearedTerms에서 L/R component 수집
    for appearedTerm in appearedTerms {
        for component in appearedTerm.components where component.pattern == pattern.name {
            let isLeft = matchesRole(component.role, required: pattern.leftRole)
            let isRight = matchesRole(component.role, required: pattern.rightRole)

            if !component.groupLinks.isEmpty { hasAnyGroup = true }

            let appearedComponent = AppearedComponent(from: component, appearedTerm: appearedTerm)

            if isLeft { lefts.append(appearedComponent) }
            if isRight { rights.append(appearedComponent) }
        }
    }

    // 그룹 링크가 없으면 Cartesian product
    if !hasAnyGroup {
        var pairs: [(AppearedComponent, AppearedComponent)] = []
        for l in lefts {
            for r in rights where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                pairs.append((l, r))
            }
        }
        return pairs
    }

    // 그룹 링크 기반 페어링
    var leftByGroup: [String: [AppearedComponent]] = [:]
    var rightByGroup: [String: [AppearedComponent]] = [:]

    for component in lefts {
        for g in component.groupLinks.map({ $0.group.uid }) {
            leftByGroup[g, default: []].append(component)
        }
    }
    for component in rights {
        for g in component.groupLinks.map({ $0.group.uid }) {
            rightByGroup[g, default: []].append(component)
        }
    }

    var pairs: [(AppearedComponent, AppearedComponent)] = []
    for g in leftByGroup.keys {
        guard let ls = leftByGroup[g], let rs = rightByGroup[g] else { continue }
        for l in ls {
            for r in rs where (!pattern.skipPairsIfSameTerm || l.appearedTerm.key != r.appearedTerm.key) {
                pairs.append((l, r))
            }
        }
    }

    return pairs
}

private func matchesRole(_ componentRole: String?, required: String?) -> Bool {
    guard
        let requiredRole = required?.trimmingCharacters(in: .whitespacesAndNewlines),
        !requiredRole.isEmpty
    else {
        return true
    }
    guard
        let role = componentRole?.trimmingCharacters(in: .whitespacesAndNewlines),
        !role.isEmpty
    else {
        return false
    }
    return role == requiredRole
}
```

**matchedLeftComponents (AppearedComponent 반환):**

```swift
private func matchedLeftComponents(
    for pattern: SDPattern,
    appearedTerms: [AppearedTerm]
) -> [AppearedComponent] {
    var out: [AppearedComponent] = []
    for appearedTerm in appearedTerms {
        for component in appearedTerm.components where component.pattern == pattern.name {
            if matchesRole(component.role, required: pattern.leftRole) {
                out.append(AppearedComponent(from: component, appearedTerm: appearedTerm))
            }
        }
    }
    return out
}
```

### 5.4 Composer Entry 생성 메서드

**buildEntriesFromPairs:**

```swift
private func buildEntriesFromPairs(
    pairs: [(AppearedComponent, AppearedComponent)],
    pattern: SDPattern,
    segmentText: String
) -> [GlossaryEntry] {
    var entries: [GlossaryEntry] = []
    let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

    for (lComp, rComp) in pairs {
        let leftTerm = lComp.appearedTerm
        let rightTerm = rComp.appearedTerm

        let srcTplIdx = lComp.srcTplIdx ?? rComp.srcTplIdx ?? 0
        let tgtTplIdx = lComp.tgtTplIdx ?? rComp.tgtTplIdx ?? 0
        let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}{J}{R}"
        let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L} {R}"
        let variants: [String] = Glossary.Util.renderVariants(srcTpl, joiners: pattern.sourceJoiners, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

        for joiner in joiners {
            let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: leftTerm.sdTerm, R: rightTerm.sdTerm)
            let tgt = Glossary.Util.renderTarget(tgtTpl, L: leftTerm.sdTerm, R: rightTerm.sdTerm)

            for src in srcs {
                entries.append(
                    GlossaryEntry(
                        source: src,
                        target: tgt,
                        variants: variants,
                        preMask: pattern.preMask,
                        isAppellation: pattern.isAppellation,
                        origin: .composer(
                            composerId: pattern.name,
                            leftKey: leftTerm.key,
                            rightKey: rightTerm.key,
                            needPairCheck: pattern.needPairCheck
                        ),
                        componentTerms: [
                            GlossaryEntry.ComponentTerm.make(from: leftTerm),
                            GlossaryEntry.ComponentTerm.make(from: rightTerm)
                        ]
                    )
                )
            }
        }
    }

    return entries
}
```

**buildEntriesFromLefts:**

```swift
private func buildEntriesFromLefts(
    lefts: [AppearedComponent],
    pattern: SDPattern,
    segmentText: String
) -> [GlossaryEntry] {
    var entries: [GlossaryEntry] = []
    let joiners = Glossary.Util.filterJoiners(from: pattern.sourceJoiners, in: segmentText)

    for lComp in lefts {
        let term = lComp.appearedTerm

        let srcTplIdx = lComp.srcTplIdx ?? 0
        let tgtTplIdx = lComp.tgtTplIdx ?? 0
        let srcTpl = pattern.sourceTemplates[safe: srcTplIdx] ?? pattern.sourceTemplates.first ?? "{L}"
        let tgtTpl = pattern.targetTemplates[safe: tgtTplIdx] ?? pattern.targetTemplates.first ?? "{L}"
        let tgt = Glossary.Util.renderTarget(tgtTpl, L: term.sdTerm, R: nil)
        let variants = Glossary.Util.renderVariants(srcTpl, joiners: joiners, L: term.sdTerm, R: nil)

        for joiner in joiners {
            let srcs = Glossary.Util.renderSources(srcTpl, joiner: joiner, L: term.sdTerm, R: nil)

            for src in srcs {
                entries.append(
                    GlossaryEntry(
                        source: src,
                        target: tgt,
                        variants: variants,
                        preMask: pattern.preMask,
                        isAppellation: pattern.isAppellation,
                        origin: .composer(
                            composerId: pattern.name,
                            leftKey: term.key,
                            rightKey: nil,
                            needPairCheck: false
                        ),
                        componentTerms: [
                            GlossaryEntry.ComponentTerm.make(from: term)
                        ]
                    )
                )
            }
        }
    }

    return entries
}
```

### 5.5 기타

- `TermInfo` 구조체는 제거합니다. Composer/standalone 단계에서 바로 `GlossaryEntry`를 생성해 `sourceToEntry`에 저장합니다.

---

## 6. 전체 플로우

```
DefaultTranslationRouter.prepareMaskingContext() async
  ↓
await Task.detached {
  for each segment:
    │
    └─> TermMasker.buildSegmentPieces(
          segment,
          glossaryData.matchedTerms,
          glossaryData.patterns,
          glossaryData.matchedSourcesByKey,
          termActivationFilter
        )

        내부 처리:
          Phase 1: Standalone Activation
            - Source별 deactivation 체크
            - prohibitStandalone=false만 사용

          Phase 2: Term-to-Term Activation
            - usedTermKeys로 activator 체크
            - prohibitStandalone=true도 활성화

          Phase 3: Composer Entries
            - Pattern 매칭 (pairs/lefts)
            - 활성화된 term만 사용

          Phase 4: Pattern Proximity (선택적)

          Phase 5: Longest-First Segmentation
            - Entry 즉석 생성
            - 분할

        → SegmentPieces
}
```

---

## 7. 구현 우선순위

### Phase 1: 아키텍처 변경 (3일)

1. **TermActivationFilter 생성** (0.5일)
2. **TermMasker 통합** (2일)
3. **DefaultTranslationRouter 수정** (0.5일)

### Phase 2: 데이터 모델 & Import (1.5일)

4. **SDTerm 모델** (0.5일)
5. **Google Sheets Import** (0.5일)
6. **UI** (0.5일)

### Phase 3: 테스트 (1.5일)

> 공통 헬퍼: `buildSegmentPieces(segment:matchedTerms:patterns:matchedSources:termActivationFilter:)` 시그니처에 맞춰 호출한다.
> - `matchedSources`: `term.key → Set<source.text>`
> - `TermActivationFilter()`를 그대로 주입
> - GlossaryEntry/ComponentTerm은 `variants: [String]`, `ComponentTerm.source: String` 기준으로 검증
> - Composer 소스 생성은 `Glossary.Util.renderSources`의 `(composed,left,right)` 튜플 사용을 확인한다.

#### 7. 단위 테스트 (0.5일)

##### 7.1 Phase 0: Appearance & Deactivation 필터링

**Test 1: 기본 등장 체크**
```swift
let term = makeTerm(key: "sorato", sources: ["宙人", "ソラト"])
let matchedSources = ["sorato": Set(["宙人"])]
let segment = makeSegment(text: "宙人是地球人.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.contains { $0.source == "宙人" })
#expect(result.glossaryEntries.allSatisfy { $0.source != "ソラト" })
```

**Test 2: deactivatedIn 필터링 (단일 문맥)**
```swift
let term = makeTerm(
    key: "sorato",
    sources: [makeSource("宙人", prohibitStandalone: false)],
    deactivatedIn: ["宇宙人"]
)
let matchedSources = ["sorato": Set(["宙人"])]
let segment = makeSegment(text: "宇宙人宙人来了.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
#expect(result.pieces.allSatisfy { if case .term = $0 { return false }; return true })
```

**Test 3: deactivatedIn 복수 문맥**
```swift
let term = makeTerm(
    key: "sorato",
    sources: [makeSource("宙人", prohibitStandalone: false)],
    deactivatedIn: ["宇宙人", "外星人"]
)
let segment = makeSegment(text: "外星人宙人来了.")
let matchedSources = ["sorato": Set(["宙人"])]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
```

**Test 4: deactivatedIn 비어있음**
```swift
let term = makeTerm(
    key: "sorato",
    sources: [makeSource("宙人", prohibitStandalone: false)],
    deactivatedIn: []
)
let matchedSources = ["sorato": Set(["宙人"])]
let segment = makeSegment(text: "宇宙人宙人来了.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 1)
#expect(result.glossaryEntries.first?.source == "宙人")
```

**Test 5: 비활성화 문맥 불일치 시 활성화**
```swift
let term = makeTerm(
    key: "sorato",
    sources: [makeSource("宙人", prohibitStandalone: false)],
    deactivatedIn: ["宇宙人"]
)
let matchedSources = ["sorato": Set(["宙人"])]
let segment = makeSegment(text: "宙人来了.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 1)
```

##### 7.2 Phase 1: Standalone Activation

**Test 6: prohibitStandalone=false 즉시 활성화**
```swift
let term = makeTerm(
    key: "ultraman",
    sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
)
let matchedSources = ["ultraman": Set(["ウルトラマン"])]
let segment = makeSegment(text: "ウルトラマン登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 1)
#expect(result.glossaryEntries.first?.origin == .termStandalone(termKey: "ultraman"))
#expect(result.glossaryEntries.first?.source == "ウルトラマン")
```

**Test 7: prohibitStandalone=true는 Phase 1에서 스킵**
```swift
let term = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: []
)
let matchedSources = ["taro": Set(["太郎"])]
let segment = makeSegment(text: "太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
```

**Test 8: 복수 소스 중 permit만 활성화**
```swift
let term = makeTerm(
    key: "ultraman",
    sources: [
        makeSource("ウルトラマン", prohibitStandalone: false),
        makeSource("超人", prohibitStandalone: true)
    ],
    activators: []
)
let matchedSources = ["ultraman": Set(["ウルトラマン", "超人"])]
let segment = makeSegment(text: "ウルトラマン和超人.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 1)
#expect(result.glossaryEntries.first?.source == "ウルトラマン")
```

**Test 9: usedTermKeys 추적**
```swift
let term1 = makeTerm(
    key: "ultraman",
    sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
)
let term2 = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: [term1]
)
let matchedSources = [
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 2)
```

##### 7.3 Phase 2: Term-to-Term Activation

**Test 10: Activator 없음 → 스킵**
```swift
let term = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: []
)
let matchedSources = ["taro": Set(["太郎"])]
let segment = makeSegment(text: "太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
```

**Test 11: Activator가 비활성화되어 있으면 스킵**
```swift
let term1 = makeTerm(
    key: "ultraman",
    sources: [makeSource("ウルトラマン", prohibitStandalone: false)],
    deactivatedIn: ["宇宙人"]
)
let term2 = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: [term1]
)
let matchedSources = [
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "宇宙人ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
```

**Test 12: Activator가 usedTermKeys에 있으면 활성화**
```swift
let term1 = makeTerm(
    key: "ultraman",
    sources: [makeSource("ウルトラマン", prohibitStandalone: false)]
)
let term2 = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: [term1]
)
let matchedSources = [
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.count == 2)
#expect(result.glossaryEntries.contains { $0.source == "太郎" })
```

**Test 13: 복수 activators OR 조건**
```swift
let term1 = makeTerm(key: "ultraman", sources: [makeSource("ウルトラマン", prohibitStandalone: false)])
let term2 = makeTerm(key: "zero", sources: [makeSource("ゼロ", prohibitStandalone: false)])
let term3 = makeTerm(
    key: "taro",
    sources: [makeSource("太郎", prohibitStandalone: true)],
    activators: [term1, term2]
)
let matchedSources = [
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2, term3],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.contains { $0.source == "太郎" })
```

**Test 14: 자기 자신을 activator로 지정한 경우 스킵**
```swift
let term1 = makeTerm(
    key: "ultraman",
    sources: [makeSource("ウルトラマン", prohibitStandalone: true)]
)
term1.activators.append(term1)
let matchedSources = ["ultraman": Set(["ウルトラマン"])]
let segment = makeSegment(text: "ウルトラマン登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
```

##### 7.4 Phase 3: Composer Entries

**Test 15: Pair pattern + ComponentTerm.source(left/right)**
```swift
let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
addComponent(family, pattern: "person", role: "family")
addComponent(given, pattern: "person", role: "given")

let pattern = makePattern(
    name: "person",
    sourceTemplates: ["{L}{R}"],
    targetTemplates: ["{L} {R}"],
    leftRole: "family",
    rightRole: "given"
)
let segment = makeSegment(text: "홍길동은 위인이다.")
let matchedSources = ["hong": Set(["홍"]), "gildong": Set(["길동"])]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [family, given],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true }; return false }
#expect(composer?.source == "홍길동")
#expect(composer?.componentTerms.map(\.source) == ["홍", "길동"])
```

**Test 16: Left-only pattern (실제 접미사 패턴)**
```swift
let taro = makeTerm(
    key: "taro",
    target: "타로",
    variants: ["태랑", "태로"],
    sources: [makeSource("太郎", prohibitStandalone: false)]
)
addComponent(taro, pattern: "suffix", role: nil)

let pattern = makePattern(
    name: "suffix",
    sourceTemplates: ["{L}さん"],
    targetTemplates: ["{L}씨"],
    leftRole: nil,
    rightRole: nil
)
let segment = makeSegment(text: "太郎さん登場!")
let matchedSources = ["taro": Set(["太郎"])]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [taro],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true }; return false }
#expect(composer?.source == "太郎さん")
#expect(composer?.target == "타로씨")
#expect(composer?.variants == ["태랑씨", "태로씨"])
#expect(composer?.componentTerms.count == 1)
#expect(composer?.componentTerms[0].source == "太郎")
#expect(composer?.componentTerms[0].key == "taro")
if case .composer(_, let leftKey, let rightKey, _) = composer?.origin {
    #expect(leftKey == "taro")
    #expect(rightKey == nil)
}
```

**Test 17: skipPairsIfSameTerm=true**
```swift
let term1 = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
addComponent(term1, pattern: "person", role: "family")
addComponent(term1, pattern: "person", role: "given")

let pattern = makePattern(
    name: "person",
    skipPairsIfSameTerm: true,
    leftRole: "family",
    rightRole: "given"
)
let segment = makeSegment(text: "홍홍은 누구?")
let matchedSources = ["hong": Set(["홍"])]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.allSatisfy {
    if case .composer(_, let lKey, let rKey, _) = $0.origin { return lKey != rKey }
    return true
})
```

**Test 18: 그룹 매칭**
```swift
let l1 = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
let l2 = makeTerm(key: "kim", sources: [makeSource("김", prohibitStandalone: false)])
let r1 = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
let r2 = makeTerm(key: "철수", sources: [makeSource("철수", prohibitStandalone: false)])

let groupA = makeGroup(pattern: "person", name: "A")
[l1, l2].forEach { addComponent($0, pattern: "person", role: "family", groups: [groupA]) }
[r1, r2].forEach { addComponent($0, pattern: "person", role: "given", groups: [groupA]) }

let segment = makeSegment(text: "홍길동김철수.")
let matchedSources = [
    "hong": Set(["홍"]),
    "kim": Set(["김"]),
    "gildong": Set(["길동"]),
    "철수": Set(["철수"])
]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [l1, l2, r1, r2],
    patterns: [makePersonPattern()],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let composerEntries = result.glossaryEntries.filter { if case .composer = $0.origin { return true }; return false }
#expect(composerEntries.count == 4)
```

**Test 19: Composer보다 standalone 우선**
```swift
let fullName = makeTerm(key: "hong-gildong", sources: [makeSource("홍길동", prohibitStandalone: false)])
let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
[family, given].forEach { addComponent($0, pattern: "person", role: $0.key == "hong" ? "family" : "given") }

let pattern = makePattern(name: "person", sourceTemplates: ["{L}{R}"])
let matchedSources = [
    "hong-gildong": Set(["홍길동"]),
    "hong": Set(["홍"]),
    "gildong": Set(["길동"])
]
let segment = makeSegment(text: "홍길동은 위인.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [fullName, family, given],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let entry = result.glossaryEntries.first { $0.source == "홍길동" }
#expect(entry?.origin == .termStandalone(termKey: "hong-gildong"))
```

**Test 20: Composer 생성 시 deactivated source 필터**
```swift
let family = makeTerm(
    key: "hong",
    sources: [makeSource("홍", prohibitStandalone: false), makeSource("洪", prohibitStandalone: false)],
    deactivatedIn: ["宇宙"]
)
let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
addComponent(family, pattern: "person", role: "family")
addComponent(given, pattern: "person", role: "given")

let segment = makeSegment(text: "宇宙洪길동.")
let matchedSources = [
    "hong": Set(["홍", "洪"]),
    "gildong": Set(["길동"])
]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [family, given],
    patterns: [makePersonPattern()],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.allSatisfy { $0.source != "洪길동" })
```

##### 7.5 Phase 4: Longest-First Segmentation

**Test 21: 더 긴 source 우선 분할**
```swift
let fullName = makeTerm(key: "ultraman-taro", sources: [makeSource("ウルトラマン太郎", prohibitStandalone: false)])
let ultraman = makeTerm(key: "ultraman", sources: [makeSource("ウルトラマン", prohibitStandalone: false)])
let taro = makeTerm(key: "taro", sources: [makeSource("太郎", prohibitStandalone: false)])
let matchedSources = [
    "ultraman-taro": Set(["ウルトラマン太郎"]),
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [fullName, ultraman, taro],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let termPieces = result.pieces.compactMap { if case .term(let entry, _) = $0 { return entry } else { return nil } }
#expect(termPieces.count == 1)
#expect(termPieces.first?.source == "ウルトラマン太郎")
```

**Test 22: 동일 길이 source의 비결정적 순서**
```swift
let term1 = makeTerm(key: "key1", sources: [makeSource("AAA", prohibitStandalone: false)])
let term2 = makeTerm(key: "key2", sources: [makeSource("AAA", prohibitStandalone: false)])
let matchedSources = ["key1": Set(["AAA"]), "key2": Set(["AAA"])]
let segment = makeSegment(text: "AAA登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let termPieces = result.pieces.compactMap { if case .term(let entry, _) = $0 { return entry } else { return nil } }
#expect(termPieces.count == 1)
#expect(termPieces.first?.source == "AAA")
```

**Test 23: range 계산**
```swift
let term = makeTerm(key: "ultraman-taro", sources: [makeSource("ウルトラマン太郎", prohibitStandalone: false)])
let matchedSources = ["ultraman-taro": Set(["ウルトラマン太郎"])]
let segment = makeSegment(text: "前置詞ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let termPiece = result.pieces.first { if case .term = $0 { return true } else { return false } }
if case .term(_, let range) = termPiece {
    let extracted = String(segment.originalText[range])
    #expect(extracted == "ウルトラマン太郎")
    #expect(segment.originalText.distance(from: segment.originalText.startIndex, to: range.lowerBound) == 3)
}
```

**Test 24: 동일 source 다회 등장**
```swift
let term = makeTerm(key: "taro", sources: [makeSource("太郎", prohibitStandalone: false)])
let matchedSources = ["taro": Set(["太郎"])]
let segment = makeSegment(text: "太郎和太郎是兄弟.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let termPieces = result.pieces.filter { if case .term = $0 { return true }; return false }
#expect(termPieces.count == 2)
```

#### 8. 통합 테스트 (0.5일)

**Test 25: Phase 0-4 종합 시나리오**
```swift
let term1 = makeTerm(key: "ultraman", sources: [makeSource("ウルトラマン", prohibitStandalone: false)], deactivatedIn: ["宇宙人"])
let term2 = makeTerm(key: "taro", sources: [makeSource("太郎", prohibitStandalone: true)], activators: [term1])
addComponent(term1, pattern: "person", role: "family")
addComponent(term2, pattern: "person", role: "given")

let pattern = makePattern(
    name: "person",
    sourceTemplates: ["{L}{R}"],
    targetTemplates: ["{L} {R}"],
    leftRole: "family",
    rightRole: "given"
)
let matchedSources = [
    "ultraman": Set(["ウルトラマン"]),
    "taro": Set(["太郎"])
]
let segment = makeSegment(text: "ウルトラマン太郎登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true }; return false }
#expect(result.glossaryEntries.count == 3)  // ultraman standalone, taro standalone, composer
#expect(composer?.source == "ウルトラマン太郎")
#expect(composer?.componentTerms.map(\.source) == ["ウルトラマン", "太郎"])
let termPieces = result.pieces.filter { if case .term = $0 { return true }; return false }
#expect(termPieces.count == 1)  // longest-first로 composer만 사용됨
```

**Test 26: Deduplicator 통합**
```swift
let term1 = makeTerm(
    key: "key1",
    target: "TARGET",
    sources: [
        makeSource("AAA", prohibitStandalone: false),
        makeSource("AAA", prohibitStandalone: false)
    ]
)
let matchedSources = ["key1": Set(["AAA"])]
let segment = makeSegment(text: "AAA登場!")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)
let deduplicated = Deduplicator.deduplicate(result.glossaryEntries)

#expect(result.glossaryEntries.count == 1)
#expect(deduplicated.count == 1)
```

**Test 27: DefaultTranslationRouter.prepareMaskingContext**
```swift
let segment = makeSegment(text: "ウルトラマン太郎登場!")
let matchedTerms = [term1, term2]
let patterns = [pattern]
let matchedSources = ["ultraman": Set(["ウルトラマン"]), "taro": Set(["太郎"])]

let context = await router.prepareMaskingContext(
    for: [segment],
    matchedTerms: matchedTerms,
    patterns: patterns
)

#expect(context.segmentPieces.count == 1)
#expect(context.segmentPieces.first?.pieces.contains { if case .term = $0 { return true }; return false })
#expect(context.glossaryEntries.isEmpty == false)
```

#### 9. Edge Case 및 Import 테스트 (0.5일)

**Test 28: 빈 세그먼트**
```swift
let segment = makeSegment(text: "")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [],
    patterns: [],
    matchedSources: [:],
    termActivationFilter: TermActivationFilter()
)

#expect(result.pieces.count == 1)
if case .text(let str, _) = result.pieces.first { #expect(str.isEmpty) }
#expect(result.glossaryEntries.isEmpty)
```

**Test 29: matchedTerms 빈 배열**
```swift
let segment = makeSegment(text: "ウルトラマン太郎")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [],
    patterns: [],
    matchedSources: [:],
    termActivationFilter: TermActivationFilter()
)

#expect(result.pieces.count == 1)
if case .text(let str, _) = result.pieces.first { #expect(str == "ウルトラマン太郎") }
#expect(result.glossaryEntries.isEmpty)
```

**Test 30: 모든 term이 deactivatedIn으로 필터링**
```swift
let term1 = makeTerm(key: "t1", sources: [makeSource("A", prohibitStandalone: false)], deactivatedIn: ["CTX"])
let term2 = makeTerm(key: "t2", sources: [makeSource("B", prohibitStandalone: false)], deactivatedIn: ["CTX"])
let matchedSources = ["t1": Set(["A"]), "t2": Set(["B"])]
let segment = makeSegment(text: "CTXAB")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term1, term2],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

#expect(result.glossaryEntries.isEmpty)
#expect(result.pieces.count == 1)
```

**Test 31: Glossary.Util.renderSources 튜플(left/right/composed)**
```swift
let family = makeTerm(key: "hong", sources: [makeSource("홍", prohibitStandalone: false)])
let given = makeTerm(key: "gildong", sources: [makeSource("길동", prohibitStandalone: false)])
addComponent(family, pattern: "person", role: "family")
addComponent(given, pattern: "person", role: "given")
let pattern = makePersonPattern()
let segment = makeSegment(text: "홍길동")
let matchedSources = ["hong": Set(["홍"]), "gildong": Set(["길동"])]

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [family, given],
    patterns: [pattern],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let composer = result.glossaryEntries.first { if case .composer = $0.origin { return true }; return false }
let sources = composer?.componentTerms.map(\.source)
#expect(sources == ["홍", "길동"])
```

**Test 32: Sheets/JSON Import - deactivated_in 파싱**
```swift
#expect(parseSheetRow("deactivated_in=宇宙人").terms.first?.deactivatedIn == ["宇宙人"])
#expect(parseJSONRow(#"{\"deactivated_in\":\"宇宙人;外星人\"}"#).deactivatedIn == ["宇宙人", "外星人"])
```

**Test 33: 특수문자/이모지 세그먼트**
```swift
let term = makeTerm(key: "smile", sources: [makeSource("😊", prohibitStandalone: false)])
let matchedSources = ["smile": Set(["😊"])]
let segment = makeSegment(text: "今日は😊いい天気です.")

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

let termPiece = result.pieces.first { if case .term(let entry, _) = $0 { return entry.source == "😊" } else { return false } }
#expect(termPiece != nil)
```

**Test 34: Unicode normalization (현행 동작 기록)**
```swift
let term = makeTerm(key: "ga", sources: [makeSource("が", prohibitStandalone: false)])
let matchedSources = ["ga": Set(["が"])]
let segment = makeSegment(text: "が登場")  // NFD

let result = masker.buildSegmentPieces(
    segment: segment,
    matchedTerms: [term],
    patterns: [],
    matchedSources: matchedSources,
    termActivationFilter: TermActivationFilter()
)

// Swift 기본 비교에 따름(NFD/NFC 매칭 기대). 실패 시 원인 분석 필요.
```

### Phase 4: 레거시 코드 정리 (1일)

**완전 제거:**

1. **GlossaryComposer.swift 전체 파일**
   - 위치: `MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift`
   - 이유: `buildEntriesForSegment`, `buildEntries` 로직이 TermMasker로 통합됨
   - 일부 헬퍼 메서드(matchedPairs, buildEntriesFromPairs 등)는 TermMasker로 이동

2. **TermMasker 보조 메서드 3개**
   - `collectUsedTermKeys`: 더 이상 필요 없음 (buildSegmentPieces에서 직접 반환)
   - `collectActivatedTermKeys`: GlossaryEntry.activatorKeys 제거로 불필요
   - `promoteActivatedEntries`: Term-to-Term Activation이 Phase 2로 통합

3. **promoteProhibitedEntries 메서드**
   - 위치: `MyTranslation/Services/Translation/Masking/Masker.swift`
   - 이유: Pattern Proximity Activation 제거
   - 관련 테스트 2개도 함께 제거

4. **makeNameGlossaries 메서드**
   - 위치: TermMasker
   - 이유: `makeNameGlossariesFromPieces`로 대체됨

5. **DefaultTranslationRouter 의존성 및 메서드**
   - `glossaryComposer: GlossaryComposer` 의존성 제거
   - `buildEntriesForSegment` 메서드 제거

**필드 제거:**

6. **GlossaryEntry 필드**
   - `activatorKeys: Set<String>` - Phase 2에서 SDTerm.activators 직접 사용
   - `activatesKeys: Set<String>` - 아무도 읽지 않음 (Entry는 최종 결과물)
   - `deactivatedIn: Set<String>` - Phase 0 필터링으로 불필요
   - `prohibitStandalone` - 항상 false, 사용하지 않음

7. **ComponentTerm 필드**
   - `sources: [Source]` - 사용하지 않음
   - `matchedSources: Set<String>` - 사용하지 않음
   - `preMask: Bool` - 사용하지 않음
   - `isAppellation: Bool` - 사용하지 않음
   - `activatorKeys: Set<String>` - 사용하지 않음
   - `activatesKeys: Set<String>` - 사용하지 않음

**수정:**

8. **DefaultTranslationRouter.prepareMaskingContext**
   - TermMasker.buildSegmentPieces에 원시 데이터 직접 전달
   - GlossaryComposer 호출 제거

**유지 (제거하지 않음):**

- **GlossaryEntry.componentTerms**: Composer 구성 Term 정보, UI/디버깅 필수
- **NameGlossary 타입**: 번역 엔진 인터페이스

**총 소요 시간: 7일**

---

**END OF SPEC**
