# SPEC: Phase 4 개선 - 실제 매칭 변형 추적 및 1글자 변형 필터링

**작성일:** 2025-11-24
**최종 수정일:** 2025-11-24
**상태:** 제안됨 (Proposed)
**우선순위:** P1 (높음 - Phase 4 오정규화 위험 방지)
**관련 버그:** BUG-004
**의존성:**
- SPEC_PHASE4_RESIDUAL_BATCH_REPLACEMENT.md (구현 완료)
- 현재 Phase 4 구현 (Masker.swift:1336-1430)

**주요 목표:**
- Phase 4에서 1글자 변형으로 인한 오정규화 방지 (예: "오" → "울트라늘은" 오염)
- 실제 매칭 성공한 변형만 Phase 4에서 재사용
- 기존 순차 정규화의 보수적 접근 철학 유지

---

## 목차

1. [문제 요약](#1-문제-요약)
2. [현재 Phase 4 구현 분석](#2-현재-phase-4-구현-분석)
3. [제안하는 개선: 2-패스 전략](#3-제안하는-개선-2-패스-전략)
4. [상세 구현 설계](#4-상세-구현-설계)
5. [Phase 1-3 수정사항](#5-phase-1-3-수정사항)
6. [Phase 4 수정사항](#6-phase-4-수정사항)
7. [엣지 케이스 및 처리 전략](#7-엣지-케이스-및-처리-전략)
8. [테스트 전략](#8-테스트-전략)
9. [성능 고려사항](#9-성능-고려사항)
10. [기존 코드와의 통합 지점](#10-기존-코드와의-통합-지점)
11. [위험 분석](#11-위험-분석)
12. [구현 체크리스트](#12-구현-체크리스트)
13. [성공 기준](#13-성공-기준)
14. [향후 개선 방향](#14-향후-개선-방향)

---

## 1. 문제 요약

### 1.1 Phase 4의 원래 목적

Phase 4는 번역 엔진이 **원문보다 더 많은 용어 인스턴스를 추가**하는 경우를 처리하기 위해 도입되었습니다.

**시나리오:**
```
원문: "伽古拉对红凯说，他今天心情很好，所以放过你一次。" (伽古拉 × 1회, 红凯 × 1회)
번역: "가고라는 홍카이에게 가고라가 오늘 기분이 좋아서 한 번 봐주겠다고 했어요.‘" (가고라 × 2회, 홍카이 × 1회)
→ Phase 1: "가고라", "홍카이" 1회씩 정규화
→ Phase 4: 남은 "가고라" → "쟈그라" 추가 정규화 필요
```

### 1.2 현재 Phase 4의 문제

현재 구현([Masker.swift:1336-1430](../MyTranslation/Services/Translation/Masking/Masker.swift#L1336-L1430))은 **모든 변형을 무차별적으로 재검색**합니다:

```swift
// 현재 Phase 4 로직
for targetName in processedTargets {
    guard let name = nameByTarget[targetName] else { continue }

    // ❌ 문제: entry.variants 전체를 사용
    handleVariants(name.variants, replacement: name.target, entry: entry)

    if let fallbacks = name.fallbackTerms {
        for fallback in fallbacks {
            // ❌ 문제: fallback.variants 전체를 사용
            handleVariants(fallback.variants, replacement: fallback.target, entry: entry)
        }
    }
}
```

**문제점:**
1. **Phase 1-3에서 사용되지 않은 변형도 검색됨**
   - 예: Phase 1에서 "가고라"로 매칭 → Phase 4에서 "가굴라"도 검색
   - 번역 엔진이 같은 세그먼트에서 다른 변형을 사용할 가능성은 매우 낮음

2. **1글자 변형이 무관한 텍스트를 오염시킴** (핵심 문제)
   - 예: 용어집 `奥` → target: "울트라", variants: ["오"]
   - Phase 1에서 "오" 매칭해서 "울트라"로 정규화 성공
   - Phase 4에서 variants 전체 재검색 → **"오"가 다른 곳에서도 검색됨**
   - "오늘은 날씨가" → "울트라늘은 날씨가" ❌

### 1.3 순차 정규화의 원래 철학

순차 정규화는 **짧은 변형(특히 1글자)의 오정규화를 방지**하기 위해 설계되었습니다:

> "세그먼트 전체를 대상으로 검출하기에는 위험한 한 글자짜리 짧은 변형도 가급적 정규화를 포기하고 싶지 않으므로, **순차 정규화를 통해 해당 원문이 등장하는 것과 동일한 위치에서만 정규화 대상을 찾아** 원문이 등장하는 것과 같은 횟수만 정규화하면 올바르게 정규화할 수 있을 가능성이 높아질 것이다."

**Phase 4는 이 철학을 무효화시킵니다:**
- Phase 4는 "남은 영역 전체"를 재스캔
- 1글자 변형이 다시 활성화됨
- 순차 정규화의 보호가 롤백됨 ❌

---

## 2. 현재 Phase 4 구현 분석

### 2.1 코드 구조

**위치:** [Masker.swift:1336-1430](../MyTranslation/Services/Translation/Masking/Masker.swift#L1336-L1430)

```swift
// Phase 4: 잔여 일괄 교체 (보호 범위 포함)
struct OffsetRange {
    let entry: GlossaryEntry
    var nsRange: NSRange
    let type: TermRange.TermType
}

var normalizedOffsets: [OffsetRange] = ranges.compactMap { termRange in
    guard let nsRange = NSRange(termRange.range, in: out) else { return nil }
    return OffsetRange(entry: termRange.entry, nsRange: nsRange, type: termRange.type)
}
var protectedRanges: [NSRange] = normalizedOffsets.map { $0.nsRange }

// Phase 1-3에서 처리된 target 수집
let processedTargetsFromOffsets = normalizedOffsets.map { $0.entry.target }
let processedTargetsFromProcessed = processed.compactMap { idx -> String? in
    guard idx < pieces.pieces.count else { return nil }
    guard case .term(let entry, _) = pieces.pieces[idx] else { return nil }
    return entry.target
}
let processedTargets = Set(processedTargetsFromOffsets + processedTargetsFromProcessed)

func overlapsProtected(_ range: NSRange) -> Bool {
    return protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
}

func shiftRanges(after position: Int, delta: Int) {
    guard delta != 0 else { return }
    for idx in normalizedOffsets.indices where normalizedOffsets[idx].nsRange.location >= position {
        normalizedOffsets[idx].nsRange.location += delta
    }
    for idx in protectedRanges.indices where protectedRanges[idx].location >= position {
        protectedRanges[idx].location += delta
    }
}

func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry) {
    let sorted = variants.sorted { $0.count > $1.count }
    for variant in sorted where variant.isEmpty == false {
        var matches: [NSRange] = []
        var searchStart = out.startIndex

        while searchStart < out.endIndex,
              let found = out.range(of: variant, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
            let nsRange = NSRange(found, in: out)
            if overlapsProtected(nsRange) == false {  // ✅ 보호 범위 체크
                matches.append(nsRange)
            }
            searchStart = found.upperBound
        }

        for nsRange in matches.reversed() {
            guard let swiftRange = Range(nsRange, in: out) else { continue }
            let before = out
            let result = replaceWithParticleFix(in: out, range: swiftRange, replacement: replacement)
            let delta = (result.text as NSString).length - (before as NSString).length
            out = result.text
            if delta != 0 {
                let threshold = nsRange.location + nsRange.length
                shiftRanges(after: threshold, delta: delta)
            }
            if let replacedRange = result.replacedRange,
               let nsReplaced = NSRange(replacedRange, in: out) {
                normalizedOffsets.append(.init(entry: entry, nsRange: nsReplaced, type: .normalized))
                protectedRanges.append(nsReplaced)
            }
        }
    }
}

// ❌ 핵심 문제: 모든 variants를 무차별 검색
for targetName in processedTargets {
    guard let name = nameByTarget[targetName],
          let entry = entryByTarget[targetName] else { continue }

    handleVariants(name.variants, replacement: name.target, entry: entry)

    if let fallbacks = name.fallbackTerms {
        for fallback in fallbacks {
            handleVariants(fallback.variants, replacement: fallback.target, entry: entry)
        }
    }
}
```

### 2.2 현재 보호 메커니즘

**✅ 이미 구현된 보호:**
1. **동음이의어 보호:** `overlapsProtected()` - Phase 1-3 정규화 범위와 겹치는 매칭 제외
2. **NSRange 기반 안정성:** 문자열 변형 중에도 범위 추적 가능
3. **델타 추적:** `shiftRanges()` - 문자열 길이 변화 반영

**❌ 부족한 보호:**
1. **실제 사용된 변형 필터링 없음:** Phase 1-3에서 사용되지 않은 변형도 검색
2. **1글자 변형 필터링 없음:** 짧은 변형이 무관한 텍스트를 오염

---

## 3. 제안하는 개선: 2-패스 전략

### 3.1 핵심 아이디어

**1단계 (Phase 1-3): 순차 정규화 + 매칭 변형 기록**
- 기존 순차 정규화 로직 유지
- 추가: **실제로 매칭된 변형 문자열 기록**
- 데이터: `matchedVariantsByTarget: [String: Set<String>]`

**2단계 (Phase 4): 기록된 변형만 재사용 + 1글자 필터링**
- 기록된 변형만 검색 (`matchedVariantsByTarget` 조회)
- 1글자 변형 제외 (`variant.count > 1`)
- 보호 범위 체크 (기존 로직 유지)

### 3.2 2-패스 알고리즘 흐름도

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1-3: 순차 정규화 (1차 패스)                            │
├─────────────────────────────────────────────────────────────┤
│ 입력: originalText, translatedText, entries                  │
│                                                              │
│ 1. Phase 1: target + variants 순차 매칭                      │
│    - 원문 등장 순서대로 번역문에서 변형 검색                    │
│    - 매칭 성공 시:                                            │
│      • 정규화 수행 (target으로 교체)                           │
│      • processed에 인덱스 기록                                 │
│      • ranges에 범위 추가                                      │
│      • ✨ matchedVariantsByTarget에 변형 기록                 │
│        matchedVariantsByTarget[entry.target].insert(matched) │
│                                                              │
│ 2. Phase 2: fallback 용어 순차 매칭                           │
│    - Phase 1 실패 시 fallback 용어로 재시도                    │
│    - 매칭 성공 시 동일하게 기록                                 │
│                                                              │
│ 3. Phase 3: 전역 검색 (남은 용어)                             │
│    - Phase 1-2 실패한 용어들을 전역 검색                        │
│    - 매칭 성공 시 동일하게 기록                                 │
│                                                              │
│ 출력: normalizedText, ranges, matchedVariantsByTarget        │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 4: 잔여 재스캔 정규화 (2차 패스)                        │
├─────────────────────────────────────────────────────────────┤
│ 입력: normalizedText (1차 패스 결과)                          │
│       matchedVariantsByTarget (1차에서 성공한 변형들)        │
│       protectedRanges (1차 정규화 범위들)                     │
│                                                              │
│ 1. processedTargets 순회                                    │
│    for target in processedTargets:                           │
│                                                              │
│ 2. 실제 매칭된 변형만 가져오기                                  │
│    guard let matchedVariants =                               │
│        matchedVariantsByTarget[target] else { continue }     │
│                                                              │
│ 3. 필터링 조건 적용:                                           │
│    for variant in matchedVariants:                           │
│      ✅ 조건 1: matchedVariants에 포함 (기본 충족)             │
│      ✅ 조건 2: variant.count > 1 (1글자 제외)                │
│      ✅ 조건 3: !overlapsProtected(range)                     │
│                                                              │
│ 4. 조건 만족 시 정규화 수행                                     │
│    - replaceWithParticleFix() 호출                           │
│    - 범위 추적 및 델타 조정                                     │
│                                                              │
│ 출력: finalNormalizedText, finalRanges                       │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 예시: 1글자 변형 필터링

**시나리오:**
```
용어집:
- source: "奥", target: "울트라", variants: ["오", "오쿠", "올림픽"]
- source: "赛罗", target: "제로", variants: ["셀로", "세로", "사이로"]

원문: "今天，赛罗再次看着那个可怜的奥特曼，叹了口气。" (赛罗 × 1회, 奥 × 1회)
정규화 전 번역: "오늘도 사이로는 그 한심한 오를 바라보고 한숨을 쉬었다."
기대 정규화 결과: "오늘도 제로는 그 한심한 울트라를 바라보고 한숨을 쉬었다."
```

**1차 패스 (Phase 1):**
```swift
out = "오늘도 제로는 그 한심한 울트라를 바라보고 한숨을 쉬었다."  // 정규화 완료
matchedVariantsByTarget["울트라"] = ["오"]  // ✅ 실제 사용된 변형만 기록
protectedRanges = [NSRange(0, 1)]  // "울트라" 보호
```

**2차 패스 (Phase 4):**
```swift
// processedTargets = ["오"]
// matchedVariants = ["오"]  // ← "오"가 포함됨

for variant in matchedVariants:  // ["오"]
    // variant = "오"
    // variant.count > 1 (1글자)
    // 검색 수행 안 함→ "오늘은"에서 "오" 매칭 안 됨

// 결과: "오늘은"이 보호됨 ✅
```

**기존 Phase 4 동작 (문제):**
```swift
// variants = ["오브", "울트라맨 오브", "오"]  // ← "오"도 포함!

for variant in variants:
    // variant = "오"
    // ❌ 1글자 필터링 없음
    // 검색 수행 → "오늘은"의 "오" 매칭
    // "오늘은" → "울트라맨 오브늘은" ❌
```

### 3.4 예시: 실제 매칭 변형만 재사용

**시나리오:**
```
용어집:
- source: "伽古拉", target: "쟈그라", variants: ["가고라", "가굴라", "Juggler"]

원문: "伽古拉が登場" (伽古拉 × 1회)
번역: "가고라가 등장, 가고라는 강하다"
```

**1차 패스 (Phase 1):**
```swift
// candidates = ["쟈그라", "가고라", "가굴라", "Juggler"]
// findNextCandidate() → "가고라" 매칭

out = "쟈그라가 등장, 가고라는 강하다"
matchedVariantsByTarget["쟈그라"] = ["가고라"]  // ✅ "가고라"만 기록
protectedRanges = [NSRange(0, 3)]  // "쟈그라" 보호
```

**2차 패스 (Phase 4):**
```swift
// matchedVariants = ["가고라"]  // ← "가굴라", "Juggler"는 제외

for variant in matchedVariants:  // ["가고라"]
    // variant = "가고라"
    // ✅ variant.count > 1 (3글자)
    // 검색 수행 → "가고라는"에서 "가고라" 매칭
    // "가고라는" → "쟈그라는" ✅

// 결과: 같은 변형("가고라")만 추가 정규화 ✅
```

**번역 엔진이 "가굴라"를 사용한 경우 (희귀):**
```
번역: "가고라가 등장, 가굴라는 강하다"
```
- Phase 1: "가고라" 매칭 → `matchedVariants = ["가고라"]`
- Phase 4: "가굴라"는 `matchedVariants`에 없음 → 정규화 안 됨
- **의도적 설계:** 번역 엔진이 같은 세그먼트에서 다른 변형을 사용할 가능성은 매우 낮음
- 만약 정규화가 필요하면 사용자가 용어집에 추가 인스턴스를 명시해야 함

---

## 4. 상세 구현 설계

### 4.1 새로운 데이터 구조

**위치:** `normalizeWithOrder()` 함수 내부 ([Masker.swift:1199](../MyTranslation/Services/Translation/Masking/Masker.swift#L1199))

```swift
func normalizeWithOrder(
    in text: String,
    pieces: SegmentPieces,
    nameGlossaries: [NameGlossary]
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange]) {
    // 기존 변수들...
    var processed: Set<Int> = []
    var lastMatchUpperBound: String.Index? = nil
    var phase2LastMatch: String.Index? = nil
    var cumulativeDelta: Int = 0

    // ✨ 새로운 추가: 실제 매칭된 변형 추적
    // Key: entry.target (예: "쟈그라")
    // Value: 실제로 매칭된 변형들 (예: ["가고라"])
    var matchedVariantsByTarget: [String: Set<String>] = [:]

    // ... 나머지 코드
}
```

**타입 설명:**
- `matchedVariantsByTarget`: `[String: Set<String>]`
  - Key: `GlossaryEntry.target` (정규화 결과 문자열)
  - Value: `Set<String>` (실제로 매칭된 변형 문자열들)
  - `Set` 사용 이유: 중복 제거, 순서 불필요

**예시 데이터:**
```swift
matchedVariantsByTarget = [
    "쟈그라": ["가고라"],
    "홍카이": ["호카이", "Hokai"],
    "오": ["울트라맨 오브"],
    "듀란트": ["듀란테"]
]
```

### 4.2 헬퍼 함수: 매칭 변형 기록

Phase 1-3에서 매칭 성공 시 변형을 기록하는 헬퍼 함수:

```swift
// normalizeWithOrder() 내부에 추가
private func recordMatchedVariant(target: String, variant: String, in dict: inout [String: Set<String>]) {
    if dict[target] != nil {
        dict[target]?.insert(variant)
    } else {
        dict[target] = [variant]
    }
}
```

**사용 위치:**
1. Phase 1 매칭 성공 시
2. Phase 2 매칭 성공 시
3. Phase 3 매칭 성공 시

---

## 5. Phase 1-3 수정사항

### 5.1 Phase 1: target + variants 순차 매칭

**위치:** [Masker.swift:1228-1265](../MyTranslation/Services/Translation/Masking/Masker.swift#L1228-L1265)

**현재 코드:**
```swift
// Phase 1: target + variants 순서 기반 매칭
for (index, entry) in unmaskedTerms {
    guard let name = nameByTarget[entry.target] else { continue }
    let candidates = makeCandidates(target: name.target, variants: name.variants)
    guard let matched = findNextCandidate(
        in: out,
        candidates: candidates,
        startIndex: lastMatchUpperBound ?? out.startIndex
    ) else { continue }

    // ... 정규화 수행 ...

    processed.insert(index)
}
```

**수정 후:**
```swift
// Phase 1: target + variants 순서 기반 매칭
for (index, entry) in unmaskedTerms {
    guard let name = nameByTarget[entry.target] else { continue }
    let candidates = makeCandidates(target: name.target, variants: name.variants)
    guard let matched = findNextCandidate(
        in: out,
        candidates: candidates,
        startIndex: lastMatchUpperBound ?? out.startIndex
    ) else { continue }

    // ✨ 새로운 추가: 매칭된 변형 기록
    recordMatchedVariant(target: entry.target, variant: matched.candidate, in: &matchedVariantsByTarget)

    let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
    let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
    let originalLower = lowerOffset - cumulativeDelta
    if originalLower >= 0, originalLower + oldLen <= original.count {
        let lower = original.index(original.startIndex, offsetBy: originalLower)
        let upper = original.index(lower, offsetBy: oldLen)
        preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
    }

    let result = replaceWithParticleFix(
        in: out,
        range: matched.range,
        replacement: name.target
    )
    out = result.text
    lastMatchUpperBound = result.nextIndex
    if let range = result.replacedRange {
        ranges.append(.init(entry: entry, range: range, type: .normalized))
    }
    let newLen: Int
    if let replacedRange = result.replacedRange {
        newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
    } else {
        newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
    }
    cumulativeDelta += (newLen - oldLen)
    processed.insert(index)
}
```

**변경점:**
- `matched.candidate`가 실제로 매칭된 변형 문자열
- `recordMatchedVariant()` 호출 추가 (정규화 수행 전에 기록)

### 5.2 Phase 2: fallback 용어 순차 매칭

**위치:** [Masker.swift:1267-1309](../MyTranslation/Services/Translation/Masking/Masker.swift#L1267-L1309)

**현재 코드:**
```swift
// Phase 2: Pattern fallback 순서 기반 매칭
for (index, entry) in unmaskedTerms where processed.contains(index) == false {
    guard let name = nameByTarget[entry.target],
          let fallbacks = name.fallbackTerms else { continue }

    for fallback in fallbacks {
        let candidates = makeCandidates(target: fallback.target, variants: fallback.variants)
        guard let matched = findNextCandidate(
            in: out,
            candidates: candidates,
            startIndex: phase2LastMatch ?? out.startIndex
        ) else { continue }

        // ... 정규화 수행 ...

        processed.insert(index)
        break
    }
}
```

**수정 후:**
```swift
// Phase 2: Pattern fallback 순서 기반 매칭
for (index, entry) in unmaskedTerms where processed.contains(index) == false {
    guard let name = nameByTarget[entry.target],
          let fallbacks = name.fallbackTerms else { continue }

    for fallback in fallbacks {
        let candidates = makeCandidates(target: fallback.target, variants: fallback.variants)
        guard let matched = findNextCandidate(
            in: out,
            candidates: candidates,
            startIndex: phase2LastMatch ?? out.startIndex
        ) else { continue }

        // ✨ 새로운 추가: 매칭된 변형 기록
        // 주의: entry.target을 키로 사용 (fallback.target 아님!)
        recordMatchedVariant(target: entry.target, variant: matched.candidate, in: &matchedVariantsByTarget)

        let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
        let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
        let originalLower = lowerOffset - cumulativeDelta
        if originalLower >= 0, originalLower + oldLen <= original.count {
            let lower = original.index(original.startIndex, offsetBy: originalLower)
            let upper = original.index(lower, offsetBy: oldLen)
            preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
        }

        let result = replaceWithParticleFix(
            in: out,
            range: matched.range,
            replacement: fallback.target
        )
        out = result.text
        phase2LastMatch = result.nextIndex
        if let range = result.replacedRange {
            ranges.append(.init(entry: entry, range: range, type: .normalized))
        }
        let newLen: Int
        if let replacedRange = result.replacedRange {
            newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
        } else {
            newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
        }
        cumulativeDelta += (newLen - oldLen)
        processed.insert(index)
        break
    }
}
```

**변경점:**
- `recordMatchedVariant()` 호출 추가
- **중요:** `entry.target`을 키로 사용 (fallback의 target이 아님!)
  - 이유: Phase 4에서 `entry.target`으로 조회하기 때문

### 5.3 Phase 3: 전역 검색

Phase 3는 `normalizeVariantsAndParticles()` 함수를 호출하므로, 해당 함수도 수정이 필요합니다.

**위치:** [Masker.swift:1311-1334](../MyTranslation/Services/Translation/Masking/Masker.swift#L1311-L1334)

**현재 코드:**
```swift
// Phase 3: 전역 검색 Fallback (기존 로직 재사용)
let remainingTargets = Set(
    unmaskedTerms
        .filter { processed.contains($0.index) == false }
        .map { $0.entry.target }
)
let remainingGlossaries = nameGlossaries.filter { remainingTargets.contains($0.target) }
if remainingGlossaries.isEmpty == false {
    let mappedEntries = remainingGlossaries.compactMap { g -> (NameGlossary, GlossaryEntry)? in
        guard let entry = entryByTarget[g.target] else { return nil }
        return (g, entry)
    }
    if mappedEntries.isEmpty == false {
        let result = normalizeVariantsAndParticles(
            in: out,
            entries: mappedEntries,
            baseText: original,
            cumulativeDelta: cumulativeDelta
        )
        out = result.text
        ranges.append(contentsOf: result.ranges)
        preNormalizedRanges.append(contentsOf: result.preNormalizedRanges)
    }
}
```

**수정 후:**
```swift
// Phase 3: 전역 검색 Fallback (기존 로직 재사용)
let remainingTargets = Set(
    unmaskedTerms
        .filter { processed.contains($0.index) == false }
        .map { $0.entry.target }
)
let remainingGlossaries = nameGlossaries.filter { remainingTargets.contains($0.target) }
if remainingGlossaries.isEmpty == false {
    let mappedEntries = remainingGlossaries.compactMap { g -> (NameGlossary, GlossaryEntry)? in
        guard let entry = entryByTarget[g.target] else { return nil }
        return (g, entry)
    }
    if mappedEntries.isEmpty == false {
        let result = normalizeVariantsAndParticles(
            in: out,
            entries: mappedEntries,
            baseText: original,
            cumulativeDelta: cumulativeDelta
        )
        out = result.text
        ranges.append(contentsOf: result.ranges)
        preNormalizedRanges.append(contentsOf: result.preNormalizedRanges)

        // ✨ 새로운 추가: Phase 3 매칭 변형 기록
        // normalizeVariantsAndParticles()가 matchedVariants를 반환하도록 수정 필요
        for (target, variants) in result.matchedVariants {
            for variant in variants {
                recordMatchedVariant(target: target, variant: variant, in: &matchedVariantsByTarget)
            }
        }
    }
}
```

**`normalizeVariantsAndParticles()` 함수 수정 필요:**

현재 반환 타입:
```swift
func normalizeVariantsAndParticles(
    in text: String,
    entries: [(NameGlossary, GlossaryEntry)],
    baseText: String,
    cumulativeDelta: Int
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange])
```

수정 후 반환 타입:
```swift
func normalizeVariantsAndParticles(
    in text: String,
    entries: [(NameGlossary, GlossaryEntry)],
    baseText: String,
    cumulativeDelta: Int
) -> (
    text: String,
    ranges: [TermRange],
    preNormalizedRanges: [TermRange],
    matchedVariants: [String: Set<String>]  // ✨ 추가
)
```

**함수 내부 수정:**
- `normalizeVariantsAndParticles()` 내부에서도 `matchedVariants` 딕셔너리를 유지
- 각 매칭 성공 시 `matchedVariants[entry.target].insert(variant)` 호출
- 반환 시 `matchedVariants` 포함

---

## 6. Phase 4 수정사항

### 6.1 현재 Phase 4 구조

**위치:** [Masker.swift:1336-1430](../MyTranslation/Services/Translation/Masking/Masker.swift#L1336-L1430)

**현재 로직:**
```swift
// Phase 4: 잔여 일괄 교체 (보호 범위 포함)

// 1. 보호 범위 및 처리된 target 수집
var normalizedOffsets: [OffsetRange] = ...
var protectedRanges: [NSRange] = ...
let processedTargets = Set(processedTargetsFromOffsets + processedTargetsFromProcessed)

// 2. handleVariants 헬퍼 함수 (변형 검색 및 교체)
func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry) {
    let sorted = variants.sorted { $0.count > $1.count }
    for variant in sorted where variant.isEmpty == false {
        // 검색 및 교체 로직...
    }
}

// 3. processedTargets 순회
for targetName in processedTargets {
    guard let name = nameByTarget[targetName],
          let entry = entryByTarget[targetName] else { continue }

    // ❌ 문제: 모든 variants 사용
    handleVariants(name.variants, replacement: name.target, entry: entry)

    if let fallbacks = name.fallbackTerms {
        for fallback in fallbacks {
            // ❌ 문제: 모든 fallback.variants 사용
            handleVariants(fallback.variants, replacement: fallback.target, entry: entry)
        }
    }
}
```

### 6.2 수정된 Phase 4 구조

**핵심 변경:**
1. `handleVariants()` 호출 시 **모든 variants 대신 matchedVariants만 전달**
2. `handleVariants()` 내부에서 **1글자 변형 필터링 추가**

**수정된 코드:**
```swift
// Phase 4: 잔여 일괄 교체 (보호 범위 포함)

// 1. 보호 범위 및 처리된 target 수집 (기존 동일)
struct OffsetRange {
    let entry: GlossaryEntry
    var nsRange: NSRange
    let type: TermRange.TermType
}

var normalizedOffsets: [OffsetRange] = ranges.compactMap { termRange in
    guard let nsRange = NSRange(termRange.range, in: out) else { return nil }
    return OffsetRange(entry: termRange.entry, nsRange: nsRange, type: termRange.type)
}
var protectedRanges: [NSRange] = normalizedOffsets.map { $0.nsRange }

let processedTargetsFromOffsets = normalizedOffsets.map { $0.entry.target }
let processedTargetsFromProcessed = processed.compactMap { idx -> String? in
    guard idx < pieces.pieces.count else { return nil }
    guard case .term(let entry, _) = pieces.pieces[idx] else { return nil }
    return entry.target
}
let processedTargets = Set(processedTargetsFromOffsets + processedTargetsFromProcessed)

func overlapsProtected(_ range: NSRange) -> Bool {
    return protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
}

func shiftRanges(after position: Int, delta: Int) {
    guard delta != 0 else { return }
    for idx in normalizedOffsets.indices where normalizedOffsets[idx].nsRange.location >= position {
        normalizedOffsets[idx].nsRange.location += delta
    }
    for idx in protectedRanges.indices where protectedRanges[idx].location >= position {
        protectedRanges[idx].location += delta
    }
}

// 2. handleVariants 헬퍼 함수 수정
func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry) {
    let sorted = variants.sorted { $0.count > $1.count }
    for variant in sorted where variant.isEmpty == false {
        // ✨ 새로운 추가: 1글자 변형 필터링
        guard variant.count > 1 else { continue }

        var matches: [NSRange] = []
        var searchStart = out.startIndex

        while searchStart < out.endIndex,
              let found = out.range(of: variant, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
            let nsRange = NSRange(found, in: out)
            if overlapsProtected(nsRange) == false {
                matches.append(nsRange)
            }
            searchStart = found.upperBound
        }

        for nsRange in matches.reversed() {
            guard let swiftRange = Range(nsRange, in: out) else { continue }
            let before = out
            let result = replaceWithParticleFix(
                in: out,
                range: swiftRange,
                replacement: replacement
            )
            let delta = (result.text as NSString).length - (before as NSString).length
            out = result.text
            if delta != 0 {
                let threshold = nsRange.location + nsRange.length
                shiftRanges(after: threshold, delta: delta)
            }
            if let replacedRange = result.replacedRange,
               let nsReplaced = NSRange(replacedRange, in: out) {
                normalizedOffsets.append(.init(entry: entry, nsRange: nsReplaced, type: .normalized))
                protectedRanges.append(nsReplaced)
            }
        }
    }
}

// 3. processedTargets 순회 (수정)
for targetName in processedTargets {
    guard let name = nameByTarget[targetName],
          let entry = entryByTarget[targetName] else { continue }

    // ✨ 핵심 변경: matchedVariantsByTarget에서 실제 사용된 변형만 가져오기
    if let matchedVariants = matchedVariantsByTarget[targetName] {
        // matchedVariants는 Set<String>이므로 Array로 변환
        handleVariants(Array(matchedVariants), replacement: name.target, entry: entry)
    }

    // fallback 용어 처리
    if let fallbacks = name.fallbackTerms {
        for fallback in fallbacks {
            // ✨ 핵심 변경: matchedVariantsByTarget에서 실제 사용된 변형만 가져오기
            // 주의: fallback의 매칭 변형도 entry.target 키로 저장되어 있음
            if let matchedVariants = matchedVariantsByTarget[targetName] {
                // fallback.target과 fallback.variants를 교차 확인
                let fallbackVariantsSet = Set([fallback.target] + fallback.variants)
                let matchedFallbackVariants = matchedVariants.intersection(fallbackVariantsSet)

                if matchedFallbackVariants.isEmpty == false {
                    handleVariants(Array(matchedFallbackVariants), replacement: fallback.target, entry: entry)
                }
            }
        }
    }
}

ranges = normalizedOffsets.compactMap { offset in
    guard let swiftRange = Range(offset.nsRange, in: out) else { return nil }
    return TermRange(entry: offset.entry, range: swiftRange, type: offset.type)
}
```

### 6.3 변경점 상세 분석

#### 변경점 1: 1글자 변형 필터링

**위치:** `handleVariants()` 함수 내부

**변경 전:**
```swift
for variant in sorted where variant.isEmpty == false {
    // 검색 수행
}
```

**변경 후:**
```swift
for variant in sorted where variant.isEmpty == false {
    // ✨ 1글자 변형 제외
    guard variant.count > 1 else { continue }

    // 검색 수행
}
```

**효과:**
- "오", "울", "광" 같은 1글자 변형이 Phase 4에서 완전히 제외됨
- "오늘은" → "오브늘은" 같은 오정규화 방지 ✅

#### 변경점 2: 실제 매칭된 변형만 사용

**위치:** Phase 4 메인 루프

**변경 전:**
```swift
// ❌ 모든 variants 사용
handleVariants(name.variants, replacement: name.target, entry: entry)
```

**변경 후:**
```swift
// ✅ matchedVariantsByTarget에서 가져오기
if let matchedVariants = matchedVariantsByTarget[targetName] {
    handleVariants(Array(matchedVariants), replacement: name.target, entry: entry)
}
```

**효과:**
- Phase 1-3에서 실제로 매칭된 변형만 Phase 4에서 재사용
- "가고라" 사용 → "가굴라" 제외 ✅

#### 변경점 3: fallback 용어 처리

**위치:** Phase 4 fallback 루프

**문제:**
- `matchedVariantsByTarget`는 `entry.target`을 키로 사용
- fallback 매칭 변형도 `entry.target` 키로 저장됨
- 하지만 Phase 4에서는 `fallback.target`으로 교체해야 함

**해결책:**
```swift
if let fallbacks = name.fallbackTerms {
    for fallback in fallbacks {
        // matchedVariants는 entry.target 키로 저장된 모든 매칭 변형
        if let matchedVariants = matchedVariantsByTarget[targetName] {
            // fallback의 변형 집합
            let fallbackVariantsSet = Set([fallback.target] + fallback.variants)

            // 교집합: 실제로 매칭되었고 fallback에 속한 변형만
            let matchedFallbackVariants = matchedVariants.intersection(fallbackVariantsSet)

            if matchedFallbackVariants.isEmpty == false {
                handleVariants(Array(matchedFallbackVariants), replacement: fallback.target, entry: entry)
            }
        }
    }
}
```

**예시:**
```swift
// 용어집
name = NameGlossary(
    target: "쟈그라",
    variants: ["가고라"],
    fallbackTerms: [
        FallbackTerm(target: "저그러스", variants: ["저글러스", "Juggrus"])
    ]
)

// Phase 2에서 fallback 매칭 성공
matchedVariantsByTarget["쟈그라"] = ["저글러스"]  // entry.target 키 사용!

// Phase 4 fallback 처리
fallbackVariantsSet = ["저그러스", "저글러스", "Juggrus"]
matchedFallbackVariants = ["저글러스"]  // 교집합

// "저글러스"만 검색하여 "저그러스"로 교체
handleVariants(["저글러스"], replacement: "저그러스", entry: entry)
```

---

## 7. 엣지 케이스 및 처리 전략

### 7.1 엣지 케이스 1: 1글자 변형이 유일한 매칭

**시나리오:**
```
용어집:
- source: "奥", target: "오", variants: ["오브"]

원문: "奥の力" (奥 × 1회)
번역: "오의 힘"  // "오"만 매칭, "오브" 없음
```

**1차 패스:**
```swift
// candidates = ["오", "오브"]
// findNextCandidate() → "오" 매칭 (유일한 매칭)

matchedVariantsByTarget["오"] = ["오"]  // 1글자 변형 기록됨
```

**2차 패스:**
```swift
// matchedVariants = ["오"]
// handleVariants(["오"], ...)

for variant in matchedVariants:  // ["오"]
    // variant = "오"
    // ❌ guard variant.count > 1 else { continue }
    // 1글자이므로 continue

// 결과: Phase 4에서 아무것도 안 함
```

**결론:** 의도된 동작 ✅
- 1글자 변형만 매칭된 경우, Phase 4는 아무것도 하지 않음
- 원문과 같은 횟수만 정규화됨 (순차 정규화의 원래 철학)

### 7.2 엣지 케이스 2: 2글자 이상 변형과 1글자 변형 혼재

**시나리오:**
```
용어집:
- source: "奥", target: "오", variants: ["오브", "울트라맨 오브"]

원문: "奥の力" (奥 × 1회)
번역: "울트라맨 오브의 힘, 오브는"
```

**1차 패스:**
```swift
// candidates = ["오", "오브", "울트라맨 오브"]
// findNextCandidate() → "울트라맨 오브" 매칭 (가장 긴 것 우선)

matchedVariantsByTarget["오"] = ["울트라맨 오브"]
```

**2차 패스:**
```swift
// matchedVariants = ["울트라맨 오브"]
// handleVariants(["울트라맨 오브"], ...)

for variant in matchedVariants:  // ["울트라맨 오브"]
    // variant = "울트라맨 오브"
    // ✅ variant.count > 1 (7글자)
    // 검색 수행 → "오브는"에서 "울트라맨 오브" 매칭 실패

// "오브"는 matchedVariants에 없으므로 검색 안 됨
```

**결론:** 의도된 동작 ✅
- "울트라맨 오브"만 재검색됨
- "오브"는 Phase 1에서 매칭되지 않았으므로 Phase 4에서도 제외
- 추가 정규화가 필요하면 사용자가 용어집을 수정해야 함

### 7.3 엣지 케이스 3: Phase 2 fallback 매칭 후 Phase 4

**시나리오:**
```
용어집:
- source: "伽古拉", target: "쟈그라", variants: ["가고라"]
- fallbackTerms: [{ target: "저그러스", variants: ["저글러스"] }]

원문: "伽古拉が登場" (伽古拉 × 1회)
번역: "저글러스가 등장, 저글러스는"
```

**Phase 1:**
- "가고라" 검색 → 매칭 실패

**Phase 2:**
- fallback "저글러스" 검색 → 매칭 성공
```swift
matchedVariantsByTarget["쟈그라"] = ["저글러스"]  // entry.target 키!
out = "저그러스가 등장, 저글러스는"
```

**Phase 4:**
```swift
// processedTargets = ["쟈그라"]
// matchedVariants = ["저글러스"]

// fallback 처리
fallbackVariantsSet = ["저그러스", "저글러스"]
matchedFallbackVariants = ["저글러스"]  // 교집합

handleVariants(["저글러스"], replacement: "저그러스", entry: entry)
// "저글러스는" → "저그러스는" ✅
```

**결론:** 정상 작동 ✅
- fallback 매칭 변형도 Phase 4에서 재사용됨
- `replacement`는 `fallback.target` 사용 (정확히 매핑됨)

### 7.4 엣지 케이스 4: Phase 3 전역 검색 후 Phase 4

**시나리오:**
```
용어집:
- source: "홍카이", target: "호카이", variants: ["Hokai"]

원문: "홍카이가 싸움" (홍카이 × 1회)
번역: "Hokai가 싸움, 호카이는"
```

**Phase 1:**
- 순차 검색 실패 (위치 불일치)

**Phase 2:**
- fallback 없음

**Phase 3:**
- 전역 검색 → "Hokai" 매칭 성공
```swift
// normalizeVariantsAndParticles() 내부
matchedVariants["호카이"] = ["Hokai"]  // 반환값에 포함

// normalizeWithOrder() 내부
matchedVariantsByTarget["호카이"] = ["Hokai"]  // 기록
out = "호카이가 싸움, 호카이는"
```

**Phase 4:**
```swift
// matchedVariants = ["Hokai"]
// handleVariants(["Hokai"], replacement: "호카이", entry: entry)

// "호카이는"에서 "Hokai" 검색 → 매칭 실패
// 결과: Phase 4에서 추가 정규화 없음
```

**결론:** 정상 작동 ✅
- Phase 3 매칭 변형도 Phase 4에서 재사용됨
- "호카이는"은 "Hokai"와 다르므로 매칭 안 됨 (의도된 동작)

### 7.5 엣지 케이스 5: 같은 변형을 여러 번 매칭

**시나리오:**
```
용어집:
- source: "凯文", target: "케빈", variants: ["Kevin"]

원문: "凯文と凯文の友達" (凯文 × 2회)
번역: "Kevin과 Kevin의 친구"
```

**Phase 1:**
```swift
// 첫 번째 凯文
matchedVariantsByTarget["케빈"] = ["Kevin"]
out = "케빈과 Kevin의 친구"

// 두 번째 凯文
// findNextCandidate() → "Kevin" 매칭
matchedVariantsByTarget["케빈"].insert("Kevin")  // 이미 있음 (Set)
out = "케빈과 케빈의 친구"
```

**Phase 4:**
```swift
// matchedVariants = ["Kevin"]  // Set이므로 중복 없음
// 검색 → "Kevin" 매칭 없음
```

**결론:** 정상 작동 ✅
- `Set` 사용으로 중복 자동 제거
- Phase 4에서 불필요한 중복 검색 없음

### 7.6 엣지 케이스 6: 빈 matchedVariantsByTarget

**시나리오:**
```
용어집:
- source: "テスト", target: "테스트", variants: ["Test"]

원문: "テストです" (テスト × 1회)
번역: "테스트입니다"  // target이 그대로 사용됨
```

**Phase 1:**
```swift
// candidates = ["테스트", "Test"]
// findNextCandidate() → "테스트" 매칭

matchedVariantsByTarget["테스트"] = ["테스트"]  // target도 기록됨
```

**Phase 4:**
```swift
// matchedVariants = ["테스트"]
// handleVariants(["테스트"], replacement: "테스트", entry: entry)

// "테스트"를 검색하여 "테스트"로 교체 → 결과 동일
```

**결론:** 정상 작동 (무해) ✅
- target 자체도 `matchedVariants`에 포함될 수 있음
- Phase 4에서 검색해도 `overlapsProtected()`로 보호됨

---

## 8. 테스트 전략

### 8.1 테스트 1: 1글자 변형 필터링

**목적:** 1글자 변형이 Phase 4에서 제외되는지 확인

**테스트 코드:**
```swift
@Test
func phase4FiltersOutSingleCharacterVariants() {
    // 용어집: 奥 → "오", variants: ["오브", "울트라맨 오브"]
    let glossary = NameGlossary(
        target: "오",
        variants: ["오브", "울트라맨 오브"],
        expectedCount: 1,
        fallbackTerms: nil
    )

    // SegmentPieces: [term(奥)]
    let pieces = SegmentPieces(...)

    // 번역: "울트라맨 오브의 힘, 오늘은 날씨가 좋다"
    let translation = "울트라맨 오브의 힘, 오늘은 날씨가 좋다"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: [glossary]
    )

    // 검증
    #expect(result.text == "오의 힘, 오늘은 날씨가 좋다")
    //                      ↑ 정규화됨  ↑ 보호됨

    // "오늘은"의 "오"가 변경되지 않았는지 확인
    #expect(result.text.contains("오늘은"))

    // ranges는 1개만 (Phase 1 정규화)
    #expect(result.ranges.count == 1)
    let range = result.ranges[0]
    let normalized = String(result.text[range.range])
    #expect(normalized == "오")
}
```

**예상 결과:**
- ✅ "울트라맨 오브" → "오" (Phase 1)
- ✅ "오늘은" 보호됨 (Phase 4에서 "오" 제외)

### 8.2 테스트 2: 실제 매칭 변형만 재사용

**목적:** Phase 1에서 사용된 변형만 Phase 4에서 재사용되는지 확인

**테스트 코드:**
```swift
@Test
func phase4OnlyReusesActuallyMatchedVariants() {
    // 용어집: 伽古拉 → "쟈그라", variants: ["가고라", "가굴라", "Juggler"]
    let glossary = NameGlossary(
        target: "쟈그라",
        variants: ["가고라", "가굴라", "Juggler"],
        expectedCount: 1,
        fallbackTerms: nil
    )

    // SegmentPieces: [term(伽古拉)]
    let pieces = SegmentPieces(...)

    // 번역: "가고라가 등장, 가고라는 강하다, 가굴라도 있다"
    let translation = "가고라가 등장, 가고라는 강하다, 가굴라도 있다"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: [glossary]
    )

    // 검증
    #expect(result.text == "쟈그라가 등장, 쟈그라는 강하다, 가굴라도 있다")
    //                      ↑ Phase 1    ↑ Phase 4         ↑ 보호됨

    // "가굴라"가 변경되지 않았는지 확인
    #expect(result.text.contains("가굴라도"))

    // ranges는 2개 (Phase 1 + Phase 4)
    #expect(result.ranges.count == 2)
    #expect(result.ranges.allSatisfy { range in
        let text = String(result.text[range.range])
        return text == "쟈그라"
    })
}
```

**예상 결과:**
- ✅ "가고라" (첫 번째) → "쟈그라" (Phase 1)
- ✅ "가고라" (두 번째) → "쟈그라" (Phase 4)
- ✅ "가굴라" 보호됨 (matchedVariants에 없음)

### 8.3 테스트 3: fallback 용어와 Phase 4

**목적:** Phase 2 fallback 매칭 후 Phase 4가 정상 작동하는지 확인

**테스트 코드:**
```swift
@Test
func phase4HandlesMatchedFallbackVariants() {
    // 용어집
    let glossary = NameGlossary(
        target: "쟈그라",
        variants: ["가고라"],
        expectedCount: 1,
        fallbackTerms: [
            FallbackTerm(target: "저그러스", variants: ["저글러스", "Juggrus"])
        ]
    )

    // SegmentPieces: [term(伽古拉)]
    let pieces = SegmentPieces(...)

    // 번역: "저글러스가 등장, 저글러스는 강하다"
    let translation = "저글러스가 등장, 저글러스는 강하다"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: [glossary]
    )

    // 검증
    #expect(result.text == "저그러스가 등장, 저그러스는 강하다")
    //                      ↑ Phase 2         ↑ Phase 4

    #expect(result.ranges.count == 2)
    #expect(result.ranges.allSatisfy { range in
        let text = String(result.text[range.range])
        return text == "저그러스"
    })
}
```

**예상 결과:**
- ✅ "저글러스" (첫 번째) → "저그러스" (Phase 2)
- ✅ "저글러스" (두 번째) → "저그러스" (Phase 4)

### 8.4 테스트 4: Phase 3 전역 검색 후 Phase 4

**목적:** Phase 3 매칭 변형도 Phase 4에서 재사용되는지 확인

**테스트 코드:**
```swift
@Test
func phase4ReusesPhase3MatchedVariants() {
    // 용어집: 홍카이 → "호카이", variants: ["Hokai"]
    let glossary = NameGlossary(
        target: "호카이",
        variants: ["Hokai"],
        expectedCount: 1,
        fallbackTerms: nil
    )

    // SegmentPieces: [text, term(홍카이), text]
    // Phase 1에서 순차 검색 실패하도록 구성
    let pieces = SegmentPieces(...)

    // 번역: "Hokai가 싸움, Hokai는"
    let translation = "Hokai가 싸움, Hokai는"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: [glossary]
    )

    // 검증
    #expect(result.text == "호카이가 싸움, 호카이는")
    //                      ↑ Phase 3    ↑ Phase 4

    #expect(result.ranges.count == 2)
}
```

**예상 결과:**
- ✅ "Hokai" (첫 번째) → "호카이" (Phase 3)
- ✅ "Hokai" (두 번째) → "호카이" (Phase 4)

### 8.5 테스트 5: 보호 범위 + 1글자 필터링 통합

**목적:** 동음이의어 보호와 1글자 필터링이 함께 작동하는지 확인

**테스트 코드:**
```swift
@Test
func phase4CombinesProtectedRangesAndSingleCharFilter() {
    // 용어집
    let glossaries = [
        // 凯 → "가이", variants: ["케이", "Kai"]
        NameGlossary(target: "가이", variants: ["케이", "Kai"], expectedCount: 2, fallbackTerms: nil),
        // k → "케이", variants: []
        NameGlossary(target: "케이", variants: [], expectedCount: 1, fallbackTerms: nil)
    ]

    // SegmentPieces: [term(凯), text, term(k), text, term(凯)]
    let pieces = SegmentPieces(...)

    // 번역: "카이와 케이, 카이의 친구, 케이도"
    let translation = "카이와 케이, 카이의 친구, 케이도"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: glossaries
    )

    // 검증
    #expect(result.text == "가이와 케이, 가이의 친구, 케이도")
    //                      ↑P1   ↑P1  ↑P4           ↑보호

    // "케이" 보호 확인
    let keiCount = result.text.components(separatedBy: "케이").count - 1
    #expect(keiCount == 2)  // "케이"는 2회만 (Phase 1 k 매칭 + 마지막 보호)

    let kaiCount = result.text.components(separatedBy: "가이").count - 1
    #expect(kaiCount == 2)  // "가이"는 2회
}
```

**예상 결과:**
- ✅ "카이" (첫 번째) → "가이" (Phase 1)
- ✅ "케이" (k 매칭) → "케이" (Phase 1, 보호 범위로 기록)
- ✅ "카이" (두 번째) → "가이" (Phase 4)
- ✅ "케이도" 보호됨 (보호 범위와 겹침)

### 8.6 테스트 6: 2글자 이상 변형만 Phase 4 활성화

**목적:** 2글자 이상 변형은 Phase 4에서 정상 작동하는지 확인

**테스트 코드:**
```swift
@Test
func phase4AllowsMultiCharacterVariants() {
    // 용어집: 凯文 → "케빈", variants: ["Kevin", "케이빈"]
    let glossary = NameGlossary(
        target: "케빈",
        variants: ["Kevin", "케이빈"],
        expectedCount: 1,
        fallbackTerms: nil
    )

    // SegmentPieces: [term(凯文)]
    let pieces = SegmentPieces(...)

    // 번역: "케이빈이 말함, Kevin도"
    let translation = "케이빈이 말함, Kevin도"

    let result = masker.normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: [glossary]
    )

    // 검증
    #expect(result.text == "케빈이 말함, 케빈도")
    //                      ↑ Phase 1   ↑ Phase 4

    #expect(result.ranges.count == 2)
}
```

**예상 결과:**
- ✅ "케이빈" → "케빈" (Phase 1)
- ✅ "Kevin" → "케빈" (Phase 4)

---

## 9. 성능 고려사항

### 9.1 추가 메모리 사용

**새로운 데이터 구조:**
```swift
var matchedVariantsByTarget: [String: Set<String>] = [:]
```

**메모리 분석:**
- Key 크기: `String` (target, 예: "쟈그라") → 평균 5-20 바이트
- Value 크기: `Set<String>` (variants, 예: ["가고라"]) → 평균 1-5개 × 5-20 바이트
- 세그먼트당 평균 용어 수: 5-20개
- **예상 메모리:** 세그먼트당 약 1-5KB (무시 가능)

**결론:** 메모리 오버헤드 무시 가능 ✅

### 9.2 추가 연산 비용

**Phase 1-3 추가 비용:**
```swift
recordMatchedVariant(target: entry.target, variant: matched.candidate, in: &matchedVariantsByTarget)
```
- 딕셔너리 접근: O(1)
- Set 삽입: O(1)
- **영향:** 거의 없음 (각 매칭마다 O(1) 연산)

**Phase 4 비용 감소:**
- **기존:** 모든 variants 검색 (평균 5-10개)
- **개선:** matchedVariants만 검색 (평균 1-3개)
- **효과:** Phase 4 검색 연산 **50-70% 감소** ✅

**결론:** 전체 성능 **개선** (Phase 4 비용 감소 > Phase 1-3 추가 비용)

### 9.3 최악의 경우 분석

**시나리오:** 모든 변형이 매칭된 경우
```
용어집: variants: ["v1", "v2", "v3", "v4", "v5"]
번역: "v1과 v2와 v3와 v4와 v5"
```

**Phase 1-3:**
- 각 매칭마다 `recordMatchedVariant()` 호출 (O(1) × 5 = O(5))
- `matchedVariantsByTarget[target] = ["v1", "v2", "v3", "v4", "v5"]`

**Phase 4:**
- **기존:** 5개 변형 모두 검색
- **개선:** 5개 변형 모두 검색 (동일)
- **차이:** 없음

**결론:** 최악의 경우에도 성능 저하 없음 ✅

---

## 10. 기존 코드와의 통합 지점

### 10.1 수정 필요한 파일

**1. Masker.swift**
- `normalizeWithOrder()` 함수 ([lines 1199-1431](../MyTranslation/Services/Translation/Masking/Masker.swift#L1199-L1431))
- `normalizeVariantsAndParticles()` 함수 (Phase 3에서 호출)

**2. 테스트 파일**
- `MaskerTests.swift` (기존 테스트 업데이트 + 새 테스트 추가)

### 10.2 Backward Compatibility

**기존 동작과의 차이:**
1. **Phase 4가 더 보수적으로 작동**
   - 기존: 모든 variants 재검색
   - 개선: 실제 사용된 variants + 2글자 이상만 재검색

2. **일부 엣지 케이스에서 정규화 횟수 감소**
   - 예: "가고라" 사용 후 "가굴라" 발견 → 개선 후 정규화 안 됨
   - **의도된 변경:** 번역 엔진이 같은 세그먼트에서 다른 변형 사용은 매우 희귀

**마이그레이션 전략:**
1. 새 동작이 기본값
2. 기존 동작이 필요한 경우, 용어집에 추가 인스턴스 명시
3. 사용자 피드백 모니터링 후 조정

### 10.3 normalizeVariantsAndParticles() 수정

**현재 함수 위치:** Masker.swift (Phase 3에서 호출)

**현재 시그니처:**
```swift
func normalizeVariantsAndParticles(
    in text: String,
    entries: [(NameGlossary, GlossaryEntry)],
    baseText: String,
    cumulativeDelta: Int
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange])
```

**수정 후 시그니처:**
```swift
func normalizeVariantsAndParticles(
    in text: String,
    entries: [(NameGlossary, GlossaryEntry)],
    baseText: String,
    cumulativeDelta: Int
) -> (
    text: String,
    ranges: [TermRange],
    preNormalizedRanges: [TermRange],
    matchedVariants: [String: Set<String>]  // ✨ 추가
)
```

**함수 내부 수정:**
```swift
func normalizeVariantsAndParticles(
    in text: String,
    entries: [(NameGlossary, GlossaryEntry)],
    baseText: String,
    cumulativeDelta: Int
) -> (
    text: String,
    ranges: [TermRange],
    preNormalizedRanges: [TermRange],
    matchedVariants: [String: Set<String>]
) {
    var out = text
    var ranges: [TermRange] = []
    var preNormalizedRanges: [TermRange] = []
    var matchedVariants: [String: Set<String>] = [:]  // ✨ 추가

    for (name, entry) in entries {
        let candidates = makeCandidates(target: name.target, variants: name.variants)

        for candidate in candidates {
            // 전역 검색 로직...
            if let range = out.range(of: candidate, options: [.caseInsensitive]) {
                // ✨ 매칭 성공 시 기록
                if matchedVariants[entry.target] != nil {
                    matchedVariants[entry.target]?.insert(candidate)
                } else {
                    matchedVariants[entry.target] = [candidate]
                }

                // 정규화 수행...
                let result = replaceWithParticleFix(...)
                // ... 기존 로직 ...

                break  // 첫 번째 매칭만 사용
            }
        }

        // fallback 용어 처리도 동일하게 matchedVariants 기록
        if let fallbacks = name.fallbackTerms {
            for fallback in fallbacks {
                // ... fallback 로직 + matchedVariants 기록 ...
            }
        }
    }

    return (out, ranges, preNormalizedRanges, matchedVariants)
}
```

---

## 11. 위험 분석

### 11.1 위험 1: 과도한 보호로 인한 정규화 누락

**위험 설명:**
- 1글자 필터링 + 매칭 변형 제한으로 인해 정규화가 필요한 경우에도 건너뛰는 경우

**발생 가능성:** 낮음
- 번역 엔진이 같은 세그먼트에서 다른 변형을 사용할 가능성은 매우 낮음

**완화 전략:**
1. 사용자 피드백 모니터링
2. 필요 시 용어집에 `expectedCount` 증가 또는 추가 인스턴스 명시
3. Phase 4 필터링 조건을 설정으로 제어 가능하도록 향후 확장

**심각도:** 낮음 (사용자가 수동으로 해결 가능)

### 11.2 위험 2: matchedVariants 메모리 누적

**위험 설명:**
- 긴 문서에서 `matchedVariantsByTarget`이 누적되어 메모리 사용 증가

**발생 가능성:** 거의 없음
- `matchedVariantsByTarget`은 세그먼트 단위로 생성 (함수 로컬 변수)
- 세그먼트 처리 완료 후 자동 해제

**완화 전략:**
- 현재 설계로 충분 (로컬 변수 사용)

**심각도:** 없음

### 11.3 위험 3: normalizeVariantsAndParticles() 호출처 누락

**위험 설명:**
- `normalizeVariantsAndParticles()`의 반환 타입이 변경되면서, 다른 호출처에서 컴파일 오류 발생 가능

**발생 가능성:** 중간
- `normalizeVariantsAndParticles()`가 다른 곳에서도 사용되는 경우

**완화 전략:**
1. 컴파일 오류를 통해 즉시 발견 가능
2. 다른 호출처에서는 `matchedVariants` 무시 가능 (`let (text, ranges, preNormalized, _) = ...`)

**심각도:** 낮음 (컴파일 타임에 발견)

### 11.4 위험 4: fallback 용어 교집합 로직 오류

**위험 설명:**
- Phase 4 fallback 처리에서 교집합 계산이 잘못되어 정규화 누락 또는 오정규화

**발생 가능성:** 중간
- 복잡한 로직이므로 엣지 케이스 가능

**완화 전략:**
1. 테스트 8.3 (fallback 용어 테스트) 강화
2. 다양한 fallback 시나리오 테스트

**심각도:** 중간 (테스트로 완화 가능)

---

## 12. 구현 체크리스트

### 12.1 코드 수정

- [ ] **Masker.swift 수정**
  - [ ] `normalizeWithOrder()` 내부에 `matchedVariantsByTarget` 변수 추가
  - [ ] `recordMatchedVariant()` 헬퍼 함수 추가
  - [ ] Phase 1: `recordMatchedVariant()` 호출 추가
  - [ ] Phase 2: `recordMatchedVariant()` 호출 추가 (entry.target 키 사용)
  - [ ] Phase 3: `normalizeVariantsAndParticles()` 반환값에서 `matchedVariants` 가져오기
  - [ ] Phase 4: `handleVariants()` 함수에 1글자 필터링 추가 (`guard variant.count > 1`)
  - [ ] Phase 4: 메인 루프에서 `matchedVariantsByTarget` 조회로 변경
  - [ ] Phase 4: fallback 용어 교집합 로직 구현

- [ ] **normalizeVariantsAndParticles() 함수 수정**
  - [ ] 반환 타입에 `matchedVariants: [String: Set<String>]` 추가
  - [ ] 함수 내부에 `matchedVariants` 변수 추가
  - [ ] 매칭 성공 시 `matchedVariants` 기록
  - [ ] fallback 매칭 시에도 `matchedVariants` 기록
  - [ ] 반환 시 `matchedVariants` 포함

### 12.2 테스트 작성

- [ ] **테스트 8.1: 1글자 변형 필터링**
  - [ ] `phase4FiltersOutSingleCharacterVariants` 구현
  - [ ] "오늘은"이 "오브늘은"으로 오염되지 않는지 검증

- [ ] **테스트 8.2: 실제 매칭 변형만 재사용**
  - [ ] `phase4OnlyReusesActuallyMatchedVariants` 구현
  - [ ] "가고라" 사용 후 "가굴라" 보호 검증

- [ ] **테스트 8.3: fallback 용어와 Phase 4**
  - [ ] `phase4HandlesMatchedFallbackVariants` 구현
  - [ ] Phase 2 fallback 매칭 후 Phase 4 추가 정규화 검증

- [ ] **테스트 8.4: Phase 3 전역 검색 후 Phase 4**
  - [ ] `phase4ReusesPhase3MatchedVariants` 구현
  - [ ] Phase 3 매칭 변형이 Phase 4에서 재사용되는지 검증

- [ ] **테스트 8.5: 보호 범위 + 1글자 필터링 통합**
  - [ ] `phase4CombinesProtectedRangesAndSingleCharFilter` 구현
  - [ ] 동음이의어 보호와 1글자 필터링 함께 작동 검증

- [ ] **테스트 8.6: 2글자 이상 변형 정상 작동**
  - [ ] `phase4AllowsMultiCharacterVariants` 구현
  - [ ] 2글자 이상 변형은 Phase 4에서 정상 정규화되는지 검증

### 12.3 문서 업데이트

- [ ] **BUGS.md 업데이트**
  - [ ] BUG-004 상태 업데이트 (해결됨)
  - [ ] 해결 방법 요약 추가

- [ ] **SPEC_PHASE4_RESIDUAL_BATCH_REPLACEMENT.md 업데이트**
  - [ ] 1글자 변형 필터링 추가됨 명시
  - [ ] 실제 매칭 변형 추적 메커니즘 추가

- [ ] **TODO.md 업데이트**
  - [ ] Phase 4 개선 작업 완료 표시

### 12.4 코드 리뷰 체크리스트

- [ ] **정확성**
  - [ ] 1글자 필터링이 모든 Phase 4 경로에 적용되는가?
  - [ ] `recordMatchedVariant()`가 Phase 1-3 모든 매칭 시 호출되는가?
  - [ ] fallback 교집합 로직이 정확한가?

- [ ] **성능**
  - [ ] `matchedVariantsByTarget` 사용이 Phase 4 성능을 개선하는가?
  - [ ] 불필요한 딕셔너리 복사가 없는가?

- [ ] **메모리**
  - [ ] `matchedVariantsByTarget`가 함수 종료 후 해제되는가?
  - [ ] Set 사용으로 중복이 제거되는가?

- [ ] **테스트 커버리지**
  - [ ] 모든 엣지 케이스가 테스트되는가?
  - [ ] 기존 테스트가 여전히 통과하는가?

---

## 13. 성공 기준

### 13.1 기능적 성공 기준

1. **✅ 1글자 변형 오정규화 방지**
   - "오늘은" → "오브늘은" 같은 오염이 발생하지 않음
   - 테스트 8.1 통과

2. **✅ 실제 매칭 변형만 재사용**
   - "가고라" 사용 → "가굴라" 제외
   - 테스트 8.2 통과

3. **✅ Phase 4 추가 정규화 작동**
   - 번역 엔진이 추가한 인스턴스가 정규화됨
   - "Kevin과 Kevin" → "케빈과 케빈" (두 번째 "Kevin"도 정규화)
   - 기존 테스트 통과 (`normalizeWithOrderHandlesResidualVariantsInPhase4`)

4. **✅ 동음이의어 보호 유지**
   - Phase 4에서도 `overlapsProtected()` 작동
   - 테스트 8.5 통과

5. **✅ fallback 용어 지원**
   - Phase 2 fallback 매칭 후 Phase 4 작동
   - 테스트 8.3 통과

6. **✅ Phase 3 전역 검색 지원**
   - Phase 3 매칭 변형도 Phase 4에서 재사용
   - 테스트 8.4 통과

### 13.2 성능 성공 기준

1. **✅ Phase 4 검색 연산 감소**
   - 기존: 평균 5-10개 변형 검색
   - 개선: 평균 1-3개 변형 검색
   - 측정: Phase 4 실행 시간 30-50% 감소

2. **✅ 메모리 사용 무시 가능**
   - `matchedVariantsByTarget` 추가 메모리: 세그먼트당 <5KB
   - 전체 메모리 사용 증가: <1%

### 13.3 품질 성공 기준

1. **✅ 모든 테스트 통과**
   - 기존 테스트 100% 통과
   - 새 테스트 6개 100% 통과

2. **✅ 코드 리뷰 승인**
   - 정확성, 성능, 메모리 체크리스트 모두 통과

3. **✅ 문서 업데이트 완료**
   - BUGS.md, SPEC 문서, TODO.md 최신화

---

## 14. 향후 개선 방향

### 14.1 선택적 1글자 변형 허용

**현재 제약:**
- Phase 4에서 모든 1글자 변형 제외

**개선 아이디어:**
- 용어집에 `allowSingleCharInPhase4: Bool` 플래그 추가
- 특정 용어는 1글자 변형도 Phase 4 허용 (예: "光" → "광" 같은 안전한 경우)

**예상 구현:**
```swift
struct NameGlossary {
    let target: String
    let variants: [String]
    let expectedCount: Int
    let fallbackTerms: [FallbackTerm]?
    let allowSingleCharInPhase4: Bool = false  // ✨ 추가
}

// Phase 4 handleVariants()
func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry, allowSingleChar: Bool) {
    for variant in sorted where variant.isEmpty == false {
        // 조건부 1글자 필터링
        if !allowSingleChar && variant.count <= 1 {
            continue
        }
        // ... 검색 로직 ...
    }
}
```

### 14.2 변형 우선순위 지정

**현재 동작:**
- `matchedVariants`는 `Set`이므로 순서 없음
- `handleVariants()` 내부에서 길이순 정렬

**개선 아이디어:**
- 용어집에 변형별 우선순위 지정
- 높은 우선순위 변형을 먼저 검색

**예상 구현:**
```swift
struct VariantWithPriority {
    let text: String
    let priority: Int  // 높을수록 우선
}

struct NameGlossary {
    let target: String
    let variants: [VariantWithPriority]  // 기존 [String]에서 변경
    // ...
}
```

### 14.3 통계 수집

**개선 아이디어:**
- Phase 4에서 실제로 정규화된 횟수 추적
- 사용자에게 Phase 4 효과 보고

**예상 구현:**
```swift
struct NormalizationStats {
    var phase1Count: Int = 0
    var phase2Count: Int = 0
    var phase3Count: Int = 0
    var phase4Count: Int = 0  // ✨ 추가
    var phase4SkippedSingleChar: Int = 0  // ✨ 1글자 필터링으로 건너뛴 횟수
}

// normalizeWithOrder() 반환 타입
return (out, ranges, preNormalizedRanges, stats)
```

### 14.4 Phase 4 비활성화 옵션

**개선 아이디어:**
- 사용자가 Phase 4를 완전히 비활성화할 수 있는 설정 추가
- BUG-004가 발생하지 않는 환경에서는 Phase 4 불필요

**예상 구현:**
```swift
struct MaskerConfig {
    var enablePhase4: Bool = true  // ✨ 추가
}

// normalizeWithOrder() 내부
if config.enablePhase4 {
    // Phase 4 로직...
}
```

---

## 15. 참고 자료

### 15.1 관련 문서

- **BUGS.md**: BUG-004 상세 설명
- **SPEC_PHASE4_RESIDUAL_BATCH_REPLACEMENT.md**: 원래 Phase 4 스펙
- **SPEC_ORDER_BASED_NORMALIZATION.md**: Phase 1-3 순차 정규화 스펙

### 15.2 관련 코드

- **Masker.swift** ([lines 1199-1431](../MyTranslation/Services/Translation/Masking/Masker.swift#L1199-L1431)): `normalizeWithOrder()` 함수
- **Masker.swift** (Phase 3 호출): `normalizeVariantsAndParticles()` 함수
- **MaskerTests.swift**: 기존 Phase 4 테스트

### 15.3 설계 결정 기록

| 결정 | 이유 | 대안 |
|------|------|------|
| `Set<String>` 사용 | 중복 제거, 순서 불필요 | `[String]` (중복 가능) |
| 1글자 필터링 (`count > 1`) | 오정규화 위험 높음 | 2글자 필터링 (`count > 2`) |
| `entry.target` 키 사용 | Phase 1-3와 Phase 4 일관성 | 별도 키 구조 |
| fallback 교집합 로직 | 정확한 매핑 필요 | 단순 matchedVariants 사용 |

---

## 부록 A: 전체 코드 예시

### normalizeWithOrder() 전체 수정본 (핵심 부분)

```swift
func normalizeWithOrder(
    in text: String,
    pieces: SegmentPieces,
    nameGlossaries: [NameGlossary]
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange]) {
    guard text.isEmpty == false else { return (text, [], []) }
    guard nameGlossaries.isEmpty == false else { return (text, [], []) }

    let original = text.precomposedStringWithCompatibilityMapping
    var out = original
    var ranges: [TermRange] = []
    var preNormalizedRanges: [TermRange] = []
    let nameByTarget = Dictionary(nameGlossaries.map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
    let entryByTarget = Dictionary(
        pieces.unmaskedTerms().map { ($0.target, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var processed: Set<Int> = []
    var lastMatchUpperBound: String.Index? = nil
    var phase2LastMatch: String.Index? = nil
    var cumulativeDelta: Int = 0

    // ✨ 새로운 추가: 실제 매칭된 변형 추적
    var matchedVariantsByTarget: [String: Set<String>] = [:]

    // ✨ 헬퍼 함수: 매칭 변형 기록
    func recordMatchedVariant(target: String, variant: String) {
        if matchedVariantsByTarget[target] != nil {
            matchedVariantsByTarget[target]?.insert(variant)
        } else {
            matchedVariantsByTarget[target] = [variant]
        }
    }

    let unmaskedTerms: [(index: Int, entry: GlossaryEntry)] = pieces.pieces.enumerated().compactMap { idx, piece in
        if case .term(let entry, _) = piece, entry.preMask == false {
            return (index: idx, entry: entry)
        }
        return nil
    }

    // Phase 1: target + variants 순서 기반 매칭
    for (index, entry) in unmaskedTerms {
        guard let name = nameByTarget[entry.target] else { continue }
        let candidates = makeCandidates(target: name.target, variants: name.variants)
        guard let matched = findNextCandidate(
            in: out,
            candidates: candidates,
            startIndex: lastMatchUpperBound ?? out.startIndex
        ) else { continue }

        // ✨ 매칭 변형 기록
        recordMatchedVariant(target: entry.target, variant: matched.candidate)

        let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
        let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
        let originalLower = lowerOffset - cumulativeDelta
        if originalLower >= 0, originalLower + oldLen <= original.count {
            let lower = original.index(original.startIndex, offsetBy: originalLower)
            let upper = original.index(lower, offsetBy: oldLen)
            preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
        }

        let result = replaceWithParticleFix(in: out, range: matched.range, replacement: name.target)
        out = result.text
        lastMatchUpperBound = result.nextIndex
        if let range = result.replacedRange {
            ranges.append(.init(entry: entry, range: range, type: .normalized))
        }
        let newLen: Int
        if let replacedRange = result.replacedRange {
            newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
        } else {
            newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
        }
        cumulativeDelta += (newLen - oldLen)
        processed.insert(index)
    }

    // Phase 2: Pattern fallback 순서 기반 매칭
    for (index, entry) in unmaskedTerms where processed.contains(index) == false {
        guard let name = nameByTarget[entry.target],
              let fallbacks = name.fallbackTerms else { continue }

        for fallback in fallbacks {
            let candidates = makeCandidates(target: fallback.target, variants: fallback.variants)
            guard let matched = findNextCandidate(
                in: out,
                candidates: candidates,
                startIndex: phase2LastMatch ?? out.startIndex
            ) else { continue }

            // ✨ 매칭 변형 기록 (entry.target 키 사용!)
            recordMatchedVariant(target: entry.target, variant: matched.candidate)

            let lowerOffset = out.distance(from: out.startIndex, to: matched.range.lowerBound)
            let oldLen = out.distance(from: matched.range.lowerBound, to: matched.range.upperBound)
            let originalLower = lowerOffset - cumulativeDelta
            if originalLower >= 0, originalLower + oldLen <= original.count {
                let lower = original.index(original.startIndex, offsetBy: originalLower)
                let upper = original.index(lower, offsetBy: oldLen)
                preNormalizedRanges.append(.init(entry: entry, range: lower..<upper, type: .normalized))
            }

            let result = replaceWithParticleFix(in: out, range: matched.range, replacement: fallback.target)
            out = result.text
            phase2LastMatch = result.nextIndex
            if let range = result.replacedRange {
                ranges.append(.init(entry: entry, range: range, type: .normalized))
            }
            let newLen: Int
            if let replacedRange = result.replacedRange {
                newLen = out.distance(from: replacedRange.lowerBound, to: replacedRange.upperBound)
            } else {
                newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
            }
            cumulativeDelta += (newLen - oldLen)
            processed.insert(index)
            break
        }
    }

    // Phase 3: 전역 검색 Fallback (기존 로직 재사용)
    let remainingTargets = Set(
        unmaskedTerms
            .filter { processed.contains($0.index) == false }
            .map { $0.entry.target }
    )
    let remainingGlossaries = nameGlossaries.filter { remainingTargets.contains($0.target) }
    if remainingGlossaries.isEmpty == false {
        let mappedEntries = remainingGlossaries.compactMap { g -> (NameGlossary, GlossaryEntry)? in
            guard let entry = entryByTarget[g.target] else { return nil }
            return (g, entry)
        }
        if mappedEntries.isEmpty == false {
            let result = normalizeVariantsAndParticles(
                in: out,
                entries: mappedEntries,
                baseText: original,
                cumulativeDelta: cumulativeDelta
            )
            out = result.text
            ranges.append(contentsOf: result.ranges)
            preNormalizedRanges.append(contentsOf: result.preNormalizedRanges)

            // ✨ Phase 3 매칭 변형 기록
            for (target, variants) in result.matchedVariants {
                for variant in variants {
                    recordMatchedVariant(target: target, variant: variant)
                }
            }
        }
    }

    // Phase 4: 잔여 일괄 교체 (보호 범위 + 1글자 필터링 포함)
    struct OffsetRange {
        let entry: GlossaryEntry
        var nsRange: NSRange
        let type: TermRange.TermType
    }

    var normalizedOffsets: [OffsetRange] = ranges.compactMap { termRange in
        guard let nsRange = NSRange(termRange.range, in: out) else { return nil }
        return OffsetRange(entry: termRange.entry, nsRange: nsRange, type: termRange.type)
    }
    var protectedRanges: [NSRange] = normalizedOffsets.map { $0.nsRange }

    let processedTargetsFromOffsets = normalizedOffsets.map { $0.entry.target }
    let processedTargetsFromProcessed = processed.compactMap { idx -> String? in
        guard idx < pieces.pieces.count else { return nil }
        guard case .term(let entry, _) = pieces.pieces[idx] else { return nil }
        return entry.target
    }
    let processedTargets = Set(processedTargetsFromOffsets + processedTargetsFromProcessed)

    func overlapsProtected(_ range: NSRange) -> Bool {
        return protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    func shiftRanges(after position: Int, delta: Int) {
        guard delta != 0 else { return }
        for idx in normalizedOffsets.indices where normalizedOffsets[idx].nsRange.location >= position {
            normalizedOffsets[idx].nsRange.location += delta
        }
        for idx in protectedRanges.indices where protectedRanges[idx].location >= position {
            protectedRanges[idx].location += delta
        }
    }

    func handleVariants(_ variants: [String], replacement: String, entry: GlossaryEntry) {
        let sorted = variants.sorted { $0.count > $1.count }
        for variant in sorted where variant.isEmpty == false {
            // ✨ 1글자 변형 필터링
            guard variant.count > 1 else { continue }

            var matches: [NSRange] = []
            var searchStart = out.startIndex

            while searchStart < out.endIndex,
                  let found = out.range(of: variant, options: [.caseInsensitive], range: searchStart..<out.endIndex) {
                let nsRange = NSRange(found, in: out)
                if overlapsProtected(nsRange) == false {
                    matches.append(nsRange)
                }
                searchStart = found.upperBound
            }

            for nsRange in matches.reversed() {
                guard let swiftRange = Range(nsRange, in: out) else { continue }
                let before = out
                let result = replaceWithParticleFix(in: out, range: swiftRange, replacement: replacement)
                let delta = (result.text as NSString).length - (before as NSString).length
                out = result.text
                if delta != 0 {
                    let threshold = nsRange.location + nsRange.length
                    shiftRanges(after: threshold, delta: delta)
                }
                if let replacedRange = result.replacedRange,
                   let nsReplaced = NSRange(replacedRange, in: out) {
                    normalizedOffsets.append(.init(entry: entry, nsRange: nsReplaced, type: .normalized))
                    protectedRanges.append(nsReplaced)
                }
            }
        }
    }

    // ✨ 핵심 변경: matchedVariantsByTarget에서 실제 사용된 변형만 가져오기
    for targetName in processedTargets {
        guard let name = nameByTarget[targetName],
              let entry = entryByTarget[targetName] else { continue }

        if let matchedVariants = matchedVariantsByTarget[targetName] {
            handleVariants(Array(matchedVariants), replacement: name.target, entry: entry)
        }

        if let fallbacks = name.fallbackTerms {
            for fallback in fallbacks {
                if let matchedVariants = matchedVariantsByTarget[targetName] {
                    let fallbackVariantsSet = Set([fallback.target] + fallback.variants)
                    let matchedFallbackVariants = matchedVariants.intersection(fallbackVariantsSet)

                    if matchedFallbackVariants.isEmpty == false {
                        handleVariants(Array(matchedFallbackVariants), replacement: fallback.target, entry: entry)
                    }
                }
            }
        }
    }

    ranges = normalizedOffsets.compactMap { offset in
        guard let swiftRange = Range(offset.nsRange, in: out) else { return nil }
        return TermRange(entry: offset.entry, range: swiftRange, type: offset.type)
    }

    return (out, ranges, preNormalizedRanges)
}
```

---

## 부록 B: 의사결정 트리

```
Phase 4 변형 검색 의사결정
├─ variant in matchedVariantsByTarget?
│  ├─ NO → SKIP (Phase 1-3에서 사용 안 됨)
│  └─ YES
│     └─ variant.count > 1?
│        ├─ NO → SKIP (1글자 필터링)
│        └─ YES
│           └─ overlapsProtected(range)?
│              ├─ YES → SKIP (보호 범위)
│              └─ NO → NORMALIZE ✅
```

---

**문서 끝**
