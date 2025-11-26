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

7. **단위 테스트** (0.5일)
8. **통합 테스트** (0.5일)
9. **End-to-End** (0.5일)

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
  - `variants: [String]` - 사용하지 않음
   - `sources: [Source]` - 사용하지 않음
   - `matchedSources: Set<String>` - 사용하지 않음
   - `preMask: Bool` - 사용하지 않음
   - `isAppellation: Bool` - 사용하지 않음
   - `activatorKeys: Set<String>` - 사용하지 않음
   - `activatesKeys: Set<String>` - 사용하지 않음
   - `Source` 중첩 구조체 - 사용하지 않음

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
