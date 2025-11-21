# SPEC: 세그먼트 용어집 감지 로직 리팩토링

**작성일**: 2025-11-20
**최종 수정**: 2025-11-21 (Codex 리뷰 반영)
**상태**: Planning (구현 전)
**우선순위**: P1

---

## 1. 개요 및 목적

### 1.1 배경

현재 `DefaultTranslationRouter.prepareMaskingContext()`는 다음과 같이 동작합니다:

1. `maskWithLocks()`: 용어를 토큰으로 마스킹 (preMask == true인 것만)
2. `makeNameGlossaries()`: 정규화용 용어집 생성 (preMask == false인 것)

이 구조는 다음과 같은 문제가 있습니다:

- **위치 정보 손실**: 용어가 원문의 어디에 있는지 range 정보가 보존되지 않음
- **중복 처리**: 두 함수가 각각 AC 알고리즘으로 용어를 검색하여 비효율적
- **로직 분산**: Term 활성화, filterBySourceOcc 등의 로직이 여러 곳에 분산
- **오버레이 제약**: 감지된 용어를 UI에서 시각적으로 표시하기 어려움

### 1.2 목표

**SegmentPieces 기반 구조로 전환하여**:

1. 모든 용어를 한 번에 검출 (마스킹 대상/정규화 대상 구분 없이)
2. 용어의 원문 위치 정보(range) 보존
3. Term 활성화 로직과 통합
4. AC 알고리즘 실행 횟수 최소화 (성능 개선)
5. 오버레이 패널에서 용어 시각화 가능

---

## 2. 현재 구현 분석

### 2.1 prepareMaskingContext 흐름

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift` (라인 260-292)

```swift
private func prepareMaskingContext(
    from segments: [Segment],
    glossaryEntries: [GlossaryEntry],
    engine: TranslationEngine,
    termMasker: TermMasker
) -> MaskingContext {
    // 1단계: 마스킹 (preMask == true만 처리)
    let maskedPacks: [MaskedPack] = segments.map { segment in
        termMasker.maskWithLocks(segment: segment, glossary: glossaryEntries)
    }

    // 2단계: 마스킹된 텍스트로 새 Segment 생성
    let maskedSegments: [Segment] = maskedPacks.map { ... }

    // 3단계: 정규화용 이름 용어집 생성 (preMask == false 처리)
    let nameGlossariesPerSegment: [[TermMasker.NameGlossary]] = {
        return maskedPacks.map { pack in
            termMasker.makeNameGlossaries(
                forOriginalText: pack.seg.originalText,
                entries: glossaryEntries
            )
        }
    }()

    return MaskingContext(...)
}
```

### 2.2 maskWithLocks 핵심 로직

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift` (라인 209-288)

1. Entry를 긴 것부터 정렬 (`sorted { $0.source.count > $1.source.count }`)
2. `preMask == false`인 것은 스킵
3. 각 용어를 토큰으로 치환 (`__E#123__`)
4. LockInfo 생성 (받침 정보, 호칭 여부 등)

**문제점**: preMask == false인 용어는 처리하지 않음 → makeNameGlossaries에서 다시 검색해야 함

### 2.3 makeNameGlossaries 핵심 로직

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift` (라인 575-648)

1. **Term 활성화**:
   - 기본 활성화: `prohibitStandalone == false`인 Entry
   - Pattern 기반: `promoteProhibitedEntries(in:entries:)`
   - Term-to-Term: `collectUsedTermKeys()` → `collectActivatedTermKeys()` → `promoteActivatedEntries(from:standaloneEntries:original:)`
2. **중복 제거**: source 기준으로 중복 Entry 제거
3. **긴 용어에 덮이는 짧은 용어 제외**: `filterBySourceOcc(_:_:)`
4. **NameGlossary 생성**: target별로 variants와 expectedCount 집계

**문제점**: maskWithLocks와 별도로 용어를 다시 검색함 (각 함수가 독립적으로 용어 매칭 수행)

### 2.4 MaskingContext 타입

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift` (라인 486-491)

```swift
private struct MaskingContext {
    let maskedSegments: [Segment]
    let maskedPacks: [MaskedPack]
    let nameGlossariesPerSegment: [[TermMasker.NameGlossary]]
    let engineTag: EngineTag
}
```

### 2.5 현재 구현 상태

**2025-11-21 기준**: 이 스펙 문서에서 제안하는 SegmentPieces 기반 리팩토링은 **아직 구현되지 않았습니다**.

현재 코드베이스는 여전히 2.1-2.4에서 설명한 기존 구조를 사용하고 있습니다:
- `prepareMaskingContext`는 `maskWithLocks()`와 `makeNameGlossaries()`를 별도로 호출
- SegmentPieces 타입 및 관련 메서드들은 존재하지 않음
- MaskingContext에 `segmentPieces` 필드 없음

**구현 계획**: 섹션 5 (구현 계획)의 Phase 1-6을 순차적으로 진행 예정

---

## 3. SegmentPieces 설계

### 3.1 핵심 아이디어

세그먼트 텍스트를 **텍스트 조각**과 **용어 조각**으로 분해:

```swift
SegmentPiece:
  - .text(String)      // 일반 텍스트
  - .term(GlossaryEntry)  // 감지된 용어

SegmentPieces: [SegmentPiece]
```

**초기 상태**: `[.text(fullSegmentText)]`

**Longest-first 알고리즘**:
1. 긴 source → 짧은 source 순으로 Entry 순회
2. 각 Entry마다 `.text(str)` 조각에서만 검색
3. 발견되면 `[.text, .term(entry), .text, ...]`로 분해
4. `.term(...)` 조각은 다시 split하지 않음 → 긴 용어가 짧은 용어를 자동으로 덮음

### 3.2 장점

1. **겹침 자동 해소**: filterBySourceOcc 로직이 알고리즘에 내장됨
2. **원문 순서 보존**: 왼쪽부터 순회하면 원문 등장 순서 유지
   - SegmentPieces를 왼쪽에서 오른쪽으로 순회하면 `.term(entry)` 조각이 원문 등장 순서대로 나타남
   - 정규화/언마스킹 시 우선순위 힌트로 활용 가능
3. **통합된 데이터 구조**: 마스킹/정규화 대상을 모두 포함

### 3.3 번역 파이프라인에서의 활용

SegmentPieces는 번역 파이프라인 전체에서 용어 위치 맥락을 유지하는 공통 기준이 됩니다.

#### 3.3.1 마스킹 단계

SegmentPieces를 왼쪽부터 순회하면서:
- `.text(str)` → 그대로 출력
- `.term(entry)`:
  - `preMask == true` → 토큰(`__E#k__`)으로 치환하고 maskedEntries에 기록
  - `preMask == false` → 원문 그대로 두고 unmaskedEntries에 기록

**결과**: 마스킹된 원문 텍스트, maskedEntries, unmaskedEntries

#### 3.3.2 정규화 단계 (preMask == false 대상)

번역 결과에서:
- 토큰(`__E#k__`)이 들어간 영역은 정규화 탐색에서 스킵
- variants 매칭 → entry.target으로 치환
- 치환 시 **바로 옆 조사만 국소 보정** (전체 재스캔 없음)
- unmaskedEntries의 원문 순서는 애매한 후보 중 우선순위 힌트로만 사용

**Pattern Fallback 처리** (섹션 6.6 참고):
- Pattern으로 생성된 entry의 variants로 매칭 시도
- 실패 시, Pattern을 구성하는 개별 Term들의 variants로 재시도
- 예: "凯文·杜兰特" Pattern의 variants에 "케빈"이 없으면 → "凯文" Term의 variants로 재시도
- 이를 통해 번역엔진이 풀네임을 이름만으로 번역하는 케이스 처리

#### 3.3.3 언마스킹 단계 (preMask == true 대상)

번역 결과에서:
- 토큰을 왼쪽부터 순서대로 탐색
- maskedEntries에서 대응 entry를 순서대로 꺼냄
- 토큰 → entry.target으로 치환
- 치환 시 **바로 옆 조사만 국소 보정** (전체 재스캔 없음)

---

## 4. 새로운 타입 설계

### 4.1 SegmentPieces 타입

**새 파일**: `MyTranslation/Domain/Models/SegmentPieces.swift`

```swift
public struct SegmentPieces: Sendable {
    public let segmentID: String
    public let pieces: [Piece]

    public enum Piece: Sendable {
        case text(String)
        case term(GlossaryEntry)
    }

    // 편의 메서드
    public var detectedTerms: [GlossaryEntry] {
        pieces.compactMap {
            if case .term(let entry) = $0 { return entry }
            return nil
        }
    }

    public func maskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { $0.preMask }
    }

    public func unmaskedTerms() -> [GlossaryEntry] {
        detectedTerms.filter { !$0.preMask }
    }
}
```

### 4.2 MaskingContext 확장

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`

```swift
private struct MaskingContext {
    let maskedSegments: [Segment]
    let maskedPacks: [MaskedPack]
    let nameGlossariesPerSegment: [[TermMasker.NameGlossary]]
    let segmentPieces: [SegmentPieces]  // 추가
    let engineTag: EngineTag
}
```

---

## 5. 구현 계획

### 5.1 Phase 1: SegmentPieces 타입 정의

**작업**:
- `MyTranslation/Domain/Models/SegmentPieces.swift` 파일 생성
- 위 4.1의 타입 정의 구현

**테스트**: 타입 인스턴스 생성 및 편의 메서드 동작 확인

---

### 5.2 Phase 2: buildSegmentPieces 메서드 구현

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift`

**새 메서드**:

```swift
public func buildSegmentPieces(
    segment: Segment,
    glossary allEntries: [GlossaryEntry]
) -> (pieces: SegmentPieces, activatedEntries: [GlossaryEntry])
```

**내부 로직**:

```swift
func buildSegmentPieces(
    segment: Segment,
    glossary allEntries: [GlossaryEntry]
) -> (pieces: SegmentPieces, activatedEntries: [GlossaryEntry]) {
    let text = segment.originalText
    guard !text.isEmpty, !allEntries.isEmpty else {
        return (
            pieces: SegmentPieces(segmentID: segment.id, pieces: [.text(text)]),
            activatedEntries: []
        )
    }

    // 1단계: 기본 활성화 (prohibitStandalone == false)
    let standaloneEntries = allEntries.filter { !$0.prohibitStandalone }

    // 2단계: Pattern 기반 활성화
    let patternPromoted = promoteProhibitedEntries(
        in: text,
        entries: allEntries
    )

    // 3단계: Term-to-Term 활성화
    let termPromoted = promoteActivatedEntries(
        from: allEntries,
        standaloneEntries: standaloneEntries,
        original: text
    )

    // 4단계: 모든 활성화된 Entry 병합 (중복 제거)
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

    // 5단계: filterBySourceOcc 적용 (긴 용어에 완전히 덮이는 짧은 용어 제외)
    allowedEntries = filterBySourceOcc(segment, allowedEntries)

    // 6단계: Longest-first 알고리즘으로 SegmentPieces 생성
    let sorted = allowedEntries.sorted { $0.source.count > $1.source.count }
    var pieces: [SegmentPieces.Piece] = [.text(text)]

    for entry in sorted {
        guard !entry.source.isEmpty else { continue }

        var newPieces: [SegmentPieces.Piece] = []

        for piece in pieces {
            switch piece {
            case .text(let str):
                // 이 텍스트에서 entry.source 찾기
                if str.contains(entry.source) {
                    // str을 [.text, .term, .text, ...] 로 분해
                    let parts = splitTextBySource(str, source: entry.source)
                    for part in parts {
                        if part == entry.source {
                            newPieces.append(.term(entry))
                        } else {
                            newPieces.append(.text(part))
                        }
                    }
                } else {
                    newPieces.append(.text(str))
                }
            case .term:
                // 이미 term인 조각은 다시 split하지 않음
                newPieces.append(piece)
            }
        }

        pieces = newPieces
    }

    return (
        pieces: SegmentPieces(segmentID: segment.id, pieces: pieces),
        activatedEntries: allowedEntries
    )
}
```

**헬퍼 함수**:

```swift
private func splitTextBySource(_ text: String, source: String) -> [String] {
    var parts: [String] = []
    var remaining = text

    while let range = remaining.range(of: source) {
        // 앞부분
        if range.lowerBound > remaining.startIndex {
            parts.append(String(remaining[remaining.startIndex..<range.lowerBound]))
        }
        // 매치된 부분
        parts.append(source)
        // 나머지
        remaining = String(remaining[range.upperBound...])
    }

    // 마지막 남은 부분
    if !remaining.isEmpty {
        parts.append(remaining)
    }

    return parts
}
```

**테스트**:
- 다양한 용어 조합으로 pieces 생성 확인
- 긴 용어가 짧은 용어를 덮는지 확인
- Term 활성화 로직 정상 작동 확인

---

### 5.3 Phase 3: pieces 기반 마스킹 메서드 구현

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift`

**새 메서드**:

```swift
public func maskFromPieces(
    pieces: SegmentPieces,
    segment: Segment
) -> MaskedPack
```

**내부 로직**:

```swift
func maskFromPieces(
    pieces: SegmentPieces,
    segment: Segment
) -> MaskedPack {
    var out = ""
    var locks: [String: LockInfo] = [:]
    var localNextIndex = self.nextIndex

    for piece in pieces.pieces {
        switch piece {
        case .text(let str):
            out += str

        case .term(let entry):
            if entry.preMask {
                // 토큰 생성
                let token = Self.makeToken(prefix: "E", index: localNextIndex)
                localNextIndex += 1
                out += token

                // 호칭일 때 NBSP 주입
                if entry.isAppellation {
                    out = surroundTokenWithNBSP(out, token: token)
                }

                // LockInfo 등록 (tags는 deprecated되어 제거)
                let (b, r) = hangulFinalJongInfo(entry.target)
                locks[token] = LockInfo(
                    placeholder: token,
                    target: entry.target,
                    endsWithBatchim: b,
                    endsWithRieul: r,
                    isAppellation: entry.isAppellation
                )
            } else {
                // preMask == false: 원문 그대로
                out += entry.source
            }
        }
    }

    // 토큰 좌우 공백 삽입 (격리된 세그먼트만)
    out = insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(out)

    self.nextIndex = localNextIndex
    return .init(seg: segment, masked: out, tags: [], locks: locks)  // tags는 빈 배열
}
```

**테스트**:
- 마스킹된 텍스트 정확성 확인
- LockInfo 생성 확인
- 호칭 NBSP 주입 확인

---

### 5.4 Phase 4: pieces 기반 정규화 정보 생성 메서드 구현

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift`

**새 메서드**:

```swift
public func makeNameGlossariesFromPieces(
    pieces: SegmentPieces,
    allEntries: [GlossaryEntry]  // Pattern Fallback을 위해 필요
) -> [NameGlossary]
```

**내부 로직**:

```swift
func makeNameGlossariesFromPieces(
    pieces: SegmentPieces,
    allEntries: [GlossaryEntry]  // Pattern Fallback을 위해 필요
) -> [NameGlossary] {
    // preMask == false인 용어만 추출
    let unmaskedEntries = pieces.detectedTerms.filter { !$0.preMask }

    guard !unmaskedEntries.isEmpty else { return [] }

    // target별로 variants와 expectedCount 집계
    var variantsByTarget: [String: [String]] = [:]
    var seenVariantKeysByTarget: [String: Set<String>] = [:]
    var expectedCountsByTarget: [String: Int] = [:]

    for entry in unmaskedEntries {
        guard !entry.target.isEmpty else { continue }

        // variants 수집 (중복 제거)
        if !entry.variants.isEmpty {
            var bucket = variantsByTarget[entry.target, default: []]
            var seen = seenVariantKeysByTarget[entry.target, default: []]
            for variant in entry.variants where !variant.isEmpty {
                let key = normKey(variant)
                if seen.insert(key).inserted {
                    bucket.append(variant)
                }
            }
            variantsByTarget[entry.target] = bucket
            seenVariantKeysByTarget[entry.target] = seen
        } else if variantsByTarget[entry.target] == nil {
            variantsByTarget[entry.target] = []
        }

        // 등장 횟수: pieces에서 이 entry가 몇 번 나타나는지
        let count = pieces.pieces.filter {
            if case .term(let e) = $0, e.target == entry.target {
                return true
            }
            return false
        }.count

        expectedCountsByTarget[entry.target, default: 0] += count

        // Pattern entry인 경우 fallback 정보 생성 (Phase 6.5)
        // (실제 구현은 Phase 6.5에서 진행)
    }

    guard !variantsByTarget.isEmpty else { return [] }

    // NameGlossary 배열 생성 및 정렬
    // 주의: Pattern entry의 fallbackTerms는 Phase 6.5에서 구현
    return variantsByTarget.map { target, variants in
        (target: target, variants: variants, count: expectedCountsByTarget[target] ?? 0)
    }.sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.target < rhs.target
    }.map { NameGlossary(target: $0.target, variants: $0.variants, expectedCount: $0.count) }
}
```

**테스트**:
- NameGlossary 생성 확인
- expectedCount 정확성 확인
- variants 중복 제거 확인

---

### 5.5 Phase 5: prepareMaskingContext 리팩토링

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`

**새 구현**:

```swift
private func prepareMaskingContext(
    from segments: [Segment],
    glossaryEntries: [GlossaryEntry],
    engine: TranslationEngine,
    termMasker: TermMasker
) -> MaskingContext {
    var allSegmentPieces: [SegmentPieces] = []
    var maskedPacks: [MaskedPack] = []
    var nameGlossariesPerSegment: [[TermMasker.NameGlossary]] = []

    for segment in segments {
        // 1. 용어 검출 + 활성화 (통합)
        let (pieces, _) = termMasker.buildSegmentPieces(
            segment: segment,
            glossary: glossaryEntries
        )
        allSegmentPieces.append(pieces)

        // 2. pieces 기반 마스킹
        let pack = termMasker.maskFromPieces(
            pieces: pieces,
            segment: segment
        )
        maskedPacks.append(pack)

        // 3. pieces 기반 정규화 정보 생성
        let nameGlossaries = termMasker.makeNameGlossariesFromPieces(
            pieces: pieces,
            allEntries: glossaryEntries  // Pattern Fallback을 위해 전달
        )
        nameGlossariesPerSegment.append(nameGlossaries)
    }

    // 4. 마스킹된 Segment 생성
    let maskedSegments = maskedPacks.map { pack in
        Segment(
            id: pack.seg.id,
            url: pack.seg.url,
            indexInPage: pack.seg.indexInPage,
            originalText: pack.masked,
            normalizedText: pack.seg.normalizedText,
            domRange: pack.seg.domRange
        )
    }

    return MaskingContext(
        maskedSegments: maskedSegments,
        maskedPacks: maskedPacks,
        nameGlossariesPerSegment: nameGlossariesPerSegment,
        segmentPieces: allSegmentPieces,
        engineTag: engine.tag
    )
}
```

**테스트**:
- 기존 번역 파이프라인 동작 확인
- 마스킹/정규화 결과 일관성 확인
- 성능 측정 (AC 알고리즘 실행 횟수)

---

### 5.6 Phase 6: MaskingContext 확장

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`

**수정**:

```swift
private struct MaskingContext {
    let maskedSegments: [Segment]
    let maskedPacks: [MaskedPack]
    let nameGlossariesPerSegment: [[TermMasker.NameGlossary]]
    let segmentPieces: [SegmentPieces]  // 추가
    let engineTag: EngineTag
}
```

**테스트**: 컴파일 확인

---

### 5.7 Phase 6.5: Pattern Fallback 로직 구현

**파일**:
- `MyTranslation/Domain/Glossary/GlossaryEntry.swift`
- `MyTranslation/Services/Translation/Masking/Masker.swift`
- `MyTranslation/Services/Translation/Postprocessing/Output.swift`

**작업**:

#### 1. Origin 필드 활용 (GlossaryEntry 수정 불필요)

**파일**: `MyTranslation/Domain/Glossary/GlossaryEntry.swift`

**변경 사항**: 없음. 기존 `origin` 필드를 활용합니다.

```swift
// 기존 GlossaryEntry.origin 필드 활용
public enum Origin {
    case termStandalone(termKey: String)
    case composer(composerId: String, leftKey: String, rightKey: String?, needPairCheck: Bool)
}

// Pattern entry 판별 예시
if case let .composer(_, leftKey, rightKey, _) = entry.origin {
    // leftKey: 첫 번째 Term의 key
    // rightKey: 두 번째 Term의 key (단일 구성이면 nil)
}
```

#### 2. NameGlossary 확장

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift`

```swift
public struct NameGlossary {
    public let target: String
    public let variants: [String]
    public let expectedCount: Int

    // Pattern Fallback 지원
    public struct FallbackTerm: Sendable {
        public let termKey: String  // Term의 key (origin에서 추출)
        public let target: String
        public let variants: [String]
    }
    public let fallbackTerms: [FallbackTerm]?
}
```

#### 3. makeNameGlossariesFromPieces 수정

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift`

```swift
func makeNameGlossariesFromPieces(
    pieces: SegmentPieces,
    allEntries: [GlossaryEntry]  // Pattern Fallback을 위해 필수
) -> [NameGlossary] {
    let unmaskedEntries = pieces.detectedTerms.filter { !$0.preMask }
    // ... 기존 로직 (variants 수집, expectedCount 계산 등)

    // Pattern entry의 fallback 정보 생성
    for entry in unmaskedEntries {
        // ... 기존 variants 수집 로직

        // Pattern entry인지 확인하고 fallback 정보 추가
        var fallbacks: [NameGlossary.FallbackTerm]? = nil
        if case let .composer(_, leftKey, rightKey, _) = entry.origin {
            var termKeys: [String] = [leftKey]
            if let rightKey = rightKey {
                termKeys.append(rightKey)
            }

            fallbacks = termKeys.compactMap { termKey in
                // allEntries에서 termKey로 Term entry 찾기
                guard let term = allEntries.first(where: {
                    if case .termStandalone(termKey: termKey) = $0.origin {
                        return true
                    }
                    return false
                }) else {
                    return nil
                }

                return NameGlossary.FallbackTerm(
                    termKey: termKey,
                    target: term.target,
                    variants: Array(term.variants)
                )
            }
        }

        // NameGlossary 생성 시 fallbackTerms 포함
        // ...
    }
}
```

#### 4. normalizeVariantsAndParticles 수정

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift`

```swift
func normalizeVariantsAndParticles(
    _ text: String,
    nameGlossaries: [TermMasker.NameGlossary],
    // ...
) -> String {
    var out = text

    for nameGlossary in nameGlossaries {
        // 1차 시도: Pattern variants
        if let matched = findAndReplaceVariant(
            in: out,
            variants: nameGlossary.variants,
            target: nameGlossary.target
        ) {
            out = matched
            continue
        }

        // 2차 시도: Fallback to Term variants
        if let fallbackTerms = nameGlossary.fallbackTerms {
            for fallbackTerm in fallbackTerms {
                if let matched = findAndReplaceVariant(
                    in: out,
                    variants: fallbackTerm.variants,
                    target: fallbackTerm.target
                ) {
                    out = matched
                    break  // 첫 번째 매칭된 Term으로만 치환
                }
            }
        }
    }

    return out
}

private func findAndReplaceVariant(
    in text: String,
    variants: [String],
    target: String
) -> String? {
    // 기존 variant 매칭 + 치환 로직
    // 매칭 성공 시 치환된 텍스트 반환, 실패 시 nil
}
```

**테스트**:

1. **Pattern Fallback 시나리오**:
   - Pattern "凯文·杜兰特"가 "케빈"으로 번역
   - Pattern variants로 매칭 실패
   - Term "凯文"의 variants로 매칭 성공 → "케빈"으로 정규화

2. **여러 Term 매칭 우선순위**:
   - Pattern "凯文·杜兰特"가 "케빈 듀란트"로 번역
   - Pattern variants로 매칭 실패
   - Term "凯文"과 "杜兰特" 모두 매칭 가능
   - fallbackTerms 순서대로 처리 (첫 번째 매칭만 적용)

3. **일반 entry는 영향 없음**:
   - patternSourceTermIds가 nil인 entry는 기존과 동일하게 동작

---

## 6. 통합 시 주의사항

### 6.1 Term 활성화 로직 보존

- `promoteProhibitedEntries(in:entries:)`: Pattern 기반 활성화 로직 그대로 재사용
- `promoteActivatedEntries(from:standaloneEntries:original:)`: Term-to-Term 활성화 로직 그대로 재사용
  - 내부적으로 `collectUsedTermKeys()`, `collectActivatedTermKeys()` 사용
- 기존 활성화 동작과 동일하게 작동하도록 검증

### 6.2 filterBySourceOcc 로직 보존

- `buildSegmentPieces` 5단계에서 `filterBySourceOcc(_:_:)` 호출
- 긴 용어에 완전히 덮이는 짧은 용어를 제외하여, Longest-first 알고리즘과 함께 긴 용어 우선 보장
- 기존 로직과 동일하게 동작

### 6.3 조사 보정 로직 영향 없음

- `restoreOutput()`의 `normalizeTokensAndParticles()`, `normalizeVariantsAndParticles()` 로직은 그대로 유지
- MaskingContext의 기존 필드들(`maskedPacks`, `nameGlossariesPerSegment`)이 동일하게 생성되므로 영향 없음

### 6.4 하위 호환성

- 기존 `maskWithLocks()`, `makeNameGlossaries()` 메서드는 일단 유지 (deprecated 표시)
- 향후 다른 코드에서 사용하지 않는 것이 확인되면 제거 가능

### 6.5 마스킹 토큰 개수 변경 영향

**기존 동작** (`maskWithLocks`):
```swift
for e in sorted {
    let token = Self.makeToken(prefix: "E", index: localNextIndex)
    localNextIndex += 1
    // NSRegularExpression으로 모든 매치를 찾아 같은 token으로 치환
    let matches = rx.matches(in: out, ...)
    for m in matches {
        newOut += token  // 같은 토큰 재사용
    }
}
```
- 같은 entry의 모든 등장을 **하나의 token**으로 치환
- 예: "ABA는 ABA다" → `__E#1__는 __E#1__다` (같은 토큰)
- `locks`: token당 1개

**새로운 동작** (Phase 3 `maskFromPieces`):
```swift
for piece in pieces.pieces {
    case .term(let entry):
        if entry.preMask {
            let token = Self.makeToken(prefix: "E", index: localNextIndex)
            localNextIndex += 1  // 매번 새 토큰 생성
            out += token
            // tags는 deprecated되어 제거
        }
}
```
- 같은 entry의 각 등장마다 **새로운 token** 생성
- 예: "ABA는 ABA다" → `__E#1__는 __E#2__다` (다른 토큰)
- `locks`: entry 등장 횟수만큼 증가

**영향 분석**:

1. **메모리 사용량 증가**:
   - locks 딕셔너리: entry 등장 횟수만큼 증가 (예: entry당 평균 1-3회 등장 시 2-3배)

2. **restoreOutput 영향**:
   - `normalizeTokensAndParticles()`: 각 토큰을 개별적으로 처리하므로 영향 없음
   - `unlockTermsSafely()`: locks 딕셔너리로 토큰별 복원하므로 영향 없음

3. **장점**:
   - 각 등장 위치마다 독립적인 조사 보정 가능
   - 원문 등장 순서 정보 보존 (토큰 번호로 추적 가능)

4. **tags 필드 제거**:
   - **현재 상태**: tags는 deprecated되어 사용되지 않음
   - **변경 사항**: Phase 3에서 tags 생성 로직 제거
   - **MaskedPack 수정**: tags 필드를 제거하거나 빈 배열로 유지
   - 기존 코드에서 tags 참조가 있다면 모두 제거 필요

### 6.6 Pattern 정규화 Fallback 전략

**배경 문제**:
번역엔진이 원문의 풀네임(Pattern으로 생성된 복합 용어)을 이름만으로 번역하는 경우, Pattern의 variants에는 해당 이름이 없어 정규화에 실패할 수 있습니다.

**예시**:
- 원문: "凯文·杜兰特" (Pattern: Term1="凯文" + Term2="杜兰特")
- Pattern target: "케빈 듀란트"
- Pattern variants: ["Kevin Durant", "케빈듀란트", ...]
- 번역 결과: "케빈" (이름만 번역)
- 문제: Pattern variants에 "케빈"이 없어 정규화 실패

**해결 전략**:

1. **1차 시도**: Pattern의 variants로 매칭
   - 정규화 로직에서 Pattern으로 생성된 GlossaryEntry의 variants로 먼저 매칭 시도
   - 성공 시 Pattern의 target으로 정규화

2. **2차 시도 (Fallback)**: 구성 Term들의 variants로 재시도
   - 1차 시도 실패 시, Pattern을 구성하는 개별 Term들의 variants로 재시도
   - 예: "케빈"이 Term1("凯文")의 variants에 있으면 Term1의 target("케빈")으로 정규화
   - 여러 Term이 매칭되면 원문 순서에 따라 우선순위 결정

**구현 요구사항**:

1. **GlossaryEntry의 origin 필드 활용**:
   ```swift
   // 기존 origin 필드로 Pattern 정보 확인
   public enum Origin {
       case termStandalone(termKey: String)
       case composer(composerId: String, leftKey: String, rightKey: String?, needPairCheck: Bool)
   }

   // Pattern entry 판별 및 구성 Term 추출
   if case let .composer(_, leftKey, rightKey, _) = entry.origin {
       // leftKey, rightKey가 구성 Term의 key
       // allEntries에서 이 key로 Term entry를 찾아 fallback 정보 구성
   }
   ```

   **참고**: 새로운 필드 추가 불필요. 기존 `origin` 필드가 Pattern 구성 정보를 이미 포함하고 있음.

2. **NameGlossary 확장**:
   ```swift
   public struct NameGlossary {
       public let target: String
       public let variants: [String]
       public let expectedCount: Int

       // Fallback용 추가 정보
       public struct FallbackTerm: Sendable {
           public let termKey: String  // Term의 key (origin에서 추출)
           public let target: String
           public let variants: [String]
       }
       public let fallbackTerms: [FallbackTerm]?
   }
   ```

3. **정규화 로직 수정** (`normalizeVariantsAndParticles`):
   ```swift
   func normalizeVariantsAndParticles(...) {
       for nameGlossary in nameGlossaries {
           // 1차 시도: Pattern variants
           if let matched = findVariant(in: text, variants: nameGlossary.variants) {
               // nameGlossary.target으로 치환
               continue
           }

           // 2차 시도: Fallback to Term variants
           if let fallbackTerms = nameGlossary.fallbackTerms {
               for fallbackTerm in fallbackTerms {
                   if let matched = findVariant(in: text, variants: fallbackTerm.variants) {
                       // fallbackTerm의 target으로 치환
                       break
                   }
               }
           }
       }
   }
   ```

**엣지 케이스**:

1. **여러 Term이 동시에 매칭**:
   - 원문 등장 순서(SegmentPieces의 pieces 순서)를 우선순위로 사용
   - 또는 가장 긴 Term 우선

2. **Fallback으로 정규화 후 조사 보정**:
   - Fallback으로 치환된 Term의 받침 정보로 조사 보정
   - Pattern의 받침 정보가 아닌 실제 매칭된 Term의 받침 사용

3. **성능 고려**:
   - Fallback은 1차 시도 실패 시에만 실행
   - fallbackTerms는 Pattern entry에만 존재 (일반 entry는 nil)

---

## 7. 성능 고려사항

### 7.1 용어 검색 로직 통합

**현재**:
- `maskWithLocks`: NSRegularExpression으로 각 entry마다 전체 텍스트 스캔
- `makeNameGlossaries`: `contains` 및 `components(separatedBy:)`로 각 entry마다 검색
- 총 2회 처리 (preMask와 비preMask로 분리)

**개선 후**:
- `buildSegmentPieces`: 모든 entry를 한 번에 처리
- `str.contains(entry.source)` 기반 단순 문자열 검색 사용
- 총 1회 처리 (통합)

**성능 특성**:
- ❌ AC 알고리즘 미사용 (현재 스펙 구현 기준)
- ✅ 중복 처리 제거 (maskWithLocks + makeNameGlossaries → buildSegmentPieces)
- ✅ Term 활성화 로직 통합으로 오버헤드 감소
- ⚠️ 최악 케이스 복잡도: O(entries × pieces × text_length)

**예상 성능 개선**:
- 중복 처리 제거로 인한 개선: 약 20-30%
- 실제 성능은 측정 필요 (entry 개수, 텍스트 길이에 따라 가변적)
- 향후 AC 알고리즘 도입 시 추가 개선 가능

### 7.2 메모리 사용량

- `segmentPieces` 추가로 인한 메모리 증가: 세그먼트당 약 200-500 bytes (용어 개수에 비례)
- 대규모 페이지(100+ 세그먼트)에서도 50KB 이하 예상
- 무시할 수 있는 수준

---

## 8. 테스트 전략

### 8.1 단위 테스트

1. **SegmentPieces 생성 테스트**
   - 긴 용어가 짧은 용어를 덮는지 확인
   - Term 활성화 로직 정상 작동 확인
   - filterBySourceOcc 로직 정상 작동 확인

2. **maskFromPieces 테스트**
   - 토큰 생성 정확성
   - LockInfo 생성 정확성
   - 호칭 NBSP 주입 확인

3. **makeNameGlossariesFromPieces 테스트**
   - NameGlossary 생성 정확성
   - expectedCount 정확성
   - variants 중복 제거 확인

### 8.2 통합 테스트

1. **번역 파이프라인 테스트**
   - 기존 번역 결과와 동일한지 확인
   - 다양한 용어 조합으로 테스트
   - 엣지 케이스 (빈 세그먼트, 용어 없음, 모든 용어 마스킹 등)

2. **Term 활성화 시나리오 테스트**
   - Pattern 기반 활성화 정상 작동
   - Term-to-Term 활성화 정상 작동
   - 복합 시나리오 (여러 활성화 방식 조합)

### 8.3 성능 테스트

1. **용어 검색 로직 통합 횟수 측정**
   - 로깅으로 확인
   - 기존: maskWithLocks + makeNameGlossaries (2회 처리)
   - 개선: buildSegmentPieces (1회 통합 처리)
   - 단일 처리로 통합되었는지 검증

2. **전체 번역 시간 측정**
   - 기존 구현 대비 성능 개선 확인
   - 대규모 페이지로 테스트 (100+ 세그먼트)
   - 예상: 중복 처리 제거로 인한 20-30% 개선

---

## 9. 향후 확장 계획

### 9.1 Range 정보 추가 (Phase 7)

**목표**: 각 Piece에 원문에서의 위치 정보 추가

```swift
public enum Piece: Sendable {
    case text(String, range: Range<String.Index>)
    case term(GlossaryEntry, range: Range<String.Index>)
}
```

**활용**:
- 오버레이 패널에서 용어 하이라이트
- 정규화 전/후 원문 비교 UI
- 용어 클릭 시 원문 위치로 스크롤

### 9.2 오버레이 패널 연계 (Phase 8)

**목표**: SegmentPieces 정보를 UI로 전달

```swift
// TranslationResult에 pieces 추가
public struct TranslationResult {
    // ...
    public let pieces: SegmentPieces?  // 추가
}
```

**UI 개선**:
- 감지된 용어를 색상으로 구분 표시
- 마스킹 대상 vs 정규화 대상 구분
- 용어 클릭 시 상세 정보 표시
- 번역 결과 일부를 Term variants로 바로 추가 기능

---

## 10. 구현 체크리스트

### 핵심 구현

- [ ] Phase 1: SegmentPieces.swift 파일 생성 및 타입 정의
- [ ] Phase 2: buildSegmentPieces 메서드 구현
  - [ ] 헬퍼 함수 splitTextBySource 구현
  - [ ] Term 활성화 로직 통합
  - [ ] filterBySourceOcc 통합
  - [ ] Longest-first 알고리즘 구현
- [ ] Phase 3: maskFromPieces 메서드 구현
- [ ] Phase 4: makeNameGlossariesFromPieces 메서드 구현
- [ ] Phase 5: prepareMaskingContext 리팩토링
- [ ] Phase 6: MaskingContext 확장

### Pattern Fallback 구현

- [ ] Phase 6.5: Pattern Fallback 로직 구현
  - [ ] GlossaryEntry에 patternSourceTermIds 필드 추가
  - [ ] NameGlossary에 FallbackTerm 타입 추가
  - [ ] makeNameGlossariesFromPieces에서 fallbackTerms 생성
  - [ ] normalizeVariantsAndParticles에서 Fallback 로직 구현

### 테스트

- [ ] 단위 테스트 작성 및 통과
  - [ ] SegmentPieces 생성 테스트
  - [ ] maskFromPieces 테스트
  - [ ] makeNameGlossariesFromPieces 테스트
  - [ ] Pattern Fallback 시나리오 테스트
- [ ] 통합 테스트 작성 및 통과
  - [ ] 기존 번역 결과와 일치 확인
  - [ ] Pattern Fallback 실제 케이스 테스트
  - [ ] 토큰 개수 변경 영향 확인
- [ ] 성능 테스트 및 측정
  - [ ] 용어 검색 로직 통합 성능 측정
  - [ ] 메모리 사용량 측정

### 마무리

- [ ] 기존 maskWithLocks/makeNameGlossaries deprecated 표시
- [ ] 문서 업데이트 (PROJECT_OVERVIEW.md)
- [ ] TODO.md 업데이트
- [ ] 스펙 문서 최종 리뷰 (Codex 리뷰 반영 확인)

---

## 11. 참고 문서

- `History/SPEC_TERM_ACTIVATION.md`: Term 활성화 로직 스펙
- `PROJECT_OVERVIEW.md`: 프로젝트 아키텍처 개요
- `MyTranslation/Services/Translation/Masking/Masker.swift`: 현재 구현
  - `maskWithLocks()`: 라인 207-279
  - `makeNameGlossaries()`: 라인 575-648
  - `promoteProhibitedEntries()`: Pattern 기반 활성화
  - `promoteActivatedEntries()`: Term-to-Term 활성화
  - `filterBySourceOcc()`: 라인 651-716
- `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`: 라우터 구현
  - `prepareMaskingContext()`: 라인 260-292

---

**작성자**: Claude Code
**최종 수정**: 2025-11-21
