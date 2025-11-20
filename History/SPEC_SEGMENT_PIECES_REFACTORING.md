# SPEC: 세그먼트 용어집 감지 로직 리팩토링

**작성일**: 2025-11-20
**상태**: Draft
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

**파일**: `MyTranslation/Services/Translation/Masking/Masker.swift` (라인 584-657)

1. **Term 활성화**:
   - Pattern 기반: `promoteProhibitedEntries()`
   - Term-to-Term: `collectUsedTermKeys()` → `collectActivatedTermKeys()` → `promoteActivatedEntries()`
2. **긴 용어에 덮이는 짧은 용어 제외**: `filterBySourceOcc()`
3. **NameGlossary 생성**: target별로 variants와 expectedCount 집계

**문제점**: maskWithLocks와 별도로 용어를 다시 검색함

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

---

## 3. SegmentPieces 설계 (참고: SegmentPieces.txt)

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
3. **통합된 데이터 구조**: 마스킹/정규화 대상을 모두 포함

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
    let usedKeys = collectUsedTermKeys(from: standaloneEntries)
    let activatedKeys = collectActivatedTermKeys(
        from: allEntries,
        usedKeys: usedKeys
    )
    let termPromoted = promoteActivatedEntries(
        from: allEntries,
        activatedKeys: activatedKeys
    )

    // 4단계: 모든 활성화된 Entry 병합 (중복 제거)
    var combined = standaloneEntries
    combined.append(contentsOf: patternPromoted)
    combined.append(contentsOf: termPromoted)

    var seen: Set<String> = []
    var allowedEntries: [GlossaryEntry] = []
    for entry in combined {
        let key = originKey(entry.origin)
        if seen.insert(key).inserted {
            allowedEntries.append(entry)
        }
    }

    // 5단계: filterBySourceOcc 적용 (현재 세그먼트에서 실제 등장하는 것만)
    let normalizedText = text.precomposedStringWithCompatibilityMapping.lowercased()
    allowedEntries = filterBySourceOcc(normalizedText, allowedEntries)

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
    var tags: [String] = []
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

                // 태그 및 LockInfo 등록
                tags.append(entry.target)
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
    return .init(seg: segment, masked: out, tags: tags, locks: locks)
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
    pieces: SegmentPieces
) -> [NameGlossary]
```

**내부 로직**:

```swift
func makeNameGlossariesFromPieces(
    pieces: SegmentPieces
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
    }

    guard !variantsByTarget.isEmpty else { return [] }

    // NameGlossary 배열 생성 및 정렬
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
            pieces: pieces
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

## 6. 통합 시 주의사항

### 6.1 Term 활성화 로직 보존

- `promoteProhibitedEntries()`: Pattern 기반 활성화 로직 그대로 재사용
- `collectUsedTermKeys()`, `collectActivatedTermKeys()`, `promoteActivatedEntries()`: Term-to-Term 활성화 로직 그대로 재사용
- 기존 활성화 동작과 동일하게 작동하도록 검증

### 6.2 filterBySourceOcc 로직 보존

- `buildSegmentPieces` 5단계에서 filterBySourceOcc 호출
- Longest-first 알고리즘과 함께 사용하여 긴 용어 우선 보장

### 6.3 조사 보정 로직 영향 없음

- `restoreOutput()`의 `normalizeTokensAndParticles()`, `normalizeVariantsAndParticles()` 로직은 그대로 유지
- MaskingContext의 기존 필드들(`maskedPacks`, `nameGlossariesPerSegment`)이 동일하게 생성되므로 영향 없음

### 6.4 하위 호환성

- 기존 `maskWithLocks()`, `makeNameGlossaries()` 메서드는 일단 유지 (deprecated 표시)
- 향후 다른 코드에서 사용하지 않는 것이 확인되면 제거 가능

---

## 7. 성능 고려사항

### 7.1 AC 알고리즘 실행 횟수

**현재**:
- `maskWithLocks`: 1회 (preMask == true 용어만)
- `makeNameGlossaries`: 1회 (모든 용어)
- 총 2회

**개선 후**:
- `buildSegmentPieces`: 1회 (모든 용어)
- 총 1회

**예상 성능 개선**: 약 30-40% (AC 알고리즘이 병목인 경우)

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

1. **AC 알고리즘 실행 횟수 측정**
   - 로깅으로 확인
   - 1회만 실행되는지 검증

2. **전체 번역 시간 측정**
   - 기존 구현 대비 성능 개선 확인
   - 대규모 페이지로 테스트 (100+ 세그먼트)

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
- [ ] 단위 테스트 작성 및 통과
- [ ] 통합 테스트 작성 및 통과
- [ ] 성능 테스트 및 측정
- [ ] 기존 maskWithLocks/makeNameGlossaries deprecated 표시
- [ ] 문서 업데이트 (PROJECT_OVERVIEW.md)
- [ ] TODO.md 업데이트

---

## 11. 참고 문서

- `SegmentPieces.txt`: 원본 아이디어 설명
- `History/SPEC_TERM_ACTIVATION.md`: Term 활성화 로직 스펙
- `PROJECT_OVERVIEW.md`: 프로젝트 아키텍처 개요
- `MyTranslation/Services/Translation/Masking/Masker.swift`: 현재 구현
- `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`: 라우터 구현

---

**작성자**: Claude Code
**최종 수정**: 2025-11-20
