# 기능 스펙: Term 문맥 기반 비활성화 (Context Deactivation)

## 1. 기능 개요

### 1.1 목적
일반적으로 사용 가능한 Term(`prohibitStandalone=false`)이 특정 문맥(prefix/suffix 조합)에서 등장할 때 조건부로 비활성화되어 **번역 용어 매칭에서 제외**되도록 하는 기능.

### 1.2 배경
기존 `activated_by` 시스템은 "기본적으로 사용 안 되는 용어를 조건부로 활성화"하는 방향이었습니다. 하지만 반대 방향의 요구사항도 존재합니다:

- **기존 방향**: `prohibitStandalone=true` → activator 등장 시 → 활성화
- **새 방향**: `prohibitStandalone=false` → 특정 문맥 등장 시 → 비활성화

### 1.3 적용 범위
- **SegmentPieces 생성 시 적용**
  - `TermMasker.buildSegmentPieces`에서 deactivation 필터링
  - 마스킹 방식(preMask=true)과 정규화 방식(isAppellation=true) 모두에 적용
- **세그먼트 단위 판단**
  - 각 세그먼트마다 독립적으로 deactivation 조건 체크
  - 동일한 용어라도 세그먼트 문맥에 따라 다르게 동작

### 1.4 사용 사례

#### 사례 1: 부분 단어 회피

**Segment:** "宇宙人は地球人だ"

**Term 설정:**
```
key: sorato
target: 소라토
sources: [{ text: "宙人", deactivatingPrefixes: ["宇"] }]
prohibitStandalone: false
```

**현재 동작:**
- "宙人" 매칭됨 → "宇宙人"의 일부인데도 번역 시도
- 결과: "宇소라토는 지구인이다" (오역)

**변경 후:**
- "宙人" 매칭됨
- 앞에 "宇" 존재 → deactivation 조건 충족
- 이 entry 제외
- 결과: "우주인은 지구인이다" (정상)

#### 사례 2: 복합어 회피

**Segment:** "光波が来た"

**Term 설정:**
```
key: hikaru
target: 히카루
sources: [{ text: "光", deactivatingSuffixes: ["波", "線"] }]
prohibitStandalone: false
```

**동작:**
- "光" 매칭됨
- 뒤에 "波" 존재 → deactivation 조건 충족
- 이 entry 제외
- 결과: "광파가 왔다" (정상)

**비교 세그먼트:** "光が来た"
- "光" 매칭됨
- 뒤에 아무것도 없음 → deactivation 조건 불충족
- 이 entry 포함
- 결과: "히카루가 왔다" (정상)

---

## 2. 데이터 모델 변경

### 2.1 SDSource 모델 확장

```swift
@Model
public final class SDSource {
    var text: String
    var prohibitStandalone: Bool
    @Relationship var term: SDTerm

    // 신규: 문맥 기반 비활성화 조건
    var deactivatingPrefixes: [String] = []  // 이 prefix가 앞에 붙으면 비활성화
    var deactivatingSuffixes: [String] = []  // 이 suffix가 뒤에 붙으면 비활성화

    init(
        text: String,
        prohibitStandalone: Bool,
        term: SDTerm,
        deactivatingPrefixes: [String] = [],
        deactivatingSuffixes: [String] = []
    ) {
        self.text = text
        self.prohibitStandalone = prohibitStandalone
        self.term = term
        self.deactivatingPrefixes = deactivatingPrefixes
        self.deactivatingSuffixes = deactivatingSuffixes
    }
}
```

### 2.2 GlossaryEntry 확장

```swift
public struct GlossaryEntry: Sendable, Hashable {
    public var source: String
    public var target: String
    public var variants: Set<String>
    public var preMask: Bool
    public var isAppellation: Bool
    public var prohibitStandalone: Bool
    public var origin: Origin
    public var componentTerms: [ComponentTerm] = []
    public var activatorKeys: Set<String> = []
    public var activatesKeys: Set<String> = []

    // 신규: 문맥 기반 비활성화 조건
    public var deactivatingPrefixes: Set<String> = []
    public var deactivatingSuffixes: Set<String> = []

    public init(
        source: String,
        target: String,
        variants: Set<String>,
        preMask: Bool,
        isAppellation: Bool,
        prohibitStandalone: Bool,
        origin: Origin,
        componentTerms: [ComponentTerm] = [],
        activatorKeys: Set<String> = [],
        activatesKeys: Set<String> = [],
        deactivatingPrefixes: Set<String> = [],
        deactivatingSuffixes: Set<String> = []
    ) {
        self.source = source
        self.target = target
        self.variants = variants
        self.preMask = preMask
        self.isAppellation = isAppellation
        self.prohibitStandalone = prohibitStandalone
        self.origin = origin
        self.componentTerms = componentTerms
        self.activatorKeys = activatorKeys
        self.activatesKeys = activatesKeys
        self.deactivatingPrefixes = deactivatingPrefixes
        self.deactivatingSuffixes = deactivatingSuffixes
    }
}
```

### 2.3 ComponentTerm 확장

```swift
public struct ComponentTerm: Sendable, Hashable {
    public struct Source: Sendable, Hashable {
        public let text: String
        public let prohibitStandalone: Bool
        public let deactivatingPrefixes: [String]  // 신규
        public let deactivatingSuffixes: [String]  // 신규

        public init(
            text: String,
            prohibitStandalone: Bool,
            deactivatingPrefixes: [String] = [],
            deactivatingSuffixes: [String] = []
        ) {
            self.text = text
            self.prohibitStandalone = prohibitStandalone
            self.deactivatingPrefixes = deactivatingPrefixes
            self.deactivatingSuffixes = deactivatingSuffixes
        }
    }

    public let key: String
    public let target: String
    public let variants: Set<String>
    public let sources: [Source]
    public let matchedSources: Set<String>
    public let preMask: Bool
    public let isAppellation: Bool
    public let activatorKeys: Set<String>
    public let activatesKeys: Set<String>
}
```

---

## 3. Google Sheets Import 지원

### 3.1 Google Sheets 포맷

**권장 방식: 별도 컬럼 추가**

| key | target | sources | deactivating_prefixes | deactivating_suffixes |
|-----|--------|---------|----------------------|----------------------|
| sorato | 소라토 | 宙人 | 宇 | |
| hikaru | 히카루 | 光 | 小,大 | 波,線 |
| ginga | 긴가 | 银河 | | |

**컬럼 형식:**
- **deactivating_prefixes**: 쉼표(`,`) 또는 세미콜론(`;`)으로 구분
- **deactivating_suffixes**: 쉼표(`,`) 또는 세미콜론(`;`)으로 구분
- **빈 값**: 비활성화 조건 없음
- **공백**: 자동 trim 처리

**예시:**
```
deactivating_prefixes: "宇"           → ["宇"]
deactivating_prefixes: "小, 大"      → ["小", "大"]
deactivating_prefixes: ""            → []
deactivating_suffixes: "波;線;点"    → ["波", "線", "点"]
```

### 3.2 파싱 로직

**Glossary.Sheet 확장:**

```swift
extension Glossary.Sheet {
    struct ParsedSource {
        let text: String
        let prohibitStandalone: Bool
        let deactivatingPrefixes: [String]  // 신규
        let deactivatingSuffixes: [String]  // 신규
    }

    struct ParsedTerm {
        let key: String
        let target: String
        let variants: [String]
        let sources: [ParsedSource]
        let isAppellation: Bool
        let preMask: Bool
        let activatedByKeys: [String]
        // deactivation은 source별로 관리되므로 여기에는 추가 안 함
    }

    static func parseTermRow(_ row: [String], headers: [String]) -> ParsedTerm? {
        // ... 기존 파싱 로직 (key, target, variants 등)

        // sources 파싱 (기존)
        let sourcesStr = getColumnValue(row, headers, "sources")
        let sourceParts = sourcesStr.split(separator: "|").map { String($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        // deactivating_prefixes 파싱 (신규)
        let deactivatingPrefixesStr = getColumnValue(row, headers, "deactivating_prefixes")
        let deactivatingPrefixes = parseDelimitedList(deactivatingPrefixesStr)

        // deactivating_suffixes 파싱 (신규)
        let deactivatingSuffixesStr = getColumnValue(row, headers, "deactivating_suffixes")
        let deactivatingSuffixes = parseDelimitedList(deactivatingSuffixesStr)

        // ParsedSource 배열 생성
        var parsedSources: [ParsedSource] = []
        for sourcePart in sourceParts {
            let (sourceText, prohibit) = parseSourceWithProhibit(sourcePart)
            parsedSources.append(
                ParsedSource(
                    text: sourceText,
                    prohibitStandalone: prohibit,
                    deactivatingPrefixes: deactivatingPrefixes,
                    deactivatingSuffixes: deactivatingSuffixes
                )
            )
        }

        return ParsedTerm(
            key: key,
            target: target,
            variants: variants,
            sources: parsedSources,
            isAppellation: isAppellation,
            preMask: preMask,
            activatedByKeys: activatedByKeys
        )
    }

    /// 쉼표/세미콜론 구분 리스트 파싱
    private static func parseDelimitedList(_ str: String) -> [String] {
        guard !str.isEmpty else { return [] }

        let separator = str.contains(",") ? "," : ";"
        return str.split(separator: Character(separator))
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
}
```

### 3.3 Upsert 로직

**GlossarySDUpserter 수정:**

```swift
extension Glossary.SDUpserter {
    func upsertTermsFromSheet(_ parsedTerms: [Glossary.Sheet.ParsedTerm], context: ModelContext) async throws {
        // Phase 1: Term 생성/업데이트
        var termsByKey: [String: SDTerm] = [:]

        for parsed in parsedTerms {
            let term: SDTerm

            if let existing = try? context.fetch(
                FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == parsed.key })
            ).first {
                term = existing
            } else {
                term = SDTerm(key: parsed.key)
                context.insert(term)
            }

            term.target = parsed.target
            term.variants = parsed.variants
            term.isAppellation = parsed.isAppellation
            term.preMask = parsed.preMask

            // Sources 업데이트 (deactivation 정보 포함)
            term.sources.removeAll()
            for parsedSource in parsed.sources {
                let source = SDSource(
                    text: parsedSource.text,
                    prohibitStandalone: parsedSource.prohibitStandalone,
                    term: term,
                    deactivatingPrefixes: parsedSource.deactivatingPrefixes,  // 신규
                    deactivatingSuffixes: parsedSource.deactivatingSuffixes   // 신규
                )
                context.insert(source)
                term.sources.append(source)
            }

            termsByKey[parsed.key] = term
        }

        // Phase 2: activator 관계 설정 (기존 로직)
        for parsed in parsedTerms {
            guard let term = termsByKey[parsed.key] else { continue }

            term.activators.removeAll()

            for activatorKey in parsed.activatedByKeys {
                if activatorKey == parsed.key {
                    print("[Warning] Self-reference ignored for term '\(parsed.key)'")
                    continue
                }

                if let activatorTerm = termsByKey[activatorKey] {
                    term.activators.append(activatorTerm)
                } else if let existingActivator = try? context.fetch(
                    FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == activatorKey })
                ).first {
                    term.activators.append(existingActivator)
                } else {
                    print("[Warning] Activator term '\(activatorKey)' not found for term '\(parsed.key)'")
                }
            }
        }

        try context.save()
    }
}
```

### 3.4 Validation 규칙

**검증 항목:**

1. **빈 prefix/suffix 제거**
   - 파싱 시 자동으로 빈 문자열 필터링

2. **중복 제거**
   - 동일한 prefix/suffix가 여러 번 나열된 경우 중복 제거

3. **Source보다 긴 prefix/suffix 경고**
   - 예: source="光", prefix="宇宙" → 경고 (절대 매칭 안 됨)

4. **특수문자 처리**
   - prefix/suffix에 공백, 개행 등이 포함되면 경고

**Validation 코드:**

```swift
extension Glossary.Sheet {
    static func validateDeactivationRules(
        _ parsedTerms: [ParsedTerm]
    ) -> [String] {
        var warnings: [String] = []

        for term in parsedTerms {
            for source in term.sources {
                // prefix가 source보다 길면 경고
                for prefix in source.deactivatingPrefixes {
                    if prefix.count >= source.text.count {
                        warnings.append(
                            "[Term: \(term.key)] deactivating_prefix '\(prefix)' is longer than or equal to source '\(source.text)'"
                        )
                    }
                }

                // suffix가 source보다 길면 경고
                for suffix in source.deactivatingSuffixes {
                    if suffix.count >= source.text.count {
                        warnings.append(
                            "[Term: \(term.key)] deactivating_suffix '\(suffix)' is longer than or equal to source '\(source.text)'"
                        )
                    }
                }

                // 공백 포함 경고
                for prefix in source.deactivatingPrefixes where prefix.contains(" ") {
                    warnings.append(
                        "[Term: \(term.key)] deactivating_prefix '\(prefix)' contains whitespace"
                    )
                }

                for suffix in source.deactivatingSuffixes where suffix.contains(" ") {
                    warnings.append(
                        "[Term: \(term.key)] deactivating_suffix '\(suffix)' contains whitespace"
                    )
                }
            }
        }

        return warnings
    }
}
```

### 3.5 UI 피드백

**SheetsImportPreviewView에 deactivation 정보 표시:**

```swift
struct TermRowPreview: View {
    let parsed: Glossary.Sheet.ParsedTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parsed.target)
                    .font(.headline)
                Spacer()
                Text(parsed.key)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Sources 표시
            ForEach(parsed.sources, id: \.text) { source in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("원문:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(source.text)
                            .font(.caption)

                        if source.prohibitStandalone {
                            Text("(단독 금지)")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    // Deactivation 조건 표시 (신규)
                    if !source.deactivatingPrefixes.isEmpty || !source.deactivatingSuffixes.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text("비활성화:")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            if !source.deactivatingPrefixes.isEmpty {
                                Text("앞[\(source.deactivatingPrefixes.joined(separator: ", "))]")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            if !source.deactivatingSuffixes.isEmpty {
                                Text("뒤[\(source.deactivatingSuffixes.joined(separator: ", "))]")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }

            // Activator 표시 (기존)
            if !parsed.activatedByKeys.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("활성화 조건:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(parsed.activatedByKeys.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

---

## 4. GlossaryComposer 변경

### 4.1 buildStandaloneEntries 수정

```swift
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
            guard targetText.contains(source.text) else { continue }

            entries.append(
                GlossaryEntry(
                    source: source.text,
                    target: term.target,
                    variants: Set(term.variants),
                    preMask: term.preMask,
                    isAppellation: term.isAppellation,
                    prohibitStandalone: source.prohibitStandalone,
                    origin: .termStandalone(termKey: term.key),
                    componentTerms: [
                        GlossaryEntry.ComponentTerm.make(
                            from: term,
                            matchedSources: matchedSourcesForTerm
                        )
                    ],
                    activatorKeys: activatorKeys,
                    activatesKeys: activatesKeys,
                    deactivatingPrefixes: Set(source.deactivatingPrefixes),  // 신규
                    deactivatingSuffixes: Set(source.deactivatingSuffixes)   // 신규
                )
            )
        }
    }

    return entries
}
```

### 4.2 ComponentTerm.make 수정

```swift
extension GlossaryEntry.ComponentTerm {
    static func make(
        from term: Glossary.SDModel.SDTerm,
        matchedSources: Set<String>
    ) -> GlossaryEntry.ComponentTerm {
        let sources = term.sources.map { sdSource in
            GlossaryEntry.ComponentTerm.Source(
                text: sdSource.text,
                prohibitStandalone: sdSource.prohibitStandalone,
                deactivatingPrefixes: sdSource.deactivatingPrefixes,  // 신규
                deactivatingSuffixes: sdSource.deactivatingSuffixes   // 신규
            )
        }

        return GlossaryEntry.ComponentTerm(
            key: term.key,
            target: term.target,
            variants: Set(term.variants),
            sources: sources,
            matchedSources: matchedSources,
            preMask: term.preMask,
            isAppellation: term.isAppellation,
            activatorKeys: Set(term.activators.map { $0.key }),
            activatesKeys: Set(term.activates.map { $0.key })
        )
    }
}
```

### 4.3 Composed Entries

**Composed entries (패턴 기반)는 deactivation 조건을 상속하지 않음:**
- Composer는 항상 `prohibitStandalone=false`
- Deactivation은 단독 source에만 적용되는 규칙
- Composed entry는 이미 "조합"이므로 문맥이 다름

따라서 `buildEntriesFromPairs`, `buildEntriesFromLefts`는 수정 불필요.

---

## 5. TermMasker 변경

### 5.1 buildSegmentPieces 수정

```swift
func buildSegmentPieces(
    segment: Segment,
    glossary allEntries: [GlossaryEntry]
) -> (pieces: SegmentPieces, activatedEntries: [GlossaryEntry]) {
    let text = segment.originalText
    guard !text.isEmpty, !allEntries.isEmpty else {
        return (
            pieces: SegmentPieces(
                segmentID: segment.id,
                originalText: text,
                pieces: [.text(text, range: text.startIndex..<text.endIndex)]
            ),
            activatedEntries: []
        )
    }

    // 1) 기본 활성화 (단독 허용)
    let standaloneEntries = allEntries.filter { !$0.prohibitStandalone }

    // 2) Pattern 기반 활성화
    let patternPromoted = promoteProhibitedEntries(in: text, entries: allEntries)

    // 3) Term-to-Term 활성화
    let termPromoted = promoteActivatedEntries(
        from: allEntries,
        standaloneEntries: standaloneEntries,
        original: text
    )

    // 4) 활성화 엔트리 합치기 (source 기준 중복 제거)
    var combined = standaloneEntries
    combined.append(contentsOf: patternPromoted)
    combined.append(contentsOf: termPromoted)

    var seenSource: Set<String> = []
    var allowedEntries: [GlossaryEntry] = []
    for entry in combined {
        if seenSource.insert(entry.source).inserted {
            allowedEntries.append(entry)
        }
    }

    // 5) 문맥 기반 비활성화 필터링 (신규)
    let contextFiltered = filterByContextDeactivation(
        entries: allowedEntries,
        in: text
    )

    // 6) 긴 용어가 덮는 짧은 용어 제외
    let finalEntries = filterBySourceOcc(segment, contextFiltered)

    // 7) Longest-first 분할
    let sorted = finalEntries.sorted { $0.source.count > $1.source.count }
    var pieces: [SegmentPieces.Piece] = [.text(text, range: text.startIndex..<text.endIndex)]

    for entry in sorted {
        guard !entry.source.isEmpty else { continue }
        var newPieces: [SegmentPieces.Piece] = []

        for piece in pieces {
            switch piece {
            case .text(let str, let pieceRange):
                guard str.contains(entry.source) else {
                    newPieces.append(.text(str, range: pieceRange))
                    continue
                }

                var searchStart = str.startIndex
                while let foundRange = str.range(of: entry.source, range: searchStart..<str.endIndex) {
                    // 앞쪽 텍스트 조각 보존
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

                    // 용어 range 기록
                    let originalLower = text.index(
                        pieceRange.lowerBound,
                        offsetBy: str.distance(from: str.startIndex, to: foundRange.lowerBound)
                    )
                    let originalUpper = text.index(originalLower, offsetBy: entry.source.count)
                    newPieces.append(.term(entry, range: originalLower..<originalUpper))

                    searchStart = foundRange.upperBound
                }

                // 남은 텍스트 조각 추가
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

    return (
        pieces: SegmentPieces(
            segmentID: segment.id,
            originalText: text,
            pieces: pieces
        ),
        activatedEntries: finalEntries
    )
}
```

### 5.2 filterByContextDeactivation 구현 (신규)

```swift
/// 문맥 기반 deactivation 필터링
/// - Parameters:
///   - entries: 활성화된 GlossaryEntry 배열
///   - text: 세그먼트 원문
/// - Returns: deactivation 조건을 통과한 Entry 배열
private func filterByContextDeactivation(
    entries: [GlossaryEntry],
    in text: String
) -> [GlossaryEntry] {
    var filtered: [GlossaryEntry] = []

    for entry in entries {
        // deactivation 규칙이 없으면 그대로 포함
        guard !entry.deactivatingPrefixes.isEmpty ||
              !entry.deactivatingSuffixes.isEmpty else {
            filtered.append(entry)
            continue
        }

        // source가 실제로 나타나는 모든 위치 확인
        let occurrences = allOccurrences(of: entry.source, in: text)
        guard !occurrences.isEmpty else {
            // 나타나지 않으면 포함 안 함 (이미 앞 단계에서 필터링되어야 하지만 방어 코드)
            continue
        }

        // 각 위치마다 deactivation 조건 체크
        var hasValidOccurrence = false
        for offset in occurrences {
            let shouldDeactivate = checkDeactivationCondition(
                source: entry.source,
                offset: offset,
                in: text,
                prefixes: entry.deactivatingPrefixes,
                suffixes: entry.deactivatingSuffixes
            )

            if !shouldDeactivate {
                // 하나라도 유효한 출현이 있으면 이 entry는 포함
                hasValidOccurrence = true
                break
            }
        }

        if hasValidOccurrence {
            filtered.append(entry)
        }
    }

    return filtered
}

/// 특정 위치에서 deactivation 조건 체크
/// - Parameters:
///   - source: Entry의 source 문자열
///   - offset: 세그먼트 내 source의 시작 오프셋 (문자 단위)
///   - text: 세그먼트 원문
///   - prefixes: 비활성화 prefix 집합
///   - suffixes: 비활성화 suffix 집합
/// - Returns: true면 비활성화해야 함, false면 활성 상태 유지
private func checkDeactivationCondition(
    source: String,
    offset: Int,
    in text: String,
    prefixes: Set<String>,
    suffixes: Set<String>
) -> Bool {
    // Prefix 체크
    if !prefixes.isEmpty {
        for prefix in prefixes {
            let prefixStart = offset - prefix.count
            if prefixStart >= 0 {
                let prefixStartIndex = text.index(text.startIndex, offsetBy: prefixStart)
                let prefixEndIndex = text.index(text.startIndex, offsetBy: offset)

                if prefixEndIndex <= text.endIndex {
                    let actualPrefix = String(text[prefixStartIndex..<prefixEndIndex])
                    if actualPrefix == prefix {
                        return true  // deactivate
                    }
                }
            }
        }
    }

    // Suffix 체크
    if !suffixes.isEmpty {
        let sourceEnd = offset + source.count
        for suffix in suffixes {
            let suffixEnd = sourceEnd + suffix.count
            if suffixEnd <= text.count {
                let suffixStartIndex = text.index(text.startIndex, offsetBy: sourceEnd)
                let suffixEndIndex = text.index(text.startIndex, offsetBy: suffixEnd)

                if suffixEndIndex <= text.endIndex {
                    let actualSuffix = String(text[suffixStartIndex..<suffixEndIndex])
                    if actualSuffix == suffix {
                        return true  // deactivate
                    }
                }
            }
        }
    }

    return false  // 조건 안 맞으면 활성 상태 유지
}
```

---

## 6. 전체 플로우

### 6.1 Import 시 (1회)

```
Google Sheets Import
  ↓
parseTermRow() → ParsedSource에 deactivatingPrefixes/Suffixes 포함
  ↓
validateDeactivationRules() → 경고 메시지 생성
  ↓
upsertTermsFromSheet() → SDSource에 deactivation 정보 저장
  ↓
[DB에 저장 완료]
```

### 6.2 페이지 로드 시 (1회)

```
GlossaryDataProvider.fetch(pageText)
  ↓
매칭된 Term/Source 목록
  ↓
GlossaryComposer.buildEntriesForSegment()
  ↓
buildStandaloneEntries() → GlossaryEntry에 deactivation 정보 포함
  ↓
[모든 matched entries (deactivation 정보 포함)]
```

### 6.3 세그먼트 번역 시 (각 세그먼트마다)

```
TranslationRouter.translateStream()
  ↓
TermMasker.buildSegmentPieces()
  ↓
1) standaloneEntries 필터링 (prohibitStandalone=false)
  ↓
2) promoteProhibitedEntries() [Pattern-based activation]
  ↓
3) promoteActivatedEntries() [Term-to-Term activation]
  ↓
4) 중복 제거
  ↓
5) filterByContextDeactivation() [신규: 문맥 기반 비활성화]
     ├─ 각 entry의 모든 출현 위치 찾기
     ├─ 각 위치마다 prefix/suffix 조건 체크
     └─ 하나라도 유효한 출현이 있으면 포함
  ↓
6) filterBySourceOcc() [긴 용어 우선]
  ↓
7) Longest-first 분할 → SegmentPieces
  ↓
번역 엔진 호출 (마스킹/정규화 적용)
  ↓
[번역 완료]
```

---

## 7. 예시 실행

### 7.1 데이터 준비

**Terms:**
```
sorato: {
  key: "sorato",
  target: "소라토",
  sources: [
    { text: "宙人", deactivatingPrefixes: ["宇"] }
  ]
}

hikaru: {
  key: "hikaru",
  target: "히카루",
  sources: [
    { text: "光", deactivatingSuffixes: ["波", "線"] }
  ]
}
```

**GlossaryEntries (buildEntriesForSegment 결과):**
```
1. source="宙人", target="소라토", prohibitStandalone=false,
   deactivatingPrefixes=["宇"],
   origin=.termStandalone("sorato")

2. source="光", target="히카루", prohibitStandalone=false,
   deactivatingSuffixes=["波", "線"],
   origin=.termStandalone("hikaru")
```

### 7.2 케이스 1: Prefix 비활성화

**세그먼트:** "宇宙人は地球人だ"

**buildSegmentPieces 실행:**

1. **standaloneEntries:**
   ```
   [Entry 1: "宙人", Entry 2: "光"]
   ```

2. **filterByContextDeactivation:**

   **Entry 1 ("宙人") 처리:**
   - 출현 위치: [1] (offset=1, "宇**宙人**は...")
   - checkDeactivationCondition(offset=1):
     - prefix "宇" 체크: offset 1 앞에 "宇" 존재 (offset 0)
     - 조건 충족 → return true (비활성화)
   - hasValidOccurrence = false
   - **Entry 1 제외**

   **Entry 2 ("光") 처리:**
   - 출현 위치: [] (세그먼트에 없음)
   - **Entry 2 제외**

3. **최종 allowedEntries:** []

4. **번역 결과:**
   - "宙人" 매칭 안 됨
   - 번역: "우주인은 지구인이다" ✓

### 7.3 케이스 2: Suffix 비활성화

**세그먼트:** "光波が来た"

**buildSegmentPieces 실행:**

1. **standaloneEntries:**
   ```
   [Entry 2: "光"]
   ```

2. **filterByContextDeactivation:**

   **Entry 2 ("光") 처리:**
   - 출현 위치: [0] (offset=0, "**光**波が...")
   - checkDeactivationCondition(offset=0):
     - suffix "波" 체크: offset 1 (sourceEnd) 뒤에 "波" 존재
     - 조건 충족 → return true (비활성화)
   - hasValidOccurrence = false
   - **Entry 2 제외**

3. **최종 allowedEntries:** []

4. **번역 결과:**
   - "光" 매칭 안 됨
   - 번역: "광파가 왔다" ✓

### 7.4 케이스 3: 조건 불충족 (정상 활성화)

**세그먼트:** "光が来た"

**buildSegmentPieces 실행:**

1. **standaloneEntries:**
   ```
   [Entry 2: "光"]
   ```

2. **filterByContextDeactivation:**

   **Entry 2 ("光") 처리:**
   - 출현 위치: [0] (offset=0, "**光**が...")
   - checkDeactivationCondition(offset=0):
     - suffix "波" 체크: offset 1 뒤에 "が" 존재 → 불일치
     - suffix "線" 체크: offset 1 뒤에 "が" 존재 → 불일치
     - 조건 불충족 → return false (활성 유지)
   - hasValidOccurrence = true
   - **Entry 2 포함**

3. **최종 allowedEntries:** [Entry 2]

4. **번역 결과:**
   - "光" → "히카루" 매칭됨
   - 번역: "히카루가 왔다" ✓

### 7.5 케이스 4: 복수 출현 (일부만 비활성화)

**세그먼트:** "光は光波を使う"

**buildSegmentPieces 실행:**

1. **standaloneEntries:**
   ```
   [Entry 2: "光"]
   ```

2. **filterByContextDeactivation:**

   **Entry 2 ("光") 처리:**
   - 출현 위치: [0, 2]
     - offset 0: "**光**は..."
     - offset 2: "は**光**波を..."

   - **첫 번째 출현 (offset=0) 체크:**
     - suffix "波" 체크: offset 1 뒤에 "は" 존재 → 불일치
     - 조건 불충족 → return false (이 위치는 유효)
     - hasValidOccurrence = true → **Entry 2 포함**

3. **최종 allowedEntries:** [Entry 2]

4. **SegmentPieces 분할:**
   - "光" 두 출현 모두 매칭됨:
     - `[.term("光"), .text("は"), .term("光"), .text("波を使う")]`

5. **번역 결과:**
   - "히카루는 히카루파를 사용한다" (?)
   - **문제:** 두 번째 "光"도 매칭되어 오역 발생

**해결 방안:**

현재 구현은 "하나라도 유효한 출현이 있으면 전체 entry를 포함"하는 방식입니다.
더 정교한 처리를 위해서는 **출현 위치별로 비활성화를 판단**해야 하지만,
이는 구현 복잡도가 크게 증가합니다.

**권장:**
- Phase 1에서는 현재 방식 유지 (간단, 대부분 케이스 커버)
- Phase 2에서 필요 시 위치별 비활성화 구현 고려

---

## 8. UI/UX 설계

### 8.1 Term 편집 화면

**TermEditorSheet 섹션 추가:**

```
┌─────────────────────────────────────┐
│ Term 편집: 소라토                    │
├─────────────────────────────────────┤
│ 번역: 소라토                         │
│ 변형: []                             │
│                                      │
│ Sources:                             │
│   - 宙人                             │
│                                      │
│ ┌─ 문맥 비활성화 ───────────────────┐│
│ │ ⚠️ 특정 문자가 앞뒤에 나타날 때   ││
│ │    이 용어를 사용하지 않습니다    ││
│ │                                   ││
│ │ 비활성화 접두사 (prefix):         ││
│ │   [宇] [×]                        ││
│ │   ┌─────────┐ [추가]             ││
│ │   │         │                     ││
│ │   └─────────┘                     ││
│ │                                   ││
│ │ 비활성화 접미사 (suffix):         ││
│ │   (없음)                          ││
│ │   ┌─────────┐ [추가]             ││
│ │   │         │                     ││
│ │   └─────────┘                     ││
│ │                                   ││
│ │ 💡 예: "宇宙人"에서 "宙人"을      ││
│ │     제외하려면 접두사에 "宇" 추가 ││
│ └───────────────────────────────────┘│
│                                      │
│ [저장] [취소]                        │
└─────────────────────────────────────┘
```

### 8.2 UI 구현

**TermEditorSheet.swift:**

```swift
struct TermEditorSheet: View {
    @State private var draft: TermDraft
    @State private var newPrefix: String = ""
    @State private var newSuffix: String = ""

    var body: some View {
        Form {
            // ... 기존 섹션들 (번역, 변형, Sources 등)

            // 신규: 문맥 비활성화 섹션
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("특정 문자가 앞뒤에 나타날 때 이 용어를 사용하지 않습니다")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Prefix 설정
                    VStack(alignment: .leading, spacing: 8) {
                        Text("비활성화 접두사 (prefix)")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if draft.deactivatingPrefixes.isEmpty {
                            Text("(없음)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            TagChips(
                                tags: draft.deactivatingPrefixes,
                                color: .red,
                                onRemove: { index in
                                    draft.deactivatingPrefixes.remove(at: index)
                                }
                            )
                        }

                        HStack {
                            TextField("예: 宇", text: $newPrefix)
                                .textFieldStyle(.roundedBorder)

                            Button("추가") {
                                let trimmed = newPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty && !draft.deactivatingPrefixes.contains(trimmed) {
                                    draft.deactivatingPrefixes.append(trimmed)
                                    newPrefix = ""
                                }
                            }
                            .disabled(newPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Divider()

                    // Suffix 설정
                    VStack(alignment: .leading, spacing: 8) {
                        Text("비활성화 접미사 (suffix)")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if draft.deactivatingSuffixes.isEmpty {
                            Text("(없음)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            TagChips(
                                tags: draft.deactivatingSuffixes,
                                color: .red,
                                onRemove: { index in
                                    draft.deactivatingSuffixes.remove(at: index)
                                }
                            )
                        }

                        HStack {
                            TextField("예: 波", text: $newSuffix)
                                .textFieldStyle(.roundedBorder)

                            Button("추가") {
                                let trimmed = newSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty && !draft.deactivatingSuffixes.contains(trimmed) {
                                    draft.deactivatingSuffixes.append(trimmed)
                                    newSuffix = ""
                                }
                            }
                            .disabled(newSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Divider()

                    // 도움말
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text("예: \"宇宙人\"에서 \"宙人\"을 제외하려면 접두사에 \"宇\"를 추가하세요")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("문맥 비활성화")
            }

            // ... 기존 섹션들 (조건부 활성화 등)
        }
        .navigationTitle("Term 편집")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    saveDraft()
                }
            }

            ToolbarItem(placement: .cancellationAction) {
                Button("취소") {
                    dismiss()
                }
            }
        }
    }
}

/// 태그 칩 컴포넌트 (재사용)
struct TagChips: View {
    let tags: [String]
    var color: Color = .blue
    let onRemove: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.2))
                        .foregroundColor(color)
                        .cornerRadius(8)

                    Button {
                        onRemove(index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(color)
                    }
                }
            }
        }
    }
}
```

### 8.3 TermDraft 확장

```swift
struct TermDraft {
    var key: String
    var target: String
    var variants: [String]
    var sources: [SourceDraft]
    var isAppellation: Bool
    var preMask: Bool
    var activators: [SDTerm]
    var activates: [SDTerm]

    // 신규: deactivation (단순화: source별이 아닌 Term 전체에 적용)
    var deactivatingPrefixes: [String] = []
    var deactivatingSuffixes: [String] = []
}

struct SourceDraft {
    var text: String
    var prohibitStandalone: Bool
}
```

**주의:** 실제로는 source별로 deactivation 조건이 다를 수 있으므로,
더 정교한 UI가 필요하면 `SourceDraft`에 deactivation 필드를 추가해야 합니다.

---

## 9. 구현 우선순위

### Phase 1: 핵심 기능 (2일)

1. **데이터 모델** (0.5일)
   - SDSource에 `deactivatingPrefixes`, `deactivatingSuffixes` 추가
   - GlossaryEntry에 deactivation 필드 추가
   - ComponentTerm.Source에 deactivation 필드 추가

2. **GlossaryComposer** (0.5일)
   - `buildStandaloneEntries`에서 deactivation 정보 포함
   - `ComponentTerm.make` 수정

3. **TermMasker** (1일)
   - `filterByContextDeactivation` 구현
   - `checkDeactivationCondition` 구현
   - `buildSegmentPieces`에 통합

**합계: 2일**

### Phase 2: Import & UI (1.5일)

4. **Google Sheets Import** (0.5일)
   - `parseTermRow`에서 deactivation 컬럼 파싱
   - `validateDeactivationRules` 구현
   - `upsertTermsFromSheet`에서 SDSource에 저장

5. **UI 구현** (0.5일)
   - TermEditorSheet에 deactivation 섹션 추가
   - TagChips 컴포넌트
   - TermDraft 확장

6. **Import Preview** (0.5일)
   - SheetsImportPreviewView에 deactivation 정보 표시

**합계: 1.5일**

### Phase 3: 테스트 & 문서 (1일)

7. **단위 테스트** (0.5일)
   - `filterByContextDeactivation` 테스트
   - `checkDeactivationCondition` 테스트
   - Import 파싱 테스트

8. **통합 테스트** (0.25일)
   - End-to-end 테스트 (세그먼트 → 번역)

9. **문서 업데이트** (0.25일)
   - `PROJECT_OVERVIEW.md` 업데이트
   - `TODO.md` 업데이트

**합계: 1일**

---

## 10. 테스트 케이스

### 10.1 단위 테스트

**Test 1: Prefix Deactivation**
```swift
func testContextDeactivation_Prefix() {
    let masker = TermMasker()
    let text = "宇宙人は地球人だ"
    let entries = [
        GlossaryEntry(
            source: "宙人",
            target: "소라토",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "sorato"),
            deactivatingPrefixes: ["宇"]
        )
    ]

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertTrue(filtered.isEmpty, "Entry should be deactivated due to prefix '宇'")
}
```

**Test 2: Suffix Deactivation**
```swift
func testContextDeactivation_Suffix() {
    let masker = TermMasker()
    let text = "光波が来た"
    let entries = [
        GlossaryEntry(
            source: "光",
            target: "히카루",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "hikaru"),
            deactivatingSuffixes: ["波", "線"]
        )
    ]

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertTrue(filtered.isEmpty, "Entry should be deactivated due to suffix '波'")
}
```

**Test 3: No Deactivation (Valid Context)**
```swift
func testContextDeactivation_NoMatch() {
    let masker = TermMasker()
    let text = "光が来た"
    let entries = [
        GlossaryEntry(
            source: "光",
            target: "히카루",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "hikaru"),
            deactivatingSuffixes: ["波", "線"]
        )
    ]

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertEqual(filtered.count, 1, "Entry should remain active")
    XCTAssertEqual(filtered.first?.source, "光")
}
```

**Test 4: Multiple Occurrences (Partial Deactivation)**
```swift
func testContextDeactivation_MultipleOccurrences() {
    let masker = TermMasker()
    let text = "光は光波を使う"
    let entries = [
        GlossaryEntry(
            source: "光",
            target: "히카루",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "hikaru"),
            deactivatingSuffixes: ["波"]
        )
    ]

    // 첫 번째 "光" (offset 0): 뒤에 "は" → 유효
    // 두 번째 "光" (offset 2): 뒤에 "波" → 비활성화
    // 하나라도 유효하면 entry 포함

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertEqual(filtered.count, 1, "Entry should remain active due to first occurrence")
}
```

**Test 5: No Deactivation Rules**
```swift
func testContextDeactivation_NoRules() {
    let masker = TermMasker()
    let text = "宇宙人は地球人だ"
    let entries = [
        GlossaryEntry(
            source: "宙人",
            target: "소라토",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "sorato")
            // deactivation 규칙 없음
        )
    ]

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertEqual(filtered.count, 1, "Entry without deactivation rules should always be included")
}
```

**Test 6: Prefix and Suffix Combined**
```swift
func testContextDeactivation_Combined() {
    let masker = TermMasker()
    let text = "大光線"
    let entries = [
        GlossaryEntry(
            source: "光",
            target: "히카루",
            variants: [],
            preMask: false,
            isAppellation: true,
            prohibitStandalone: false,
            origin: .termStandalone(termKey: "hikaru"),
            deactivatingPrefixes: ["大"],
            deactivatingSuffixes: ["線"]
        )
    ]

    // "光" 앞에 "大", 뒤에 "線" → 둘 중 하나만 맞아도 비활성화

    let filtered = masker.filterByContextDeactivation(entries: entries, in: text)

    XCTAssertTrue(filtered.isEmpty, "Entry should be deactivated due to both prefix and suffix")
}
```

### 10.2 통합 테스트

**Test 7: End-to-End with Deactivation**
```swift
func testEndToEnd_ContextDeactivation() async throws {
    // Setup
    let context = ModelContext(/* test container */)
    let composer = GlossaryComposer()
    let masker = TermMasker()

    // Insert Term with deactivation
    let term = SDTerm(key: "sorato", target: "소라토")
    let source = SDSource(
        text: "宙人",
        prohibitStandalone: false,
        term: term,
        deactivatingPrefixes: ["宇"]
    )
    term.sources.append(source)
    context.insert(term)
    try context.save()

    // Fetch and build entries
    let dataProvider = GlossaryDataProvider(context: context)
    let data = await dataProvider.fetch(text: "宇宙人は地球人だ")
    let entries = composer.buildEntriesForSegment(from: data, segmentText: "宇宙人は地球人だ")

    // Build SegmentPieces
    let segment = Segment(id: "1", originalText: "宇宙人は地球人だ")
    let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: entries)

    // Verify
    let termPieces = pieces.pieces.filter {
        if case .term = $0 { return true }
        return false
    }

    XCTAssertTrue(termPieces.isEmpty, "宙人 should be deactivated due to prefix 宇")
}
```

**Test 8: End-to-End with Valid Context**
```swift
func testEndToEnd_ValidContext() async throws {
    // Setup (동일)

    // Fetch with different segment
    let data = await dataProvider.fetch(text: "宙人が現れた")
    let entries = composer.buildEntriesForSegment(from: data, segmentText: "宙人が現れた")

    let segment = Segment(id: "2", originalText: "宙人が現れた")
    let (pieces, _) = masker.buildSegmentPieces(segment: segment, glossary: entries)

    let termPieces = pieces.pieces.filter {
        if case .term(let entry, _) = $0 {
            return entry.source == "宙人"
        }
        return false
    }

    XCTAssertEqual(termPieces.count, 1, "宙人 should be active")
}
```

### 10.3 Import 테스트

**Test 9: Google Sheets Parsing**
```swift
func testSheetsImport_DeactivationParsing() {
    // 단일 prefix
    let row1 = ["sorato", "소라토", "宙人", "宇", ""]
    let headers = ["key", "target", "sources", "deactivating_prefixes", "deactivating_suffixes"]
    let parsed1 = Glossary.Sheet.parseTermRow(row1, headers: headers)

    XCTAssertEqual(parsed1?.sources.first?.deactivatingPrefixes, ["宇"])
    XCTAssertEqual(parsed1?.sources.first?.deactivatingSuffixes, [])

    // 복수 prefix/suffix (쉼표 구분)
    let row2 = ["hikaru", "히카루", "光", "小,大", "波,線"]
    let parsed2 = Glossary.Sheet.parseTermRow(row2, headers: headers)

    XCTAssertEqual(Set(parsed2?.sources.first?.deactivatingPrefixes ?? []), Set(["小", "大"]))
    XCTAssertEqual(Set(parsed2?.sources.first?.deactivatingSuffixes ?? []), Set(["波", "線"]))

    // 빈 값
    let row3 = ["ginga", "긴가", "银河", "", ""]
    let parsed3 = Glossary.Sheet.parseTermRow(row3, headers: headers)

    XCTAssertEqual(parsed3?.sources.first?.deactivatingPrefixes, [])
    XCTAssertEqual(parsed3?.sources.first?.deactivatingSuffixes, [])
}
```

**Test 10: Validation**
```swift
func testSheetsImport_Validation() {
    let parsedTerms = [
        Glossary.Sheet.ParsedTerm(
            key: "test",
            target: "테스트",
            variants: [],
            sources: [
                Glossary.Sheet.ParsedSource(
                    text: "光",
                    prohibitStandalone: false,
                    deactivatingPrefixes: ["宇宙"],  // 너무 긴 prefix
                    deactivatingSuffixes: []
                )
            ],
            isAppellation: false,
            preMask: false,
            activatedByKeys: []
        )
    ]

    let warnings = Glossary.Sheet.validateDeactivationRules(parsedTerms)

    XCTAssertFalse(warnings.isEmpty, "Should warn about prefix longer than source")
    XCTAssertTrue(warnings.first?.contains("longer than or equal to source") ?? false)
}
```

---

## 11. 요약

### 핵심 변경사항

1. **SDSource**: `deactivatingPrefixes`, `deactivatingSuffixes` 추가
2. **GlossaryEntry**: deactivation 필드 추가
3. **GlossaryComposer**: deactivation 정보를 Entry에 포함
4. **Google Sheets**: `deactivating_prefixes`, `deactivating_suffixes` 컬럼 지원
5. **TermMasker**: `filterByContextDeactivation()` 구현
   - 각 entry의 모든 출현 위치 체크
   - prefix/suffix 조건 매칭 여부 판단
   - 하나라도 유효한 출현이 있으면 entry 포함

### 장점

✅ **직관적**: prefix/suffix 규칙으로 명확하게 정의
✅ **유연함**: 복수 prefix/suffix 지정 가능
✅ **대칭적**: `activated_by`와 반대 방향의 대칭적 기능
✅ **확장 가능**: 향후 정규식 등으로 확장 가능
✅ **안전함**: 기존 activation 로직과 독립적으로 동작

### 제약사항

⚠️ **출현 위치별 비활성화 불가**: 현재 구현은 "하나라도 유효한 출현이 있으면 전체 포함"
⚠️ **성능**: 각 entry의 모든 출현 위치를 체크해야 함 (대부분 케이스에서는 무시 가능)
⚠️ **복잡한 패턴 미지원**: 정규식 등은 Phase 2 이후 고려

### 구현 난이도 및 기간

**난이도**: 중
**예상 기간**: 4-5일 (MVP)

### 기술적 고려사항

1. **중복 처리**: activation 후 deactivation을 적용하므로 순서 중요
2. **성능 최적화**: 출현 위치 캐싱으로 개선 가능
3. **확장성**: 향후 정규식, 위치별 비활성화 등으로 확장 가능
4. **디버깅**: entry가 제외된 이유를 로깅하면 디버깅 용이

### 다음 단계

1. SDSource 모델에 deactivation 필드 추가
2. GlossaryEntry 구조체 확장
3. GlossaryComposer 수정
4. TermMasker에 `filterByContextDeactivation` 구현
5. Google Sheets import 파싱 로직
6. TermEditorSheet UI 구현
7. 테스트 작성
8. 문서 업데이트

---

**문서 버전**: 1.0
**작성일**: 2025-11-24
**상태**: 승인 대기
