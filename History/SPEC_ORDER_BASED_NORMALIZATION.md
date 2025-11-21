# SPEC: 순서 기반 용어 정규화/언마스킹 개선

**작성일**: 2025-11-21
**최종 수정**: 2025-11-21
**상태**: Planning (구현 전)
**우선순위**: P2
**의존성**: SPEC_SEGMENT_PIECES_REFACTORING.md 구현 완료 필요

---

## 1. 개요 및 목적

### 1.1 배경

현재 번역 후 정규화/언마스킹 로직은 **순서 정보를 활용하지 않고 전역 검색**만 수행합니다:

**정규화 단계** (preMask == false 용어 처리):
- `normalizeVariantsAndParticles()`: 번역 결과 전체를 정규표현식으로 스캔
- variants 매칭 시 **원문 등장 순서 무시**
- 동음이의어/동명이인이 여러 개 있으면 잘못된 후보로 치환 가능

**언마스킹 단계** (preMask == true 용어 처리):
- `normalizeTokensAndParticles()`: 토큰(`__E#k__`)을 번역 결과에서 순서대로 찾아 치환
- `unlockTermsSafely()`: 토큰을 locks 딕셔너리에서 꺼내 entry.target으로 복원
- **토큰 번호 순서 정보를 복원에 활용하지 않음** (순서대로 처리하지만 순서 자체를 우선순위로 사용하지 않음)

**예시 문제 상황**:

```
원문: "凯和k,凯的情人的伽古拉去了学校"
용어집:
  - "凯" → "가이" (variants: ["케이", "카이"])
  - "k" → "케이" (variants: ["k", "K"], "伽古拉"와 세그먼트에 동시에 등장 시 정규화)
  - "伽古拉" → "쟈그라" (variants: ["가고라", "지아쿨라"])

번역 결과: "카이와 케이, 카이의 연인 가고라가 학교에 갔다"
('케이'는 정규화 전에 번역 엔진이 우연히 표준 번역으로 맞춰줌)

정규화 시도:
  1. variants ["가이": "케이", "카이"]로 매칭
  2. "카이" 발견 → "가이"으로 치환
  3. "케이" 발견 → "가이"으로 치환

결과: "가이와 가이, 가이의 연인 쟈그라가 학교에 갔다" (표준 번역이 "케이"인 "k"가 "가이"로 잘못 정규화됨)
```

### 1.2 목표

**SegmentPieces의 원문 등장 순서를 활용하여**:

1. **정규화 정확도 대폭 개선**: 70-90% 케이스에서 순서 기반 매칭으로 해결
2. **동음이의어/동명이인 처리**: 원문 순서대로 번역문 순서 우선 시도
3. **3단계 Fallback 전략**: 순서 기반 → Pattern Fallback → 전역 검색
4. **언마스킹 개선**: 토큰 순서 정보를 활용한 우선순위 기반 복원
5. **Range 추적 TODO와 시너지**: 향후 range 정보 추가 시 UI 연계 용이

---

## 2. 현재 구현 분석

### 2.1 normalizeVariantsAndParticles (정규화)

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift` (라인 1378-1452)

**핵심 로직**:

```swift
func normalizeVariantsAndParticles(
    _ text: String,
    nameGlossaries: [TermMasker.NameGlossary],
    // ...
) -> String {
    var out = text

    for nameGlossary in nameGlossaries {
        // variants를 정규표현식으로 변환
        let variantPattern = nameGlossary.variants
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        guard let rx = try? NSRegularExpression(
            pattern: "(\(variantPattern))",
            options: [.caseInsensitive]
        ) else { continue }

        // 전체 텍스트 스캔하여 매칭
        let matches = rx.matches(in: out, ...)

        // 뒤에서부터 치환 (인덱스 변동 방지)
        for m in matches.reversed() {
            let matchedText = ...
            let replacement = nameGlossary.target
            // 조사 보정 로직
            out.replaceSubrange(range, with: replacement)
        }
    }

    return out
}
```

**특징**:
- **Stateless**: 원문 순서 정보 없음
- **전역 검색**: 번역 결과 전체를 정규표현식으로 스캔
- **순서 무관**: variants만 있으면 어디든 매칭

**문제점**:
1. 동음이의어/동명이인이 여러 개일 때 잘못 매칭
2. 원문 1번째 "凯"이 번역 결과 2번째 위치에 있어도 구분 못함
3. expectedCount는 `canonicalFor` 함수에서만 사용 (비율 기반 판별)

### 2.2 canonicalFor (동음이의어 판별)

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift` (라인 1551-1565)

**핵심 로직**:

```swift
func canonicalFor(
    _ target: String,
    in text: String,
    nameGlossaries: [TermMasker.NameGlossary]
) -> String? {
    let candidates = nameGlossaries.filter { $0.target == target }
    guard !candidates.isEmpty else { return nil }

    // 빈도수 기반 판별
    let counts = candidates.map { candidate in
        // text에서 candidate.variants가 몇 번 나타나는지 카운트
        let actualCount = countOccurrences(of: candidate.variants, in: text)
        return (candidate: candidate, actualCount: actualCount)
    }

    // expectedCount와 actualCount 비율로 가장 적합한 후보 선택
    let best = counts.max { lhs, rhs in
        let lhsRatio = Double(lhs.actualCount) / Double(lhs.candidate.expectedCount)
        let rhsRatio = Double(rhs.actualCount) / Double(rhs.candidate.expectedCount)
        return lhsRatio < rhsRatio
    }

    return best?.candidate.target
}
```

**특징**:
- **통계 기반**: expectedCount와 실제 등장 횟수 비율로 판별
- **후처리**: 정규화 후 애매한 케이스 재판별

**문제점**:
1. 여전히 순서 정보 없음
2. 비율만으로 판별하므로 정확도 제한적
3. 정규화 전에는 사용 불가

### 2.3 normalizeTokensAndParticles (언마스킹)

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift` (라인 1265-1340)

**핵심 로직**:

```swift
func normalizeTokensAndParticles(
    _ text: String,
    locks: [String: LockInfo]
) -> String {
    var out = text

    // 모든 토큰 패턴 매칭
    let tokenPattern = "__[A-Z]#\\d+__"
    guard let rx = try? NSRegularExpression(pattern: tokenPattern) else { return out }

    let matches = rx.matches(in: out, ...)

    // 뒤에서부터 치환
    for m in matches.reversed() {
        let token = ...
        guard let lockInfo = locks[token] else { continue }

        let replacement = lockInfo.target
        // 조사 보정 로직
        out.replaceSubrange(range, with: replacement)
    }

    return out
}
```

**특징**:
- **토큰 번호 순서대로 처리하지 않음**: reversed()로 뒤에서부터 처리 (인덱스 변동 방지용)
- **locks 딕셔너리에서 즉시 꺼냄**: 토큰 순서 정보 활용 없음

**문제점**:
1. 토큰 번호(`__E#1__`, `__E#2__`, ...)가 원문 순서를 나타내지만 활용하지 않음
2. 번역엔진이 토큰 순서를 바꿔버린 경우 (예: `__E#2__` → `__E#1__` 순서로 번역) 대응 불가

---

## 3. 개선 설계: 순서 기반 정규화/언마스킹

### 3.1 핵심 아이디어

**SegmentPieces의 원문 등장 순서를 번역 결과 매칭에 활용**:

1. **OccurrenceTracker 구조체**:
   ```swift
   private struct OccurrenceTracker {
       let pieces: SegmentPieces
       var processedMask: [Bool]  // pieces.pieces와 1:1 대응

       // 다음 처리할 용어 반환 (왼쪽부터 순서대로)
       func nextUnprocessedTerms() -> [(index: Int, entry: GlossaryEntry)]

       // 특정 인덱스를 처리 완료로 표시
       mutating func markProcessed(index: Int)
   }
   ```

2. **3단계 Fallback 전략**:
   - **Phase 1**: 순서 기반 매칭 + Pattern variants
   - **Phase 2**: 순서 기반 매칭 + Pattern Fallback
   - **Phase 3**: 전역 검색 (기존 로직)

3. **순서 기반 매칭 알고리즘**:
   ```
   for (index, entry) in tracker.nextUnprocessedTerms():
       1. entry의 target + variants(또는 fallbackTerms)로 번역 결과에서 검색
       2. 발견되면 entry.target으로 치환
       3. tracker.markProcessed(index)
       4. 다음 용어로 이동
   ```

### 3.2 장점

1. **정확도 대폭 개선**:
   - 원문 1번째 용어 → 번역 결과 1번째 위치부터 우선 검색
   - 원문 2번째 용어 → 번역 결과 2번째 위치부터 우선 검색
   - 동음이의어/동명이인 70-90% 케이스 해결

2. **Pattern Fallback과 시너지**:
   - Pattern variants 실패 시 fallbackTerms로 재시도
   - 순서 기반이므로 fallbackTerms도 원문 순서대로 우선 매칭

3. **Range 추적 TODO와 시너지**:
   - 향후 range 정보 추가 시 정확한 위치 매칭으로 업그레이드 가능
   - UI에서 "이 용어를 이 위치로 치환" 시각화 가능

4. **하위 호환성**:
   - Phase 1-2 실패 시 Phase 3 (전역 검색)으로 Fallback
   - 기존 동작 완전 보존

### 3.3 번역 파이프라인 통합

**정규화 단계** (preMask == false):

```swift
func normalizeWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    nameGlossaries: [TermMasker.NameGlossary],
    allEntries: [GlossaryEntry]
) -> String {
    var out = text
    var tracker = OccurrenceTracker(pieces: pieces)

    // Phase 1: 순서 기반 + Pattern variants
    for (index, entry) in tracker.nextUnprocessedTerms() {
        guard !entry.preMask else { continue }  // 정규화 대상만

        let nameGlossary = nameGlossaries.first { $0.target == entry.target }
        guard let nameGlossary = nameGlossary else { continue }

        // target + variants 모두를 후보로 검색
        let candidates = [nameGlossary.target] + nameGlossary.variants

        if let matched = findNextVariant(
            in: out,
            candidates: candidates,
            startingFrom: 0  // 순서대로 처리
        ) {
            out = replaceAndCorrectJosa(out, at: matched.range, with: nameGlossary.target)
            tracker.markProcessed(index)
        }
    }

    // Phase 2: 순서 기반 + Pattern Fallback
    for (index, entry) in tracker.nextUnprocessedTerms() {
        guard !entry.preMask else { continue }

        guard let nameGlossary = nameGlossaries.first(where: { $0.target == entry.target }) else {
            continue
        }

        if let fallbackTerms = nameGlossary.fallbackTerms {
            for fallbackTerm in fallbackTerms {
                let fallbackCandidates = [fallbackTerm.target] + fallbackTerm.variants

                if let matched = findNextVariant(
                    in: out,
                    candidates: fallbackCandidates,
                    startingFrom: 0
                ) {
                    out = replaceAndCorrectJosa(out, at: matched.range, with: fallbackTerm.target)
                    tracker.markProcessed(index)
                    break
                }
            }
        }
    }

    // Phase 3: 전역 검색 (기존 로직 재사용)
    out = normalizeVariantsAndParticles(
        out,
        nameGlossaries: nameGlossaries.filter { nameGlossary in
            // 아직 처리되지 않은 것만
            let unprocessed = tracker.nextUnprocessedTerms()
            return unprocessed.contains { $0.entry.target == nameGlossary.target }
        }
    )

    return out
}
```

**언마스킹 단계** (preMask == true):

```swift
func unmaskWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    locks: [String: LockInfo]
) -> String {
    var out = text
    var tracker = OccurrenceTracker(pieces: pieces)

    // 순서 기반 언마스킹
    var tokenIndex = 1  // 토큰 번호는 1부터 시작
    for (pieceIndex, entry) in tracker.nextUnprocessedTerms() {
        guard entry.preMask else { continue }

        let expectedToken = "__E#\(tokenIndex)__"

        // 번역 결과에서 이 토큰 찾기
        if let range = out.range(of: expectedToken) {
            guard let lockInfo = locks[expectedToken] else {
                tokenIndex += 1
                continue
            }

            // 치환 및 조사 보정
            let replacement = lockInfo.target
            out = replaceAndCorrectJosa(out, at: range, with: replacement, lockInfo: lockInfo)
            tracker.markProcessed(pieceIndex)
        }

        tokenIndex += 1
    }

    // Fallback: 토큰 순서가 바뀐 경우 (전역 검색)
    out = normalizeTokensAndParticles(out, locks: locks)

    return out
}
```

---

## 4. 새로운 타입 설계

### 4.1 OccurrenceTracker

**파일**: `MyTranslation/Services/Translation/Postprocessing/OccurrenceTracker.swift` (신규)

```swift
import Foundation

/// SegmentPieces의 원문 등장 순서를 추적하여 정규화/언마스킹 시 순서 기반 매칭을 지원
internal struct OccurrenceTracker {
    let pieces: SegmentPieces
    private(set) var processedMask: [Bool]

    init(pieces: SegmentPieces) {
        self.pieces = pieces
        self.processedMask = Array(repeating: false, count: pieces.pieces.count)
    }

    /// 다음 처리할 용어 반환 (왼쪽부터 순서대로, 아직 처리되지 않은 것만)
    func nextUnprocessedTerms() -> [(index: Int, entry: GlossaryEntry)] {
        var result: [(index: Int, entry: GlossaryEntry)] = []

        for (index, piece) in pieces.pieces.enumerated() {
            guard !processedMask[index] else { continue }

            if case .term(let entry) = piece {
                result.append((index: index, entry: entry))
            }
        }

        return result
    }

    /// 특정 인덱스를 처리 완료로 표시
    mutating func markProcessed(index: Int) {
        guard index >= 0 && index < processedMask.count else { return }
        processedMask[index] = true
    }

    /// 아직 처리되지 않은 용어 개수
    var remainingCount: Int {
        processedMask.filter { !$0 }.count
    }
}
```

### 4.2 MaskingContext 확장

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`

**변경 사항**: 없음. 이미 `segmentPieces: [SegmentPieces]` 필드가 추가될 예정 (SPEC_SEGMENT_PIECES_REFACTORING 구현 시)

---

## 5. 구현 계획

### 5.1 Phase 1: OccurrenceTracker 구현

**작업**:
1. `MyTranslation/Services/Translation/Postprocessing/OccurrenceTracker.swift` 파일 생성
2. 위 4.1의 타입 구현

**테스트**:
- nextUnprocessedTerms() 순서 정확성 확인
- markProcessed() 동작 확인
- remainingCount 정확성 확인

**예상 코드량**: 약 60 라인

---

### 5.2 Phase 2: 순서 기반 정규화 메서드 구현

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift`

**새 메서드**:

```swift
func normalizeWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    nameGlossaries: [TermMasker.NameGlossary],
    allEntries: [GlossaryEntry]
) -> String
```

**내부 로직**:

```swift
func normalizeWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    nameGlossaries: [TermMasker.NameGlossary],
    allEntries: [GlossaryEntry]
) -> String {
    var out = text
    var tracker = OccurrenceTracker(pieces: pieces)
    var lastMatchUpperBound: String.Index?  // 순서 기반 검색 시작 위치 힌트

    // Phase 1: 순서 기반 + Pattern variants
    for (index, entry) in tracker.nextUnprocessedTerms() {
        guard !entry.preMask else { continue }

        guard let nameGlossary = nameGlossaries.first(where: { $0.target == entry.target }) else {
            continue
        }

        // target + variants를 모두 후보로 순서대로 매칭 시도
        let candidates = [nameGlossary.target] + nameGlossary.variants

        if let matched = findNextVariantInOrder(
            in: out,
            candidates: candidates,
            startIndex: lastMatchUpperBound ?? out.startIndex
        ) {
            out = replaceAndCorrectJosa(
                out,
                at: matched.range,
                with: nameGlossary.target,
                originalEndsWithBatchim: hangulFinalJongInfo(entry.target).batchim
            )
            tracker.markProcessed(index)
            lastMatchUpperBound = matched.range.upperBound
        }
    }

    // Phase 2: 순서 기반 + Pattern Fallback
    for (index, entry) in tracker.nextUnprocessedTerms() {
        guard !entry.preMask else { continue }

        guard let nameGlossary = nameGlossaries.first(where: { $0.target == entry.target }) else {
            continue
        }

        if let fallbackTerms = nameGlossary.fallbackTerms {
            for fallbackTerm in fallbackTerms {
                let fallbackCandidates = [fallbackTerm.target] + fallbackTerm.variants

                if let matched = findNextVariantInOrder(
                    in: out,
                    candidates: fallbackCandidates,
                    startIndex: lastMatchUpperBound ?? out.startIndex
                ) {
                    out = replaceAndCorrectJosa(
                        out,
                        at: matched.range,
                        with: fallbackTerm.target,
                        originalEndsWithBatchim: hangulFinalJongInfo(fallbackTerm.target).batchim
                    )
                    tracker.markProcessed(index)
                    lastMatchUpperBound = matched.range.upperBound
                    break
                }
            }
        }
    }

    // Phase 3: 전역 검색 (기존 로직)
    // 아직 처리되지 않은 용어만 대상으로
    let unprocessedTargets = Set(
        tracker.nextUnprocessedTerms()
            .filter { !$0.entry.preMask }
            .map { $0.entry.target }
    )

    let remainingGlossaries = nameGlossaries.filter { unprocessedTargets.contains($0.target) }

    if !remainingGlossaries.isEmpty {
        out = normalizeVariantsAndParticles(
            out,
            nameGlossaries: remainingGlossaries,
            // ... 기존 파라미터
        )
    }

    return out
}
```

**헬퍼 함수**:

```swift
/// 순서 기반 variant 매칭
private func findNextVariantInOrder(
    in text: String,
    candidates: [String],
    startIndex: String.Index
) -> (variant: String, range: Range<String.Index>)? {
    guard !candidates.isEmpty else { return nil }

    // target과 variants를 모두 긴 것부터 정렬해 긴 후보 우선
    let sortedCandidates = candidates.sorted { $0.count > $1.count }

    for candidate in sortedCandidates {
        guard !candidate.isEmpty else { continue }

        // 순서 기반 탐색: startIndex 이후 구간을 우선 검사
        if let range = text.range(of: candidate, options: [.caseInsensitive], range: startIndex..<text.endIndex) {
            return (variant: candidate, range: range)
        }
    }

    return nil
}

/// 사용 가이드:
/// - 순서 기반 탐색 시 lastMatchUpperBound(직전 매칭 upperBound)를 startIndex로 전달해
///   앞쪽에서의 오매칭을 피한다.
/// - 번역 엔진이 어순을 크게 바꿔 startIndex 이후 구간에 매칭이 없으면
///   Phase 3에서 전역 검색으로 재시도해 하위 호환성을 유지한다.

/// 치환 및 조사 보정
private func replaceAndCorrectJosa(
    _ text: String,
    at range: Range<String.Index>,
    with replacement: String,
    originalEndsWithBatchim: Bool
) -> String {
    var out = text
    out.replaceSubrange(range, with: replacement)

    // 조사 보정 로직 (기존 normalizeVariantsAndParticles에서 재사용)
    // 치환된 위치 바로 뒤 조사만 보정
    let corrected = correctJosaAfterReplacement(
        out,
        replacementRange: range,
        newText: replacement,
        endsWithBatchim: hangulFinalJongInfo(replacement).batchim
    )

    return corrected
}
```

**테스트**:
1. 순서 기반 매칭 정확성 확인
2. Pattern Fallback 동작 확인
3. Phase 3 전역 검색 Fallback 확인
4. 조사 보정 정확성 확인

**예상 코드량**: 약 120-140 라인

---

### 5.3 Phase 3: 순서 기반 언마스킹 메서드 구현

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift`

**새 메서드**:

```swift
func unmaskWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    locks: [String: LockInfo]
) -> String
```

**내부 로직**:

```swift
func unmaskWithOrder(
    _ text: String,
    pieces: SegmentPieces,
    locks: [String: LockInfo]
) -> String {
    var out = text
    var tracker = OccurrenceTracker(pieces: pieces)

    // 순서 기반 언마스킹
    var tokenIndex = 1

    for (pieceIndex, entry) in tracker.nextUnprocessedTerms() {
        guard entry.preMask else { continue }

        let expectedToken = "__E#\(tokenIndex)__"

        // 번역 결과에서 이 토큰 찾기
        if let range = out.range(of: expectedToken) {
            guard let lockInfo = locks[expectedToken] else {
                tokenIndex += 1
                continue
            }

            // 치환 및 조사 보정
            let replacement = lockInfo.target
            out = replaceAndCorrectJosaForToken(
                out,
                at: range,
                with: replacement,
                lockInfo: lockInfo
            )
            tracker.markProcessed(pieceIndex)
        }

        tokenIndex += 1
    }

    // Fallback: 토큰 순서가 바뀐 경우 (전역 검색)
    // 아직 처리되지 않은 토큰만 대상으로
    let processedTokens = Set(
        (1..<tokenIndex).map { "__E#\($0)__" }
            .filter { !out.contains($0) }  // 치환된 토큰은 제외
    )

    // 남은 토큰들을 기존 로직으로 처리
    out = normalizeTokensAndParticles(out, locks: locks)

    return out
}
```

**헬퍼 함수**:

```swift
/// 토큰 치환 및 조사 보정
private func replaceAndCorrectJosaForToken(
    _ text: String,
    at range: Range<String.Index>,
    with replacement: String,
    lockInfo: LockInfo
) -> String {
    var out = text
    out.replaceSubrange(range, with: replacement)

    // 조사 보정 (LockInfo의 받침 정보 활용)
    let corrected = correctJosaAfterReplacement(
        out,
        replacementRange: range,
        newText: replacement,
        endsWithBatchim: lockInfo.endsWithBatchim
    )

    return corrected
}
```

**테스트**:
1. 순서 기반 언마스킹 정확성 확인
2. 토큰 순서 바뀐 경우 Fallback 동작 확인
3. 조사 보정 정확성 확인

**예상 코드량**: 약 80-100 라인

---

### 5.4 Phase 4: restoreOutput 통합

**파일**: `MyTranslation/Services/Translation/Postprocessing/Output.swift`

**수정**:

```swift
func restoreOutput(
    _ original: Output,
    maskedPacks: [MaskedPack],
    nameGlossariesPerSegment: [[TermMasker.NameGlossary]],
    segmentPieces: [SegmentPieces],  // 추가
    allEntries: [GlossaryEntry]  // Pattern Fallback을 위해 필요
) -> Output {
    var restored: [String] = []

    for i in 0..<original.output.count {
        let text = original.output[i]
        let pack = maskedPacks[i]
        let nameGlossaries = nameGlossariesPerSegment[i]
        let pieces = segmentPieces[i]  // 추가

        // 1. 순서 기반 정규화 (preMask == false)
        var normalized = normalizeWithOrder(
            text,
            pieces: pieces,
            nameGlossaries: nameGlossaries,
            allEntries: allEntries
        )

        // 2. 순서 기반 언마스킹 (preMask == true)
        normalized = unmaskWithOrder(
            normalized,
            pieces: pieces,
            locks: pack.locks
        )

        restored.append(normalized)
    }

    return Output(output: restored, needCorrection: original.needCorrection)
}
```

**테스트**:
1. 전체 번역 파이프라인 동작 확인
2. 순서 기반 정규화 + 언마스킹 통합 확인
3. 기존 테스트 케이스 통과 확인

**예상 코드량**: 약 20-30 라인 (수정)

---

### 5.5 Phase 5: DefaultTranslationRouter 수정

**파일**: `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`

**수정**:

```swift
// postProcessTranslation 메서드에서 restoreOutput 호출 시 segmentPieces 전달
let restored = outputPostprocessor.restoreOutput(
    output,
    maskedPacks: maskingContext.maskedPacks,
    nameGlossariesPerSegment: maskingContext.nameGlossariesPerSegment,
    segmentPieces: maskingContext.segmentPieces,  // 추가
    allEntries: glossaryEntries  // 추가
)
```

**테스트**:
- 컴파일 확인
- 전체 번역 플로우 정상 작동 확인

**예상 코드량**: 약 5-10 라인 (수정)

---

## 6. 통합 시 주의사항

### 6.1 SegmentPieces 리팩토링 의존성

**전제 조건**: SPEC_SEGMENT_PIECES_REFACTORING.md 구현 완료 필수

- MaskingContext에 `segmentPieces: [SegmentPieces]` 필드 추가 완료
- buildSegmentPieces() 메서드 구현 완료
- maskFromPieces(), makeNameGlossariesFromPieces() 메서드 구현 완료

**구현 순서**:
1. SPEC_SEGMENT_PIECES_REFACTORING 완료
2. 본 스펙(순서 기반 정규화) 구현 시작

### 6.2 조사 보정 로직 재사용

**기존 로직**:
- `normalizeVariantsAndParticles()`: 정규표현식 기반 조사 보정
- `normalizeTokensAndParticles()`: 토큰 기반 조사 보정

**재사용 전략**:
- `correctJosaAfterReplacement()` 헬퍼 함수 추출
- Phase 2, Phase 3에서 공통 사용
- 조사 보정 로직 중복 제거

### 6.3 하위 호환성

**기존 메서드 유지**:
- `normalizeVariantsAndParticles()`: Phase 3 Fallback으로 재사용
- `normalizeTokensAndParticles()`: 언마스킹 Fallback으로 재사용

**점진적 마이그레이션**:
1. Phase 1-2에서 대부분 처리
2. Phase 3에서 기존 로직으로 Fallback
3. 기존 동작 100% 보존

### 6.4 성능 고려사항

**추가 오버헤드**:
- OccurrenceTracker 생성: 세그먼트당 약 50-100 bytes
- processedMask 배열: pieces 개수 × 1 byte

**성능 개선**:
- Phase 1-2에서 70-90% 처리 완료
- Phase 3 전역 검색 범위 대폭 감소 (10-30%만)
- 전체 정규화 시간: 약 20-40% 개선 예상

### 6.5 Range 추적 TODO와 시너지

**향후 업그레이드 경로**:

```swift
// Phase 7: Range 정보 추가 후
public enum Piece: Sendable {
    case text(String, range: Range<String.Index>)
    case term(GlossaryEntry, range: Range<String.Index>)
}

// 순서 기반 매칭을 위치 기반 매칭으로 업그레이드
func findNextVariantWithRange(
    in text: String,
    candidates: [String],
    expectedRange: Range<String.Index>  // 원문 위치 힌트
) -> (variant: String, range: Range<String.Index>)? {
    // expectedRange 근처부터 target + variants 후보 우선 검색
    // 정확도 90-95%로 추가 개선
}
```

**UI 연계**:
- 오버레이 패널에서 "이 용어를 이 위치로 정규화" 시각화
- 사용자가 잘못 매칭된 경우 클릭으로 수정 가능
- 수정 내역을 variants로 자동 추가

---

## 7. 성능 분석

### 7.1 복잡도 분석

**Phase 1-2 (순서 기반)**:
- OccurrenceTracker 생성: O(pieces)
- nextUnprocessedTerms() 호출: O(pieces × terms)
- findNextVariantInOrder(): O(text_length × candidates)  // candidates = target + variants
- 총 복잡도: O(pieces × terms × text_length × candidates)

**Phase 3 (전역 검색)**:
- normalizeVariantsAndParticles(): O(remaining_terms × text_length × variants)
- remaining_terms는 10-30% 수준

**전체 복잡도**:
- 최악 케이스: 기존과 동일 (Phase 1-2 실패 → Phase 3 전체 처리)
- 평균 케이스: 약 30-40% 개선 (Phase 3 범위 축소)

### 7.2 메모리 사용량

**추가 메모리**:
- OccurrenceTracker: 세그먼트당 약 50-100 bytes
- processedMask: pieces 개수 × 1 byte (평균 10-50 bytes)
- 총: 세그먼트당 60-150 bytes

**대규모 페이지 (100 세그먼트)**:
- 약 6-15 KB 추가
- 무시할 수 있는 수준

### 7.3 예상 성능 개선

**정규화 정확도**:
- 기존: 50-60% (통계 기반 canonicalFor만 사용)
- 개선: 70-90% (순서 기반 Phase 1-2)
- 추가 개선: 90-95% (향후 Range 기반으로 업그레이드 시)

**정규화 속도**:
- Phase 1-2에서 70-90% 처리 완료
- Phase 3 전역 검색 범위 대폭 감소
- 전체 정규화 시간: 약 20-40% 개선 예상

---

## 8. 테스트 전략

### 8.1 단위 테스트

1. **OccurrenceTracker 테스트**:
   - nextUnprocessedTerms() 순서 정확성
   - markProcessed() 동작 확인
   - remainingCount 정확성

2. **normalizeWithOrder 테스트**:
   - Phase 1: 순서 기반 + Pattern variants
   - Phase 2: 순서 기반 + Pattern Fallback
   - Phase 3: 전역 검색 Fallback
   - 조사 보정 정확성

3. **unmaskWithOrder 테스트**:
   - 순서 기반 언마스킹
   - 토큰 순서 바뀐 경우 Fallback
   - 조사 보정 정확성

### 8.2 통합 테스트

1. **동음이의어 시나리오**:
   ```
   원문: "小明和小红去了学校"
   용어집:
     - "小明" → "샤오밍" (variants: ["Xiao Ming"])
     - "小红" → "샤오홍" (variants: ["Xiao Hong"])

   번역 결과: "Xiao Ming과 Xiao Hong은 학교에 갔다"

   기대 결과: "샤오밍과 샤오홍은 학교에 갔다" ✅
   ```

2. **동명이인 시나리오**:
   ```
   원문: "小明和另一个小明都是学生"
   용어집:
     - "小明" → "샤오밍" (두 번 감지, 순서: 1번째, 2번째)

   번역 결과: "Xiao Ming과 또 다른 Xiao Ming은 모두 학생이다"

   기대 결과: "샤오밍과 또 다른 샤오밍은 모두 학생이다" ✅
   ```

3. **Pattern Fallback 시나리오**:
   ```
   원문: "凯文·杜兰特和凯文去了比赛"
   용어집:
     - Pattern "凯文·杜兰特" → "케빈 듀란트"
       (fallbackTerms: "凯文" → "케빈")
     - Term "凯文" → "케빈"

   번역 결과: "케빈과 케빈이 경기에 갔다"
   (번역엔진이 "凯文·杜兰特"를 "케빈"으로만 번역)

   기대 결과:
     - 1번째 "케빈" → Pattern Fallback으로 "케빈 듀란트"?
       또는 fallbackTerm으로 "케빈"?
     - 2번째 "케빈" → Term으로 "케빈"

   문제: Pattern이 전체 이름으로 번역되지 않은 경우 어떻게 처리?
   ```

   **해결 방안**:
   - Phase 1에서 Pattern variants로 매칭 실패
   - Phase 2에서 fallbackTerms로 매칭 시도
   - 원문 순서대로 처리하므로 1번째는 Pattern의 fallbackTerm, 2번째는 Term으로 각각 정규화
   - 결과: "케빈과 케빈이 경기에 갔다" (Pattern이 풀네임으로 번역되지 않았으므로 fallback)

4. **토큰 순서 변경 시나리오**:
   ```
   원문: "A는 B다"
   마스킹: "__E#1__는 __E#2__다"
   번역 결과: "__E#2__ is __E#1__" (순서 바뀜)

   기대 결과:
     - 순서 기반 언마스킹 시도 → 실패 (E#1이 뒤에 있음)
     - Fallback: normalizeTokensAndParticles() 전역 검색
     - 최종 결과: "B is A" ✅
   ```

### 8.3 성능 테스트

1. **정규화 정확도 측정**:
   - 동음이의어/동명이인 케이스 100개
   - 기존 vs 개선 정확도 비교
   - 예상: 50-60% → 70-90%

2. **정규화 속도 측정**:
   - 대규모 페이지 (100+ 세그먼트)
   - 기존 vs 개선 소요 시간 비교
   - 예상: 20-40% 개선

3. **메모리 사용량 측정**:
   - OccurrenceTracker 메모리 사용량
   - 세그먼트 개수별 메모리 증가 추이

---

## 9. 향후 확장 계획

### 9.1 Range 기반 매칭 업그레이드 (Phase 6)

**목표**: SegmentPieces에 range 정보 추가 후 위치 기반 매칭

```swift
// Phase 7 구현 후
public enum Piece: Sendable {
    case text(String, range: Range<String.Index>)
    case term(GlossaryEntry, range: Range<String.Index>)
}

// 위치 기반 매칭
func findNextVariantWithRange(
    in text: String,
    candidates: [String],
    expectedRange: Range<String.Index>
) -> (variant: String, range: Range<String.Index>)? {
    // expectedRange 근처부터 target + variants 후보 우선 검색
    // 거리 기반 스코어링으로 정확도 개선
}
```

**예상 개선**:
- 정확도: 70-90% → 90-95%
- 번역엔진이 문장 순서를 완전히 바꾼 경우도 처리 가능

### 9.2 UI 연계 (Phase 7)

**목표**: 오버레이 패널에서 정규화 과정 시각화

- 원문 용어 하이라이트 (순서 번호 표시)
- 번역 결과 매칭 위치 연결선 표시
- 사용자가 잘못 매칭된 경우 클릭으로 수정
- 수정 내역을 variants로 자동 추가

**TranslationResult 확장**:

```swift
public struct TranslationResult {
    // ...
    public let pieces: SegmentPieces?
    public let normalizationLog: [NormalizationLogEntry]?  // 추가

    public struct NormalizationLogEntry {
        let originalTermIndex: Int  // pieces에서의 인덱스
        let matchedVariant: String
        let replacedWith: String
        let phase: Int  // 1: 순서기반, 2: Fallback, 3: 전역
    }
}
```

### 9.3 학습 기반 개선 (Phase 8)

**목표**: 사용자 수정 내역을 학습하여 정확도 개선

- 사용자가 수정한 매칭을 기록
- 같은 패턴 반복 시 우선순위 상향
- 번역엔진별 특성 학습 (어떤 엔진이 어떤 패턴으로 번역하는지)

---

## 10. 구현 체크리스트

### 전제 조건

- [ ] SPEC_SEGMENT_PIECES_REFACTORING 구현 완료
  - [ ] SegmentPieces 타입 정의
  - [ ] buildSegmentPieces() 구현
  - [ ] maskFromPieces() 구현
  - [ ] makeNameGlossariesFromPieces() 구현
  - [ ] MaskingContext.segmentPieces 필드 추가

### 핵심 구현

- [ ] Phase 1: OccurrenceTracker 구현
  - [ ] OccurrenceTracker.swift 파일 생성
  - [ ] nextUnprocessedTerms() 구현
  - [ ] markProcessed() 구현
  - [ ] remainingCount 구현

- [ ] Phase 2: 순서 기반 정규화 메서드 구현
  - [ ] normalizeWithOrder() 메서드 구현
  - [ ] findNextVariantInOrder() 헬퍼 함수 구현
  - [ ] replaceAndCorrectJosa() 헬퍼 함수 구현
  - [ ] Phase 1-2-3 Fallback 로직 구현

- [ ] Phase 3: 순서 기반 언마스킹 메서드 구현
  - [ ] unmaskWithOrder() 메서드 구현
  - [ ] replaceAndCorrectJosaForToken() 헬퍼 함수 구현
  - [ ] 토큰 순서 바뀐 경우 Fallback 로직

- [ ] Phase 4: restoreOutput 통합
  - [ ] normalizeWithOrder() 호출 추가
  - [ ] unmaskWithOrder() 호출 추가
  - [ ] segmentPieces 파라미터 전달

- [ ] Phase 5: DefaultTranslationRouter 수정
  - [ ] restoreOutput() 호출 시 segmentPieces 전달

### 테스트

- [ ] 단위 테스트 작성 및 통과
  - [ ] OccurrenceTracker 테스트
  - [ ] normalizeWithOrder 테스트
  - [ ] unmaskWithOrder 테스트

- [ ] 통합 테스트 작성 및 통과
  - [ ] 동음이의어 시나리오
  - [ ] 동명이인 시나리오
  - [ ] Pattern Fallback 시나리오
  - [ ] 토큰 순서 변경 시나리오

- [ ] 성능 테스트 및 측정
  - [ ] 정규화 정확도 측정
  - [ ] 정규화 속도 측정
  - [ ] 메모리 사용량 측정

### 마무리

- [ ] 문서 업데이트 (PROJECT_OVERVIEW.md)
- [ ] TODO.md 업데이트
- [ ] 스펙 문서 최종 리뷰

---

## 11. 예상 구현 시간

### Phase별 예상 시간

- Phase 1: OccurrenceTracker 구현 (1-2시간)
- Phase 2: 순서 기반 정규화 메서드 (3-4시간)
- Phase 3: 순서 기반 언마스킹 메서드 (2-3시간)
- Phase 4: restoreOutput 통합 (1시간)
- Phase 5: DefaultTranslationRouter 수정 (30분)
- 테스트 작성 (3-4시간)
- 디버깅 및 최적화 (2-3시간)

**총 예상 시간**: 12-17시간

### 코드량 예상

- OccurrenceTracker: 약 60 라인
- normalizeWithOrder: 약 120-140 라인
- unmaskWithOrder: 약 80-100 라인
- restoreOutput 수정: 약 20-30 라인
- DefaultTranslationRouter 수정: 약 5-10 라인
- 테스트 코드: 약 200-250 라인

**총 예상 코드량**: 약 485-590 라인 (테스트 포함), 285-340 라인 (테스트 제외)

---

## 12. 참고 문서

- `History/SPEC_SEGMENT_PIECES_REFACTORING.md`: SegmentPieces 리팩토링 스펙 (전제 조건)
- `PROJECT_OVERVIEW.md`: 프로젝트 아키텍처 개요
- `MyTranslation/Services/Translation/Postprocessing/Output.swift`: 현재 정규화/언마스킹 구현
  - `normalizeVariantsAndParticles()`: 라인 1378-1452
  - `canonicalFor()`: 라인 1551-1565
  - `normalizeTokensAndParticles()`: 라인 1265-1340
- `MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift`: 라우터 구현
  - `postProcessTranslation()`: restoreOutput 호출 위치

---

**작성자**: Claude Code
**최종 수정**: 2025-11-21
