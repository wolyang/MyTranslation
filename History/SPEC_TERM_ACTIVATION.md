# 기능 스펙: Term 간 조건부 활성화

## 1. 기능 개요

### 1.1 목적
단독 번역이 금지된 Term(`prohibitStandalone=true`)이 특정 Segment 내에서 activator Term과 함께 등장할 때 조건부로 활성화되어 **정규화(normalization)** 에 사용될 수 있도록 하는 기능.

### 1.2 적용 범위
- **정규화(variants → target) 방식에 적용**
  - `makeNameGlossaries`에서 NameGlossary 생성 시 활성화된 Term 포함
  - 번역 후 `normalizeVariantsAndParticles`에서 variants를 target으로 치환
- **마스킹 방식에는 별도 적용 가능** (향후 확장)

### 1.3 사용 사례

**Segment:** "银河和小光一起战斗"

**GlossaryEntries:**
```
1. source="银河", target="긴가", prohibitStandalone=true, activators=["hikaru"]
2. source="小光", target="히카루", origin=composer(...)
```

**현재 동작:**
- `makeNameGlossaries`에서 "银河" 제외 (prohibitStandalone=true)
- 번역 후 "긴가" variants 정규화 안 됨 → "은하"로 오역 가능

**변경 후:**
- Segment에 "小光"(히카루) 존재 확인
- "银河" entry를 activate하여 NameGlossary에 포함
- 번역 후 "긴가" variants → "긴가"로 정규화

---

## 2. 데이터 모델 변경

### 2.1 SDTerm 모델 확장

```swift
@Model
public final class SDTerm {
    // ... 기존 프로퍼티 ...

    // 신규: 조건부 활성화 관계
    @Relationship var activators: [SDTerm]    // 이 Term을 활성화하는 Term 목록
    @Relationship var activates: [SDTerm]     // 이 Term이 활성화하는 Term 목록
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

    // 신규: 활성화 관계 정보
    public var activatorKeys: Set<String> = []   // 이 Entry를 활성화하는 Term 키들
    public var activatesKeys: Set<String> = []   // 이 Entry가 활성화하는 Term 키들
}
```

**두 필드 모두 필요한 이유:**
- `activatorKeys`: 이 Entry가 prohibited일 때, 어떤 Term이 나타나면 활성화되는지 체크
- `activatesKeys`: 이 Entry가 사용될 때, 어떤 다른 Entry를 활성화해야 하는지 체크

---

## 3. Glossary.Service 변경

### 3.1 buildEntries 수정

**위치:** `Domain/Glossary/Services/` 내부

**Standalone Entry 생성 시:**

```swift
for key in matchedTermKey {
    guard let t = termByKey[key], let ms = matchedSourcesByKey[key] else { continue }

    for s in t.sources {
        guard ms.contains(s.text) else { continue }

        // 활성화 관계 정보 추출
        let activatorKeys = Set(t.activators.map { $0.key })
        let activatesKeys = Set(t.activates.map { $0.key })

        entries.append(GlossaryEntry(
            source: s.text,
            target: t.target,
            variants: Set(t.variants),
            preMask: t.preMask,
            isAppellation: t.isAppellation,
            prohibitStandalone: s.prohibitStandalone,
            origin: .termStandalone(termKey: t.key),
            activatorKeys: activatorKeys,      // 신규
            activatesKeys: activatesKeys       // 신규
        ))
    }
}
```

**Pattern Composer Entry 생성 시:**

```swift
// leftTerm과 rightTerm(있으면)의 activates를 합침
var composerActivatesKeys = Set<String>()
composerActivatesKeys.formUnion(leftTerm.activates.map { $0.key })
if let rightTerm = rightTerm {
    composerActivatesKeys.formUnion(rightTerm.activates.map { $0.key })
}

// Pattern으로 생성된 entry도 activate 정보 포함
entries.append(GlossaryEntry(
    source: renderedSource,
    target: renderedTarget,
    variants: variants,
    preMask: pat.preMask,
    isAppellation: pat.isAppellation,
    prohibitStandalone: false,  // composer는 항상 false
    origin: .composer(...),
    activatorKeys: [],          // composer는 activator 없음 (자체로 사용됨)
    activatesKeys: composerActivatesKeys  // L과 R의 activates 합집합
))
```

### 3.2 Google Sheets Import 지원

Google Sheets에서 Term을 가져올 때 `activated_by` 컬럼을 통해 activator 관계를 설정할 수 있습니다.

#### 3.2.1 Google Sheets 포맷

**컬럼 구조:**

| key | target | variants | sources | ... | **activated_by** |
|-----|--------|----------|---------|-----|------------------|
| ginga | 긴가 | 긴가様 | 银河 | ... | hikaru |
| hikaru | 히카루 | ヒカル | 光 | ... | |
| taro | 타로 | 太郎 | 太郎 | ... | ginga,hikaru |

**activated_by 컬럼 형식:**
- 비어있으면: activator 없음
- 단일 값: `"hikaru"` → 히카루 Term이 이 Term을 활성화
- 복수 값: `"ginga,hikaru"` → 긴가 또는 히카루가 이 Term을 활성화
- 구분자: 쉼표(`,`) 또는 세미콜론(`;`)
- 공백 허용: `"ginga, hikaru"` → 자동 trim

#### 3.2.2 파싱 로직

**Glossary.Sheet 확장:**

```swift
extension Glossary.Sheet {
    struct ParsedTerm {
        let key: String
        let target: String
        let variants: [String]
        let sources: [SourceData]
        // ... 기존 필드들
        let activatedByKeys: [String]  // 신규
    }

    static func parseTermRow(_ row: [String], headers: [String]) -> ParsedTerm? {
        // 기존 파싱 로직...

        // activated_by 컬럼 파싱
        let activatedByKeys: [String]
        if let activatedByIndex = headers.firstIndex(of: "activated_by"),
           activatedByIndex < row.count {
            let rawValue = row[activatedByIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.isEmpty {
                activatedByKeys = []
            } else {
                // 쉼표 또는 세미콜론으로 분리
                let separator = rawValue.contains(",") ? "," : ";"
                activatedByKeys = rawValue
                    .split(separator: Character(separator))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } else {
            activatedByKeys = []
        }

        return ParsedTerm(
            key: key,
            target: target,
            variants: variants,
            sources: sources,
            // ... 기존 필드들
            activatedByKeys: activatedByKeys
        )
    }
}
```

#### 3.2.3 Upsert 로직

**Glossary.Service의 upsertTerms 메서드 확장:**

```swift
extension Glossary.Service {
    func upsertTermsFromSheet(_ parsedTerms: [Glossary.Sheet.ParsedTerm], context: ModelContext) async throws {
        // Phase 1: Term 생성/업데이트 (기존 로직)
        var termsByKey: [String: SDTerm] = [:]

        for parsed in parsedTerms {
            let term: SDTerm

            // 기존 Term 조회 또는 생성
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
            // ... 기존 필드 업데이트

            termsByKey[parsed.key] = term
        }

        // Phase 2: activator 관계 설정 (신규)
        for parsed in parsedTerms {
            guard let term = termsByKey[parsed.key] else { continue }

            // 기존 activators 관계 초기화
            term.activators.removeAll()

            // activated_by에 명시된 Term들을 activator로 추가
            for activatorKey in parsed.activatedByKeys {
                // 같은 배치 내에서 찾기
                if let activatorTerm = termsByKey[activatorKey] {
                    term.activators.append(activatorTerm)
                }
                // 기존 DB에서 찾기
                else if let existingActivator = try? context.fetch(
                    FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == activatorKey })
                ).first {
                    term.activators.append(existingActivator)
                } else {
                    // activator Term이 존재하지 않으면 경고 로그
                    print("[Warning] Activator term '\(activatorKey)' not found for term '\(parsed.key)'")
                }
            }
        }

        try context.save()
    }
}
```

#### 3.2.4 에러 처리

**Validation 규칙:**

1. **존재하지 않는 activator 참조:**
   - 경고 로그 출력
   - 해당 activator만 스킵하고 계속 진행
   - UI에 경고 메시지 표시 (선택사항)

2. **순환 참조:**
   - A의 activated_by에 B, B의 activated_by에 A
   - 현재는 허용 (1단계 관계만 탐색하므로 무한 루프 없음)
   - 향후 체인 지원 시 검증 필요

3. **자기 참조:**
   - A의 activated_by에 A 자신
   - 무시하고 설정 안 함

**Validation 코드:**

```swift
// Phase 2에서 추가
for parsed in parsedTerms {
    guard let term = termsByKey[parsed.key] else { continue }

    term.activators.removeAll()

    for activatorKey in parsed.activatedByKeys {
        // 자기 참조 방지
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
```

#### 3.2.5 UI 피드백

**SheetsImportPreviewView에 activator 정보 표시:**

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

            // 기존: sources, variants 등 표시

            // 신규: activators 표시
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

#### 3.2.6 예시

**Google Sheets 데이터:**

```
key     | target | sources | activated_by
--------|--------|---------|-------------
ginga   | 긴가   | 银河    | hikaru
hikaru  | 히카루  | 光      |
taro    | 타로   | 太郎    | ginga,hikaru
red     | 레드   | 红      |
```

**Import 후 결과:**

```swift
// ginga Term
ginga.activators = [hikaru]
ginga.activates = [taro]  // 역관계 자동 설정됨 (SwiftData)

// hikaru Term
hikaru.activators = []
hikaru.activates = [ginga, taro]

// taro Term
taro.activators = [ginga, hikaru]
taro.activates = []

// red Term
red.activators = []
red.activates = []
```

---

## 4. TermMasker 변경

### 4.1 makeNameGlossaries 수정

**현재 구조:**
```swift
let standaloneEntries = entries.filter { !$0.prohibitStandalone }
```

**변경 후:**
```swift
func makeNameGlossaries(forOriginalText original: String, entries: [GlossaryEntry]) -> [NameGlossary] {
    let normalizedOriginal = original.precomposedStringWithCompatibilityMapping.lowercased()

    // Step 1: prohibitStandalone이 아닌 entry 수집
    var allowedEntries = entries.filter { !$0.prohibitStandalone }

    // Step 2: Segment에서 실제 사용된 Term 키 수집
    let usedTermKeys = collectUsedTermKeys(in: normalizedOriginal, from: entries)

    // Step 3: 사용된 Term들이 activate하는 Term 키 수집
    let activatedTermKeys = collectActivatedTermKeys(from: usedTermKeys, entries: entries)

    // Step 4-1: Pattern-based promotion (기존 promoteProhibitedEntries 로직)
    let patternPromoted = promoteByPatternPairs(in: normalizedOriginal, from: entries)
    allowedEntries.append(contentsOf: patternPromoted)

    // Step 4-2: Term-to-Term activation (신규)
    let termPromoted = promoteActivatedEntries(
        in: normalizedOriginal,
        from: entries,
        activatedKeys: activatedTermKeys
    )
    allowedEntries.append(contentsOf: termPromoted)

    // Step 5: 기존 로직 계속 (filterBySourceOcc, variant map 생성 등)
    allowedEntries = filterBySourceOcc(normalizedOriginal, allowedEntries)
    // ... 나머지 기존 코드
}
```

### 4.2 새 헬퍼 메서드 추가

**collectUsedTermKeys:**
```swift
private func collectUsedTermKeys(in segmentText: String, from entries: [GlossaryEntry]) -> Set<String> {
    var usedKeys = Set<String>()

    for entry in entries {
        // prohibitStandalone=false이고 실제로 등장하는 경우만
        guard !entry.prohibitStandalone else { continue }
        guard segmentText.contains(entry.source.precomposedStringWithCompatibilityMapping.lowercased()) else { continue }

        switch entry.origin {
        case .termStandalone(let key):
            usedKeys.insert(key)

        case .composer(_, let leftKey, let rightKey, _):
            usedKeys.insert(leftKey)
            if let rKey = rightKey {
                usedKeys.insert(rKey)
            }
        }
    }

    return usedKeys
}
```

**collectActivatedTermKeys:**
```swift
private func collectActivatedTermKeys(from usedKeys: Set<String>, entries: [GlossaryEntry]) -> Set<String> {
    var activatedKeys = Set<String>()

    // 사용된 Term의 activatesKeys를 모두 수집
    for entry in entries {
        let entryKey: String?
        switch entry.origin {
        case .termStandalone(let key):
            entryKey = key
        case .composer(_, let leftKey, _):
            entryKey = leftKey  // composer는 leftKey로 대표
        }

        guard let key = entryKey, usedKeys.contains(key) else { continue }

        // 이 entry가 activate하는 Term들 추가
        activatedKeys.formUnion(entry.activatesKeys)
    }

    return activatedKeys
}
```

**promoteActivatedEntries:**
```swift
private func promoteActivatedEntries(
    in segmentText: String,
    from entries: [GlossaryEntry],
    activatedKeys: Set<String>
) -> [GlossaryEntry] {
    var promoted: [GlossaryEntry] = []

    for entry in entries {
        // prohibited 아니면 스킵
        guard entry.prohibitStandalone else { continue }

        // Segment에 등장하지 않으면 스킵
        guard segmentText.contains(entry.source.precomposedStringWithCompatibilityMapping.lowercased()) else { continue }

        // 이 entry가 활성화되었는지 체크
        if case .termStandalone(let key) = entry.origin,
           activatedKeys.contains(key) {
            // prohibitStandalone을 false로 바꾼 복사본 추가
            var activated = entry
            activated.prohibitStandalone = false
            promoted.append(activated)
        }
    }

    return promoted
}
```

### 4.3 기존 promoteProhibitedEntries를 promoteByPatternPairs로 리팩토링

**기존 promoteProhibitedEntries 로직을 재사용:**

```swift
private func promoteByPatternPairs(in segmentText: String, from entries: [GlossaryEntry]) -> [GlossaryEntry] {
    var promoted: [GlossaryEntry] = []

    // Step 1: composer entries에서 needPairCheck=true인 쌍 수집
    var composerPairs: [(left: String, right: String?)] = []
    for e in entries {
        if case .composer(_, let leftId, let rightId, let needPairCheck) = e.origin,
           needPairCheck {
            composerPairs.append((left: leftId, right: rightId))
        }
    }

    // Step 2: prohibited standalone terms 수집
    var prohibTerms: [String: [GlossaryEntry]] = [:]
    for e in entries where e.prohibitStandalone {
        if case .termStandalone(let termId) = e.origin {
            prohibTerms[termId, default: []].append(e)
        }
    }

    // Step 3: 각 쌍에 대해 contextWindow 내 거리 체크
    for pair in composerPairs {
        // left와 right가 contextWindow(40자) 내에 있는지 체크
        let leftOccurrences = findOccurrences(of: pair.left, in: segmentText, entries: entries)
        let rightOccurrences: [Int]
        if let rightId = pair.right {
            rightOccurrences = findOccurrences(of: rightId, in: segmentText, entries: entries)
        } else {
            rightOccurrences = []
        }

        // 거리 체크
        var shouldPromote = false
        for leftPos in leftOccurrences {
            for rightPos in rightOccurrences {
                if abs(leftPos - rightPos) <= contextWindow {
                    shouldPromote = true
                    break
                }
            }
            if shouldPromote { break }
        }

        // Promote
        if shouldPromote {
            if let leftEntries = prohibTerms[pair.left] {
                promoted.append(contentsOf: leftEntries.map { var e = $0; e.prohibitStandalone = false; return e })
            }
            if let rightId = pair.right, let rightEntries = prohibTerms[rightId] {
                promoted.append(contentsOf: rightEntries.map { var e = $0; e.prohibitStandalone = false; return e })
            }
        }
    }

    return promoted
}

private func findOccurrences(of termKey: String, in text: String, entries: [GlossaryEntry]) -> [Int] {
    var positions: [Int] = []

    // termKey에 해당하는 entry의 source를 찾아서 위치 반환
    let sources = entries.filter {
        if case .termStandalone(let key) = $0.origin, key == termKey {
            return true
        }
        return false
    }.map { $0.source }

    for source in sources {
        let normalized = source.precomposedStringWithCompatibilityMapping.lowercased()
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(of: normalized, range: searchRange) {
            positions.append(text.distance(from: text.startIndex, to: range.lowerBound))
            searchRange = range.upperBound..<text.endIndex
        }
    }

    return positions.sorted()
}
```

---

## 5. 전체 플로우

### 5.1 Entry 생성 (페이지 로드 시, 1회)

```
Glossary.Service.buildEntries(pageText)
  ↓
각 Term에서 activators/activates 관계 추출
  ↓
GlossaryEntry에 activatorKeys/activatesKeys 포함하여 생성
  ↓
[모든 matched entries (prohibited 포함)]
```

### 5.2 Segment 번역 시 (각 Segment마다)

```
TranslationRouter.translateStream()
  ↓
각 Segment마다:
  ↓
prepareMaskingContext()
  ├─ maskWithLocks() [마스킹 방식, preMask=true만]
  └─ makeNameGlossaries() [정규화 방식, isAppellation=true 중심]
       ↓
     collectUsedTermKeys() [Segment에서 실제 사용된 Term]
       ↓
     collectActivatedTermKeys() [activate되어야 할 Term]
       ↓
     promoteByPatternPairs() [기존: Pattern-based activation]
       ↓
     promoteActivatedEntries() [신규: Term-to-Term activation]
       ↓
     [allowedEntries = non-prohibited + pattern-promoted + term-promoted]
       ↓
     filterBySourceOcc() [독립 출현 체크]
       ↓
     [NameGlossary 생성]
  ↓
번역 엔진 호출
  ↓
processStream()
  └─ restoreOutput()
       └─ normalizeVariantsAndParticles(nameGlossaries)
            └─ activated terms의 variants도 정규화됨
```

---

## 6. 예시 실행

### 6.1 데이터 준비

**Terms:**
```
ginga: { key: "ginga", target: "긴가", activators: [hikaru] }
hikaru: { key: "hikaru", target: "히카루", activates: [ginga] }
```

**GlossaryEntries (buildEntries 결과):**
```
1. source="银河", target="긴가", prohibitStandalone=true,
   origin=.termStandalone("ginga"), activatorKeys=["hikaru"]

2. source="小光", target="히카루", prohibitStandalone=false,
   origin=.composer("person", "xiao", "hikaru"), activatesKeys=["ginga"]

3. source="光", target="히카루", prohibitStandalone=true,
   origin=.termStandalone("hikaru"), activatorKeys=[]
```

### 6.2 Segment 처리: "银河和小光一起战斗"

**makeNameGlossaries 실행:**

1. **Initial filter:**
   ```
   allowedEntries = [Entry 2]  // prohibitStandalone=false만
   ```

2. **collectUsedTermKeys:**
   ```
   "小光" 등장 → Entry 2 (composer) → usedKeys = {"xiao", "hikaru"}
   ```

3. **collectActivatedTermKeys:**
   ```
   Entry 2의 activatesKeys = ["ginga"]
   → activatedKeys = {"ginga"}
   ```

4. **promoteByPatternPairs:**
   ```
   (Pattern-based activation이 있다면 여기서 처리)
   ```

5. **promoteActivatedEntries:**
   ```
   Entry 1: termKey="ginga" ∈ activatedKeys ✓, "银河" ∈ segment ✓
   → Entry 1 복사본(prohibitStandalone=false) 추가
   allowedEntries = [Entry 2, Entry 1*]
   ```

6. **filterBySourceOcc + variant map:**
   ```
   NameGlossaries = [
     { target: "히카루", variants: [...], expectedCount: 1 },
     { target: "긴가", variants: [...], expectedCount: 1 }  // 활성화됨!
   ]
   ```

7. **번역 후 정규화:**
   ```
   번역 결과: "은하와 히카루가 함께 싸운다"
   정규화 후: "긴가와 히카루가 함께 싸운다"  // "은하" → "긴가"
   ```

### 6.3 다른 Segment: "银河是一个美丽的星系"

**makeNameGlossaries 실행:**

1. **usedTermKeys:** (히카루 없음) → {}
2. **activatedKeys:** → {}
3. **promoteActivatedEntries:** 아무것도 promote 안 됨
4. **NameGlossaries:** "긴가" 포함 안 됨
5. **번역 후:** "은하는 아름다운 은하계다" (활성화 안 됨, 의도한 동작)

---

## 7. UI/UX 설계

### 7.1 Term 편집 화면

**TermEditorSheet 섹션 추가:**

```
┌─────────────────────────────────────┐
│ Term 편집: 긴가                      │
├─────────────────────────────────────┤
│ 번역: 긴가                           │
│ 변형: [긴가様]                       │
│                                      │
│ Sources:                             │
│   - 银河 (단독 번역 금지)            │
│                                      │
│ ┌─ 조건부 활성화 설정 ─────────────┐│
│ │                                   ││
│ │ 💡 이 용어를 활성화하는 용어:     ││
│ │   [히카루] [×]                    ││
│ │   [+ 용어 추가]                   ││
│ │                                   ││
│ │ 💡 이 용어가 활성화하는 용어:     ││
│ │   (없음)                          ││
│ │   [+ 용어 추가]                   ││
│ │                                   ││
│ └───────────────────────────────────┘│
│                                      │
│ [저장] [취소]                        │
└─────────────────────────────────────┘
```

### 7.2 UI 구현

**TermEditorSheet에 Section 추가:**

```swift
Section("조건부 활성화") {
    VStack(alignment: .leading, spacing: 12) {
        // Activators (이 용어를 활성화하는)
        VStack(alignment: .leading) {
            Text("💡 이 용어를 활성화하는 용어")
                .font(.caption)
                .foregroundColor(.secondary)

            if draft.activators.isEmpty {
                Text("(없음)")
                    .foregroundColor(.secondary)
            } else {
                TagChips(
                    tags: draft.activators.map { $0.target },
                    onRemove: { index in
                        draft.activators.remove(at: index)
                    }
                )
            }

            Button("+ 용어 추가") {
                showActivatorPicker = true
            }
        }

        Divider()

        // Activates (이 용어가 활성화하는)
        VStack(alignment: .leading) {
            Text("💡 이 용어가 활성화하는 용어")
                .font(.caption)
                .foregroundColor(.secondary)

            if draft.activates.isEmpty {
                Text("(없음)")
                    .foregroundColor(.secondary)
            } else {
                TagChips(
                    tags: draft.activates.map { $0.target },
                    onRemove: { index in
                        draft.activates.remove(at: index)
                    }
                )
            }

            Button("+ 용어 추가") {
                showActivatesPicker = true
            }
        }
    }
}
```

**Term Picker Sheet:**

```swift
struct TermPickerSheet: View {
    @Binding var selectedTerms: [SDTerm]
    let allTerms: [SDTerm]
    @State private var searchText = ""

    var filteredTerms: [SDTerm] {
        if searchText.isEmpty {
            return allTerms
        }
        return allTerms.filter {
            $0.target.contains(searchText) ||
            $0.key.contains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(filteredTerms) { term in
                    HStack {
                        Text(term.target)
                        Spacer()
                        if selectedTerms.contains(where: { $0.key == term.key }) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(term)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "용어 검색")
            .navigationTitle("용어 선택")
        }
    }

    private func toggleSelection(_ term: SDTerm) {
        if let index = selectedTerms.firstIndex(where: { $0.key == term.key }) {
            selectedTerms.remove(at: index)
        } else {
            selectedTerms.append(term)
        }
    }
}
```

---

## 8. 구현 우선순위

### Phase 1: 핵심 기능 (MVP)

1. **데이터 모델** (0.5일)
   - SDTerm에 activators/activates 관계 추가
   - GlossaryEntry에 activatorKeys/activatesKeys 추가

2. **Glossary.Service** (0.5일)
   - buildEntries에서 activatorKeys/activatesKeys 포함
   - Google Sheets import 파싱 로직 (activated_by 컬럼)
   - upsertTermsFromSheet에서 activator 관계 설정

3. **TermMasker** (1일)
   - makeNameGlossaries에 헬퍼 메서드 3개 추가
   - promoteByPatternPairs 리팩토링
   - 기존 로직과 통합

4. **기본 UI** (1일)
   - TermEditorSheet 섹션 추가
   - 간단한 Term 선택 UI

**합계: 3일**

### Phase 2: 개선 (선택사항)

5. **UI 향상** (0.5일)
   - 검색 기능
   - TagChips 스타일링
   - SheetsImportPreviewView에 activator 정보 표시

6. **테스트** (1일)
   - 단위 테스트
   - 통합 테스트

7. **문서화** (0.5일)
   - CLAUDE.md 업데이트
   - 코드 주석

**합계: 2일**

---

## 9. 테스트 케이스

### 9.1 단위 테스트

**Test 1: Term-to-Term Activation**
```swift
func testTermActivation_InSegment() {
    // Segment에 activator 있을 때 activate
    let masker = TermMasker()
    let segment = "银河和小光一起战斗"
    let entries = [
        GlossaryEntry(
            source: "小光", target: "히카루",
            prohibitStandalone: false,
            activatesKeys: ["ginga"],
            origin: .composer("person", "xiao", "hikaru", false)
        ),
        GlossaryEntry(
            source: "银河", target: "긴가",
            prohibitStandalone: true,
            activatorKeys: ["hikaru"],
            origin: .termStandalone("ginga")
        )
    ]

    let nameGlossaries = masker.makeNameGlossaries(forOriginalText: segment, entries: entries)

    XCTAssertTrue(nameGlossaries.contains { $0.target == "긴가" })
}
```

**Test 2: No Activator in Segment**
```swift
func testTermActivation_NoActivator() {
    // Segment에 activator 없을 때 비활성화
    let masker = TermMasker()
    let segment = "银河是一个美丽的星系"
    let entries = [
        GlossaryEntry(
            source: "银河", target: "긴가",
            prohibitStandalone: true,
            activatorKeys: ["hikaru"],
            origin: .termStandalone("ginga")
        )
    ]

    let nameGlossaries = masker.makeNameGlossaries(forOriginalText: segment, entries: entries)

    XCTAssertFalse(nameGlossaries.contains { $0.target == "긴가" })
}
```

**Test 3: Pattern-based + Term-based Activation 혼합**
```swift
func testMixedActivation() {
    // Pattern-based와 Term-based activation이 함께 작동
    let masker = TermMasker()
    let segment = "红凯和银河一起战斗"
    let entries = [
        GlossaryEntry(
            source: "红凯", target: "레드 카이",
            prohibitStandalone: false,
            activatesKeys: ["ginga"],
            origin: .composer("person", "red", "kai", true)
        ),
        GlossaryEntry(
            source: "红", target: "레드",
            prohibitStandalone: true,
            origin: .termStandalone("red")
        ),
        GlossaryEntry(
            source: "银河", target: "긴가",
            prohibitStandalone: true,
            activatorKeys: ["kai"],
            origin: .termStandalone("ginga")
        )
    ]

    let nameGlossaries = masker.makeNameGlossaries(forOriginalText: segment, entries: entries)

    // Pattern-based: "红" promoted (because "红凯" with needPairCheck)
    XCTAssertTrue(nameGlossaries.contains { $0.target == "레드" })

    // Term-based: "银河" promoted (because "kai" activates "ginga")
    XCTAssertTrue(nameGlossaries.contains { $0.target == "긴가" })
}
```

### 9.2 통합 테스트

**Test 4: End-to-End Normalization**
```swift
func testEndToEndNormalization() {
    // 번역 후 정규화까지 전체 플로우 테스트
    let segment = Segment(id: "1", originalText: "银河和小光一起战斗")
    let entries = [/* ... */]

    let nameGlossaries = masker.makeNameGlossaries(forOriginalText: segment.originalText, entries: entries)

    // 가짜 번역 결과
    let translated = "은하와 히카루가 함께 싸운다"

    // 정규화
    let normalized = masker.normalizeVariantsAndParticles(in: translated, entries: nameGlossaries)

    XCTAssertEqual(normalized, "긴가와 히카루가 함께 싸운다")
}
```

### 9.3 Google Sheets Import 테스트

**Test 5: Activated_by 컬럼 파싱**
```swift
func testSheetsImport_ActivatedByParsing() {
    // 단일 activator
    let row1 = ["ginga", "긴가", "银河", "hikaru"]
    let headers = ["key", "target", "sources", "activated_by"]
    let parsed1 = Glossary.Sheet.parseTermRow(row1, headers: headers)

    XCTAssertEqual(parsed1?.activatedByKeys, ["hikaru"])

    // 복수 activators (쉼표 구분)
    let row2 = ["taro", "타로", "太郎", "ginga,hikaru"]
    let parsed2 = Glossary.Sheet.parseTermRow(row2, headers: headers)

    XCTAssertEqual(parsed2?.activatedByKeys, ["ginga", "hikaru"])

    // 빈 값
    let row3 = ["red", "레드", "红", ""]
    let parsed3 = Glossary.Sheet.parseTermRow(row3, headers: headers)

    XCTAssertEqual(parsed3?.activatedByKeys, [])

    // 공백 포함 (자동 trim)
    let row4 = ["kai", "카이", "凯", " ginga , hikaru "]
    let parsed4 = Glossary.Sheet.parseTermRow(row4, headers: headers)

    XCTAssertEqual(parsed4?.activatedByKeys, ["ginga", "hikaru"])
}
```

**Test 6: Upsert with Activator 관계 설정**
```swift
func testSheetsImport_UpsertActivators() async throws {
    let context = ModelContext(/* test container */)
    let glossaryService = Glossary.Service(context: context)

    // Parse된 Term 데이터
    let parsedTerms = [
        Glossary.Sheet.ParsedTerm(
            key: "ginga",
            target: "긴가",
            variants: [],
            sources: [/* ... */],
            activatedByKeys: ["hikaru"]
        ),
        Glossary.Sheet.ParsedTerm(
            key: "hikaru",
            target: "히카루",
            variants: [],
            sources: [/* ... */],
            activatedByKeys: []
        )
    ]

    // Upsert 실행
    try await glossaryService.upsertTermsFromSheet(parsedTerms, context: context)

    // 검증
    let ginga = try context.fetch(
        FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == "ginga" })
    ).first

    let hikaru = try context.fetch(
        FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == "hikaru" })
    ).first

    XCTAssertNotNil(ginga)
    XCTAssertNotNil(hikaru)
    XCTAssertEqual(ginga?.activators.map { $0.key }, ["hikaru"])
    XCTAssertEqual(hikaru?.activates.map { $0.key }, ["ginga"])
}
```

**Test 7: 존재하지 않는 Activator 처리**
```swift
func testSheetsImport_MissingActivator() async throws {
    let context = ModelContext(/* test container */)
    let glossaryService = Glossary.Service(context: context)

    // 존재하지 않는 activator 참조
    let parsedTerms = [
        Glossary.Sheet.ParsedTerm(
            key: "ginga",
            target: "긴가",
            variants: [],
            sources: [/* ... */],
            activatedByKeys: ["nonexistent"]  // 존재하지 않는 Term
        )
    ]

    // Upsert는 성공해야 함 (경고만 출력)
    try await glossaryService.upsertTermsFromSheet(parsedTerms, context: context)

    let ginga = try context.fetch(
        FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == "ginga" })
    ).first

    XCTAssertNotNil(ginga)
    XCTAssertEqual(ginga?.activators.count, 0)  // activator 설정 안 됨
}
```

**Test 8: 자기 참조 방지**
```swift
func testSheetsImport_SelfReference() async throws {
    let context = ModelContext(/* test container */)
    let glossaryService = Glossary.Service(context: context)

    // 자기 자신을 activator로 참조
    let parsedTerms = [
        Glossary.Sheet.ParsedTerm(
            key: "ginga",
            target: "긴가",
            variants: [],
            sources: [/* ... */],
            activatedByKeys: ["ginga"]  // 자기 참조
        )
    ]

    try await glossaryService.upsertTermsFromSheet(parsedTerms, context: context)

    let ginga = try context.fetch(
        FetchDescriptor<SDTerm>(predicate: #Predicate { $0.key == "ginga" })
    ).first

    XCTAssertNotNil(ginga)
    XCTAssertEqual(ginga?.activators.count, 0)  // 자기 참조 무시됨
}
```

---

## 10. 요약

### 핵심 변경사항

1. **SDTerm**: activators/activates 관계 추가
2. **GlossaryEntry**: activatorKeys/activatesKeys 추가
3. **Glossary.Service.buildEntries**: Term 관계를 Entry에 포함
4. **Glossary.Sheet**: activated_by 컬럼 파싱 및 upsert 로직
5. **TermMasker.makeNameGlossaries**: Segment별 activation 로직 추가
   - collectUsedTermKeys()
   - collectActivatedTermKeys()
   - promoteByPatternPairs() (기존 로직 리팩토링)
   - promoteActivatedEntries() (신규)

### 장점

✅ **정확한 위치**: makeNameGlossaries 내부 (정규화 방식에 적용)
✅ **효율적**: 모든 Term이 아닌 GlossaryEntry만 사용
✅ **Segment 단위**: 각 Segment마다 독립적으로 activation 판단
✅ **기존 로직 보존**: prohibitStandalone 메커니즘 유지
✅ **확장 가능**: Pattern-based activation과 Term-based activation 공존
✅ **마이그레이션 불필요**: 개발 단계이므로 앱 재설치로 충분

### 구현 난이도 및 기간

**난이도**: 중
**예상 기간**: 3일 (MVP), 5일 (전체)

### 기술적 고려사항

1. **중복 제거**: Pattern-based와 Term-based 모두에서 promote될 경우 중복 체크 필요
2. **성능**: Segment마다 Term 키 수집 및 관계 조회하지만, in-memory 작업이므로 충분히 빠름
3. **확장성**: 향후 마스킹 방식에도 동일한 로직 적용 가능 (maskWithLocks 수정)
4. **디버깅**: origin과 activation 정보로 어떤 경로로 활성화되었는지 추적 가능

### 다음 단계

1. SDTerm 모델에 관계 추가
2. GlossaryEntry 구조체 확장
3. buildEntries 로직 수정
4. Google Sheets import 파싱 및 upsert 로직
5. TermMasker 헬퍼 메서드 구현
6. makeNameGlossaries 통합
7. UI 구현 (TermEditorSheet + SheetsImportPreviewView)
8. 테스트 작성

---

**문서 버전**: 1.1
**작성일**: 2025-11-20
**최종 수정**: 2025-11-20 (Google Sheets import 지원 추가)
**상태**: 승인됨
