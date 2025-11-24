# SPEC: Phase 4 - 잔여 일괄 교체 (Residual Batch Replacement)

**작성일:** 2025-11-24
**최종 수정일:** 2025-11-24
**상태:** 제안됨 (Proposed) - 보호 범위 메커니즘 추가
**우선순위:** P2
**관련 버그:** BUG-004
**의존성:** SPEC_ORDER_BASED_NORMALIZATION.md (구현 완료)

**주요 변경사항 (2025-11-24):**
- **보호 범위 메커니즘 추가:** Phase 1-3에서 정규화된 범위를 보호하여 동음이의어 구분 파괴 방지
- **완전한 범위 추적:** Phase 4 정규화도 ranges 배열에 추가하여 오버레이 하이라이팅 지원
- **Section 4.3 추가:** 보호 알고리즘 상세 설명 및 동음이의어 문제 재발 방지 로직
- **테스트 8, 9 추가:** 보호 범위 존중 및 범위 추적 검증 테스트
- **Section 11.1.1 추가:** 동음이의어 구분 파괴 위험 해결됨 명시
- **수정:** processedTargets를 ranges 기반으로 수집 (Phase 3 정규화 포함)
- **수정:** contains(where:) 문법 수정 및 replaceWithParticleFix 파라미터명 정정

---

## 목차

1. [문제 요약](#1-문제-요약)
2. [현재 3단계 알고리즘 정리](#2-현재-3단계-알고리즘-정리)
3. [제안하는 Phase 4: 잔여 일괄 교체](#3-제안하는-phase-4-잔여-일괄-교체)
4. [상세 구현 설계](#4-상세-구현-설계)
5. [엣지 케이스 및 처리 전략](#5-엣지-케이스-및-처리-전략)
6. [예상되는 동작 변경](#6-예상되는-동작-변경)
7. [테스트 전략](#7-테스트-전략)
8. [성능 고려사항](#8-성능-고려사항)
9. [기존 코드와의 통합 지점](#9-기존-코드와의-통합-지점)
10. [검토된 대안 접근법](#10-검토된-대안-접근법)
11. [위험 분석](#11-위험-분석)
12. [구현 체크리스트](#12-구현-체크리스트)
13. [성공 기준](#13-성공-기준)
14. [향후 개선 방향](#14-향후-개선-방향)
15. [참고 자료](#15-참고-자료)

---

## 1. 문제 요약

### 1.1 이슈 설명

현재의 3단계 순번 기반 정규화 알고리즘(`normalizeWithOrder()`)은 번역 엔진이 원문보다 더 많은 용어 인스턴스를 추가하는 경우를 처리하지 못합니다. 이는 1:N 매핑 문제로, N > 1인 경우입니다.

**참고:** BUGS.md BUG-004 (423-801번째 줄)

### 1.2 재현 시나리오

```
원문 텍스트 (중국어): "凯文说话时，杜兰特在听"
- 원문 등장: "凯文" × 1회, "杜兰特" × 1회
- SegmentPieces: [text, term(凯文), text, term(杜兰特), text]

용어집:
- "凯文" → target: "케빈", variants: ["케이빈", "카이", "Kevin"]
- "杜兰特" → target: "듀란트", variants: ["두란테", "Durant"]

번역 엔진 출력 (자연스러운 번역을 위해 인스턴스 추가):
"케빈이 말할 때, 케빈·듀란트가 듣고 있었다"
- 번역문 등장: "케빈" × 2회 (엔진이 1회 추가!), "듀란트" × 1회

현재 정규화 동작:
- Phase 1: 첫 번째 "케빈" 정규화 → processed[0] = true
- Phase 2: 건너뜀 (fallback 불필요)
- Phase 3: 전역 검색이 "케빈"을 건너뜀 (이미 processedTargets에 포함)
- 결과: 두 번째 "케빈"은 정규화되지 않음 ❌

기대 동작:
- 두 "케빈" 인스턴스 모두 정규화되어야 함
```

---

## 2. 현재 3단계 알고리즘 정리

### 2.1 데이터 구조

**위치:** `/Users/sailor.m/PrivateDevelop/MyTranslation/MyTranslation/Services/Translation/Masking/Masker.swift:1199-1327`

```swift
struct NameGlossary {
    let target: String
    let variants: [String]
    let expectedCount: Int  // 원문 텍스트 등장 횟수
    let fallbackTerms: [FallbackTerm]?
}

// normalizeWithOrder() 내부:
var processed: Set<Int> = []  // 처리된 원문 용어 인덱스
var lastMatchUpperBound: String.Index?  // Phase 1 커서
var phase2LastMatch: String.Index?  // Phase 2 커서
let unmaskedTerms: [(index: Int, entry: GlossaryEntry)]  // 원문 주도 순회
```

### 2.2 Phase 1: target + variants를 이용한 순차 매칭

**줄 번호:** 1228-1265

**알고리즘:**
```
unmaskedTerms (원문 순서)의 각 (index, entry)에 대해:
    1. entry.target에 대한 NameGlossary 가져오기
    2. candidates = [target] + variants 생성
    3. findNextCandidate(startIndex: lastMatchUpperBound) 호출
    4. 찾으면:
        - target으로 교체
        - lastMatchUpperBound = result.nextIndex로 업데이트
        - processed.insert(index) 표시
```

**특징:**
- 원문 주도 순회 (원문 용어에 대해서만 루프)
- 순차 커서 전진
- 1:1 매핑 가정
- 한 번 처리되면 재방문 안 함

### 2.3 Phase 2: 패턴 fallback

**줄 번호:** 1267-1309

**알고리즘:**
```
!processed.contains(index)인 unmaskedTerms의 각 (index, entry)에 대해:
    1. NameGlossary에서 fallbackTerms 가져오기
    2. 각 fallback에 대해:
        - candidates = [fallback.target] + fallback.variants 생성
        - findNextCandidate(startIndex: phase2LastMatch) 호출
        - 찾으면: 교체, processed 표시, break
```

**특징:**
- Phase 2를 위한 별도 커서
- 패턴 fallback 케이스 처리
- 여전히 원문 주도 (1:1 가정)

### 2.4 Phase 3: 전역 검색 fallback

**줄 번호:** 1311-1327

**알고리즘:**
```
remainingTargets = 미처리 용어의 .entry.target
remainingGlossaries = remainingTargets.contains($0.target)인 nameGlossaries
normalizeVariantsAndParticles(entries: remainingGlossaries)
```

**특징:**
- 정규식 기반 전역 교체
- 미처리 원문 용어만 처리
- **이미 처리된 용어는 재처리 안 함**
- **추가 번역문 인스턴스를 처리할 수 없음**

---

## 3. 제안하는 Phase 4: 잔여 일괄 교체

### 3.1 설계 근거

**핵심 통찰:** Phase 1-3 이후, 우리는 어떤 원문 용어들이 성공적으로 매칭되었는지 알고 있습니다 (`processed` Set). 이러한 이미 처리된 용어들에 대해, 번역문에 남아있는 variant 인스턴스들은 번역 엔진이 추가한 여분의 인스턴스일 것입니다.

**전략:**
- Phase 1-3의 높은 동음이의어 구분 정확도 유지 (70-90%)
- Phase 4를 추가하여 남아있는 variant 인스턴스들을 "정리"
- Phase 4는 일괄 교체 사용 (낮은 정확도)하지만 이미 구분된 용어에 대해서만
- 하이브리드 접근: 두 세계의 장점

### 3.2 알고리즘 의사코드

```swift
// Phase 4: 추가 인스턴스를 위한 잔여 일괄 교체 (보호 범위 포함)
// 위치: normalizeWithOrder()의 Phase 3 이후

// 1. Phase 1-3에서 정규화된 출력 범위를 보호 범위로 수집
var protectedRanges: [Range<String.Index>] = ranges.map { $0.range }
    .sorted { $0.lowerBound < $1.lowerBound }

// 2. 성공적으로 처리된 용어들의 target 수집
// Phase 1-3에서 정규화된 모든 용어를 ranges에서 추출
let processedTargets: Set<String> = Set(ranges.map { $0.entry.target })

// 3. 보호 범위와 겹치는지 확인하는 헬퍼 함수
func isRangeProtected(_ testRange: Range<String.Index>) -> Bool {
    return protectedRanges.contains(where: { protectedRange in
        testRange.overlaps(protectedRange)
    })
}

// 4. 처리된 각 target에 대해, 보호되지 않은 variant만 교체
for targetName in processedTargets {
    guard let name = nameByTarget[targetName] else { continue }
    guard let entry = entryByTarget[targetName] else { continue }

    // 5. variant를 길이순(내림차순)으로 정렬 (긴 매칭 우선)
    let sortedVariants = name.variants.sorted { $0.count > $1.count }

    // 6. 각 variant에 대해 보호되지 않은 인스턴스만 교체
    for variant in sortedVariants {
        guard !variant.isEmpty else { continue }

        var replacements: [(range: Range<String.Index>, target: String)] = []
        var searchStart = out.startIndex

        // 7. variant의 모든 발견 위치를 찾되, 보호된 범위는 건너뜀
        while searchStart < out.endIndex {
            guard let variantRange = out.range(
                of: variant,
                options: [.caseInsensitive],
                range: searchStart..<out.endIndex
            ) else { break }

            // 8. 이 범위가 보호되지 않았으면 교체 대상에 추가
            if !isRangeProtected(variantRange) {
                replacements.append((range: variantRange, target: name.target))
            }

            searchStart = variantRange.upperBound
        }

        // 9. 역순으로 교체 (범위 무효화 방지)
        for repl in replacements.reversed() {
            let result = replaceWithParticleFix(
                in: out,
                range: repl.range,
                replacement: repl.target
            )
            out = result.text

            // 10. 교체된 범위를 ranges와 protectedRanges에 추가
            if let newRange = result.replacedRange {
                ranges.append(.init(entry: entry, range: newRange, type: .normalized))
                protectedRanges.append(newRange)
                protectedRanges.sort { $0.lowerBound < $1.lowerBound }
            }
        }
    }

    // 11. fallback variant도 동일하게 처리
    if let fallbacks = name.fallbackTerms {
        for fallback in fallbacks {
            let sortedFallbackVariants = fallback.variants.sorted { $0.count > $1.count }

            for variant in sortedFallbackVariants {
                guard !variant.isEmpty else { continue }

                var replacements: [(range: Range<String.Index>, target: String)] = []
                var searchStart = out.startIndex

                while searchStart < out.endIndex {
                    guard let variantRange = out.range(
                        of: variant,
                        options: [.caseInsensitive],
                        range: searchStart..<out.endIndex
                    ) else { break }

                    if !isRangeProtected(variantRange) {
                        replacements.append((range: variantRange, target: fallback.target))
                    }

                    searchStart = variantRange.upperBound
                }

                for repl in replacements.reversed() {
                    let result = replaceWithParticleFix(
                        in: out,
                        range: repl.range,
                        replacement: repl.target
                    )
                    out = result.text

                    if let newRange = result.replacedRange {
                        ranges.append(.init(entry: entry, range: newRange, type: .normalized))
                        protectedRanges.append(newRange)
                        protectedRanges.sort { $0.lowerBound < $1.lowerBound }
                    }
                }
            }
        }
    }
}
```

### 3.3 왜 이것이 작동하는가

1. **Phase 1-3에서 이미 구분됨:** 첫 번째 인스턴스가 높은 정확도로 매칭됨
2. **보호 범위로 동음이의어 문제 방지:** Phase 1-3에서 정규화된 범위는 재교체되지 않음
3. **같은 용어 가정:** 보호되지 않은 추가 인스턴스들은 동일한 용어일 가능성이 높음
4. **안전성:** Phase 1-3 구분을 통과한 용어에만 적용하며, 이미 정규화된 영역은 건드리지 않음
5. **완전성:** 위치와 무관하게 모든 추가 인스턴스를 잡아내되, 보호된 영역은 존중

### 3.4 통합 지점

**파일:** `/Users/sailor.m/PrivateDevelop/MyTranslation/MyTranslation/Services/Translation/Masking/Masker.swift`

**함수:** `normalizeWithOrder()`

**위치:** 1327번째 줄 이후 (Phase 3 이후), 최종 return 문 이전에 삽입

---

## 4. 상세 구현 설계

### 4.1 코드 변경

**파일:** `Masker.swift:1199-1327`

**수정 내용:**

```swift
func normalizeWithOrder(
    in text: String,
    pieces: SegmentPieces,
    nameGlossaries: [NameGlossary]
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange]) {
    // ... Phase 1, 2, 3에 대한 기존 코드 ...

    // Phase 3: 전역 검색 fallback
    // ... 기존 Phase 3 코드 (1311-1341번째 줄) ...

    // ============================================
    // Phase 4: 잔여 일괄 교체 (보호 범위 포함)
    // ============================================

    // 1. Phase 1-3에서 정규화된 범위를 보호 범위로 수집
    var protectedRanges: [Range<String.Index>] = ranges.map { $0.range }
        .sorted { $0.lowerBound < $1.lowerBound }

    // 2. 처리된 target 수집 (ranges 기반)
    // Phase 1-3에서 정규화된 모든 용어를 ranges에서 추출
    let processedTargets = Set(ranges.map { $0.entry.target })

    // 3. 보호 범위 겹침 검사 헬퍼
    func isRangeProtected(_ testRange: Range<String.Index>) -> Bool {
        return protectedRanges.contains(where: { $0.overlaps(testRange) })
    }

    // 4. 각 처리된 target에 대해 보호되지 않은 variant만 교체
    for targetName in processedTargets {
        guard let name = nameByTarget[targetName] else { continue }
        guard let entry = entryByTarget[targetName] else { continue }

        // variant를 길이순 정렬 (긴 것 우선)
        let sortedVariants = name.variants.sorted { $0.count > $1.count }

        for variant in sortedVariants {
            guard !variant.isEmpty else { continue }

            // 보호되지 않은 variant 위치 수집
            var replacements: [(range: Range<String.Index>, target: String)] = []
            var searchStart = out.startIndex

            while searchStart < out.endIndex {
                guard let variantRange = out.range(
                    of: variant,
                    options: [.caseInsensitive],
                    range: searchStart..<out.endIndex
                ) else { break }

                // 보호되지 않은 범위만 교체 대상에 추가
                if !isRangeProtected(variantRange) {
                    replacements.append((range: variantRange, target: name.target))
                }

                searchStart = variantRange.upperBound
            }

            // 역순 교체 (범위 무효화 방지)
            for repl in replacements.reversed() {
                let result = replaceWithParticleFix(
                    in: out,
                    range: repl.range,
                    replacement: repl.target
                )
                out = result.text

                // 교체된 범위 추적
                if let newRange = result.replacedRange {
                    ranges.append(.init(entry: entry, range: newRange, type: .normalized))
                    protectedRanges.append(newRange)
                    protectedRanges.sort { $0.lowerBound < $1.lowerBound }
                }
            }
        }

        // fallback variant도 동일하게 처리
        if let fallbacks = name.fallbackTerms {
            for fallback in fallbacks {
                let sortedFallbackVariants = fallback.variants.sorted { $0.count > $1.count }

                for variant in sortedFallbackVariants {
                    guard !variant.isEmpty else { continue }

                    var replacements: [(range: Range<String.Index>, target: String)] = []
                    var searchStart = out.startIndex

                    while searchStart < out.endIndex {
                        guard let variantRange = out.range(
                            of: variant,
                            options: [.caseInsensitive],
                            range: searchStart..<out.endIndex
                        ) else { break }

                        if !isRangeProtected(variantRange) {
                            replacements.append((range: variantRange, target: fallback.target))
                        }

                        searchStart = variantRange.upperBound
                    }

                    for repl in replacements.reversed() {
                        let result = replaceWithParticleFix(
                            in: out,
                            range: repl.range,
                            replacement: repl.target
                        )
                        out = result.text

                        if let newRange = result.replacedRange {
                            ranges.append(.init(entry: entry, range: newRange, type: .normalized))
                            protectedRanges.append(newRange)
                            protectedRanges.sort { $0.lowerBound < $1.lowerBound }
                        }
                    }
                }
            }
        }
    }

    return (out, ranges, preNormalizedRanges)
}
```

### 4.2 보호 범위 및 추적 메커니즘

**핵심 요구사항:** Phase 4는 **반드시** Phase 1-3에서 이미 정규화된 범위를 보호해야 함

**구현 전략:**

**1. 보호 범위 수집**
```swift
// Phase 1-3에서 추적된 ranges를 보호 범위로 사용
var protectedRanges: [Range<String.Index>] = ranges.map { $0.range }
```

**2. 겹침 검사**
```swift
func isRangeProtected(_ testRange: Range<String.Index>) -> Bool {
    return protectedRanges.contains { $0.overlaps(testRange) }
}
```

**3. Phase 4 범위 추적 (필수)**
- Phase 4 교체도 `ranges` 배열에 추가
- 오버레이 하이라이팅에 표시됨
- 디버깅 및 검증에 유용

**이점:**

1. **동음이의어 구분 유지:** Phase 1-3에서 구분된 용어는 Phase 4에서 재교체되지 않음
   ```
   예: "凯" → "가이", "k" → "케이" 매핑이 유지됨
   Phase 4가 "케이"를 "가이"로 바꾸지 않음
   ```

2. **완전한 하이라이팅:** Phase 4 정규화도 오버레이에 표시됨

3. **범위 무효화 방지:** 역순 교체로 String.Index 무효화 최소화

4. **조사 교정:** `replaceWithParticleFix` 사용으로 문법 유지

### 4.3 보호 알고리즘 상세

**동음이의어 문제 재발 방지:**

Phase 4의 가장 중요한 기능은 **Phase 1-3에서 해결한 동음이의어 구분을 파괴하지 않는 것**입니다.

**문제 시나리오 (보호 없는 경우):**
```
원문: "凯和k,凯的情人的伽古拉去了学校"
용어: "凯" → "가이" (variants: ["케이", "카이"]), "k" → "케이"
번역: "카이와 케이, 카이의 연인 가고라가 학교에 갔다"

Phase 1-3 정규화 결과:
- "카이" (1번째) → "가이" (凯)
- "케이" → "케이" (k) ← 올바르게 유지됨
- "카이" (2번째) → "가이" (凯)

보호 없는 Phase 4:
- replacingOccurrences("케이", "가이") ← "k"의 매핑 파괴! ❌
→ "가이와 가이, 가이의 연인 가고라가 학교에 갔다" (잘못됨)

보호 있는 Phase 4:
- "케이" 발견 → Phase 1-3 ranges 확인 → 보호됨 → 교체 안 함 ✅
→ "가이와 케이, 가이의 연인 가고라가 학교에 갔다" (올바름)
```

**보호 로직 세부사항:**

```swift
// 1. Phase 1-3에서 정규화된 모든 범위 수집
var protectedRanges: [Range<String.Index>] = ranges.map { $0.range }

// 2. variant 발견 시 보호 여부 확인
let variantRange = out.range(of: "케이", ...)

// 3. 겹침 검사
let isProtected = protectedRanges.contains(where: { protectedRange in
    variantRange.overlaps(protectedRange)
})
// 예: variantRange = "케이"의 위치
//     protectedRange = Phase 1-3에서 정규화된 "케이" (k → 케이)
//     → overlaps = true → 교체 안 함

// 4. 보호되지 않은 경우만 교체
if !isProtected {
    // 이것은 추가 인스턴스 (엔진이 추가한 것)
    replaceWithParticleFix(...)
}
```

**범위 업데이트 전략:**

Phase 4에서 교체할 때마다 `protectedRanges`를 업데이트하여, 같은 Phase 4 내에서도 이미 처리한 인스턴스를 보호:

```swift
for repl in replacements.reversed() {
    let result = replaceWithParticleFix(...)
    out = result.text

    if let newRange = result.replacedRange {
        // ranges에 추가 (하이라이팅용)
        ranges.append(.init(entry: entry, range: newRange, type: .normalized))

        // protectedRanges에도 추가 (같은 Phase 4 내 보호용)
        protectedRanges.append(newRange)
        protectedRanges.sort { $0.lowerBound < $1.lowerBound }
    }
}
```

**하이라이팅 시스템과의 통합:**

Phase 4에서 추적된 범위는 기존 하이라이팅 인프라를 그대로 사용:

```
normalizeWithOrder() 반환:
├─ ranges: [TermRange] ← Phase 1-4 모두 포함
│   └─ 각 TermRange: (entry, range, type: .normalized)
│
DefaultTranslationRouter.restoreOutput():
├─ normalizationRanges.append(contentsOf: normalized.ranges)
│
TermHighlightMetadata:
├─ finalTermRanges: [..., Phase 4 ranges]
│
OverlayPanel:
└─ 초록 배경으로 Phase 4 정규화 표시 ✅
```

---

## 5. 엣지 케이스 및 처리 전략

### 5.1 엣지 케이스: 중복 variant

**시나리오:**
```
용어집:
- 용어 A: target="케빈", variants=["Kevin", "케이빈"]
- 용어 B: target="케이", variants=["K", "Kay"]

번역문: "케이빈이 왔다"
- "케이빈" (용어 A variant) 또는 "케이" + "빈" (용어 B variant + 무관한 텍스트)로 매칭 가능
```

**처리:**
- Phase 1은 더 긴 매칭을 먼저 처리 (`findNextCandidate`가 순서대로 candidates를 확인)
- Phase 4는 임의 순서로 처리
- **완화:** 교체 전에 variant를 길이순(내림차순)으로 정렬
- **상태:** 이미 Phase 1-3에서 처리됨; Phase 4는 이런 경우를 마주칠 가능성 낮음

### 5.2 엣지 케이스: 조사 경계 이슈

**시나리오:**
```
번역문: "케빈이" (variant "케빈" + 조사 "이")
Phase 4가 "케빈" → "케빈" (target)로 교체
조사 "이"는 target의 받침에 따라 조정 필요할 수 있음
```

**처리:**
- Phase 4는 조사 교정을 수행하지 않음 (Phase 1-2는 `replaceWithParticleFix` 사용)
- **근거:** Phase 4는 같은 용어의 variant→target 교체이므로 받침 상태가 바뀔 가능성 낮음
- **대안:** 필요시 Phase 4에 조사 교정 추가 (복잡도 증가)
- **권장사항:** 조사 교정 없이 시작; 문제 발생 시 추가

### 5.3 엣지 케이스: 대소문자 구분

**시나리오:**
```
Variants: ["Kevin", "kevin", "KEVIN"]
번역문: "Kevin은... kevin이... KEVIN도..."
```

**처리:**
- `replacingOccurrences`에 `.caseInsensitive` 옵션 사용
- 대소문자와 무관하게 모든 variant 정규화

### 5.4 엣지 케이스: 다수의 동음이의어

**시나리오:**
```
원문: "凯文·杜兰特和凯和凯文去了学校"
- 같은 target "케빈"을 가진 두 개의 다른 "凯" 용어

용어집:
- "凯" (인물 A) → "케빈"
- "凯文" (인물 B) → "케빈"

번역: "케빈 듀란트와 케빈과 케빈이 학교에 갔다"
```

**처리:**
- **Phase 1-3:** 원문 순서에 따라 각각 정규화
  - 1번째 "케빈" → "케빈" (凯文)
  - 2번째 "케빈" → "케빈" (凯)
  - 3번째 "케빈" → "케빈" (凯文)
- **Phase 4:** 모든 "케빈"이 이미 Phase 1-3에서 처리됨 → protectedRanges에 포함 → 교체 안 함 ✅
- **보호 메커니즘:** Phase 1-3 ranges가 모두 보호되므로 Phase 4는 실제로 아무것도 교체하지 않음
- **위험:** 낮음 (보호 로직으로 해결됨)
- **결과:** 동음이의어 구분이 안전하게 유지됨

### 5.5 엣지 케이스: 빈 variant

**시나리오:**
```
variants = ["", "Kevin", ""]
```

**처리:**
- Guard 절: `guard !variant.isEmpty else { continue }`
- 빈 문자열 교체 방지

---

## 6. 예상되는 동작 변경

### 6.1 기능적 변경

**이전 (3단계):**
- 추가 번역문 인스턴스는 정규화되지 않고 남음
- 표준 케이스에 대해 70-90% 정규화 정확도
- 추가 인스턴스에 대해 0% 커버리지 (1:N, N > 1인 경우)
- 동음이의어 구분: Phase 1-3에서 처리

**이후 (4단계):**
- 추가 번역문 인스턴스가 보호 범위 존중하며 정규화됨
- 첫 번째 인스턴스에 대해 70-90% 정확도 유지 (Phase 1-3)
- 추가 인스턴스에 대해 ~90-95% 커버리지 (Phase 4)
- **동음이의어 구분 유지:** Phase 1-3에서 구분된 용어는 Phase 4에서 재교체 안 됨 ✅
- 전체 개선: +10-20% 커버리지
- 하이라이팅: Phase 4 정규화도 오버레이에 표시됨

### 6.2 성능 영향

**시간 복잡도:**
- Phase 4 추가: O(P × V × T), 여기서:
  - P = 처리된 target 수
  - V = target당 평균 variant 수
  - T = 번역문 텍스트 길이
- 일반적 값: P ≈ 5-10, V ≈ 3-5, T ≈ 100-500 문자
- **예상 영향:** 세그먼트당 +5-15ms (무시 가능)

**메모리 영향:**
- `processedTargets` Set: O(P) ≈ 50-200 바이트
- 추가 데이터 구조 없음
- **예상 영향:** 무시 가능

### 6.3 사용자 가시적 변경

- 자연스러운 번역에 대한 번역 품질 개선
- 최종 출력에 남는 variant 형태 감소
- 엔진이 명확한 용어를 추가할 때 더 나은 일관성
- 기존 동작에 대한 파괴적 변경 없음

---

## 7. 테스트 전략

### 7.1 단위 테스트

**테스트 1: 기본 추가 인스턴스 정규화**
```swift
func testPhase4NormalizesExtraInstances() {
    // 설정
    let source = "凯文说话"
    let pieces = SegmentPieces(/* term(凯文) × 1 */)
    let glossaries = [NameGlossary(
        target: "케빈",
        variants: ["케이빈", "Kevin"],
        expectedCount: 1,
        fallbackTerms: nil
    )]

    // 번역 엔진이 추가 인스턴스 추가
    let translation = "케빈이 말할 때, 케빈도"

    // 실행
    let result = normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: glossaries
    )

    // 검증
    XCTAssertEqual(result.text, "케빈이 말할 때, 케빈도")
    // 두 인스턴스 모두 정규화됨
}
```

**테스트 2: 혼합 variant**
```swift
func testPhase4NormalizesDifferentVariants() {
    let translation = "케이빈이 말할 때, Kevin도"
    // "케이빈"과 "Kevin" 모두 "케빈"으로 정규화되어야 함
    let result = normalizeWithOrder(...)
    XCTAssertEqual(result.text, "케빈이 말할 때, 케빈도")
}
```

**테스트 3: 미처리 용어에 대한 가양성 없음**
```swift
func testPhase4SkipsUnprocessedTerms() {
    // Phase 1-3에서 실패하는 용어로 설정
    let glossaries = [NameGlossary(
        target: "존",
        variants: ["John"],
        expectedCount: 1,
        fallbackTerms: nil
    )]

    // 번역문에 "John"이 있지만 원문에는 "제임스" (다른 용어)
    let translation = "John이 왔다"
    let pieces = SegmentPieces(/* term(제임스) */)

    // 실행
    let result = normalizeWithOrder(...)

    // 검증: "John"은 정규화되지 않음 (processed set에 없음)
    XCTAssertEqual(result.text, "John이 왔다")
}
```

### 7.2 통합 테스트

**테스트 4: 추가 인스턴스가 있는 전체 파이프라인**
```swift
func testFullPipelineWith1ToNMapping() {
    // 실제 번역을 사용한 end-to-end 테스트
    let input = Segment(text: "凯文·杜兰特和杜兰特去了学校")

    // "凯문"을 명확히 하기 위해 추가하는 번역 엔진 모의
    mockEngine.mockOutput = "케빈 듀란트와 케빈, 그리고 듀란트가 학교에 갔다"

    // 전체 번역 실행
    let result = router.translate(input)

    // 모든 인스턴스가 정규화되었는지 검증
    XCTAssertTrue(result.output.contains("케빈 듀란트"))
    XCTAssertFalse(result.output.contains("케이빈"))
    XCTAssertFalse(result.output.contains("Kevin"))
}
```

### 7.3 회귀 테스트

**테스트 5: 기존 동작 유지**
```swift
func testPhase123BehaviorUnchanged() {
    // Phase 1-3이 여전히 이전처럼 작동하는지 검증
    let standardCases = [/* 기존 테스트 케이스들 */]

    for testCase in standardCases {
        let result = normalizeWithOrder(...)
        XCTAssertEqual(result, testCase.expected)
    }
}
```

### 7.4 엣지 케이스 테스트

**테스트 6: 빈 variant**
```swift
func testPhase4HandlesEmptyVariants() {
    let glossaries = [NameGlossary(
        target: "케빈",
        variants: ["", "Kevin", ""],  // 빈 문자열
        expectedCount: 1,
        fallbackTerms: nil
    )]

    let result = normalizeWithOrder(...)
    // 크래시하지 않아야 하며, "Kevin"을 정규화해야 함
}
```

**테스트 7: 대소문자 구분 없음**
```swift
func testPhase4CaseInsensitive() {
    let translation = "KEVIN과 kevin과 Kevin"
    let result = normalizeWithOrder(...)
    XCTAssertEqual(result.text, "케빈과 케빈과 케빈")
}
```

**테스트 8: 보호 범위 존중 (동음이의어 구분 유지)**
```swift
func testPhase4RespectsProtectedRanges() {
    // SPEC_ORDER_BASED_NORMALIZATION 예시
    let source = "凯和k,凯的情人的伽古拉去了学校"
    let pieces = SegmentPieces(/* term(凯), term(k), term(凯), term(伽古拉) */)

    let glossaries = [
        NameGlossary(
            target: "가이",
            variants: ["케이", "카이"],  // "케이"는 "k"의 올바른 번역이기도 함!
            expectedCount: 2,
            fallbackTerms: nil
        ),
        NameGlossary(
            target: "케이",  // "k" → "케이"
            variants: [],
            expectedCount: 1,
            fallbackTerms: nil
        ),
        NameGlossary(
            target: "쟈그라",
            variants: ["가고라"],
            expectedCount: 1,
            fallbackTerms: nil
        )
    ]

    // 번역 엔진 출력
    let translation = "카이와 케이, 카이의 연인 가고라가 학교에 갔다"

    // 실행
    let result = normalizeWithOrder(
        in: translation,
        pieces: pieces,
        nameGlossaries: glossaries
    )

    // 검증: "k" → "케이" 매핑이 유지되어야 함
    XCTAssertEqual(result.text, "가이와 케이, 가이의 연인 쟈그라가 학교에 갔다")
    //                                   ^^^ Phase 1-3에서 "k"로 매핑됨
    //                                       Phase 4가 이것을 "가이"로 바꾸면 안 됨!

    // ranges 검증: "케이"가 보호된 범위로 추적됨
    let keiRange = result.ranges.first { range in
        let text = String(result.text[range.range])
        return text == "케이" && range.entry.source == "k"
    }
    XCTAssertNotNil(keiRange, "k → 케이 매핑이 ranges에 있어야 함")
}
```

**테스트 9: Phase 4 범위가 하이라이팅에 포함됨**
```swift
func testPhase4RangesAreTracked() {
    let source = "凯文说话"
    let pieces = SegmentPieces(/* term(凯文) × 1 */)
    let glossaries = [NameGlossary(
        target: "케빈",
        variants: ["케이빈"],
        expectedCount: 1,
        fallbackTerms: nil
    )]

    // 엔진이 추가 인스턴스 추가
    let translation = "케빈이 말할 때, 케이빈도"

    // 실행
    let result = normalizeWithOrder(...)

    // 검증: Phase 4에서 정규화된 두 번째 "케빈"도 ranges에 포함
    XCTAssertEqual(result.ranges.count, 2, "Phase 1과 Phase 4 ranges 모두 추적되어야 함")

    // 모든 ranges가 .normalized 타입
    for range in result.ranges {
        XCTAssertEqual(range.type, .normalized)
    }
}
```

---

## 8. 성능 고려사항

### 8.1 알고리즘 복잡도

**Phase 4 복잡도:**
```
처리된 각 target (P)에 대해:
    각 variant (V)에 대해:
        replacingOccurrences → O(T)
전체: O(P × V × T)
```

**일반적 값:**
- P (세그먼트당 처리된 target): 5-10
- V (target당 variant): 3-5
- T (번역문 텍스트 길이): 100-500 문자

**예상 연산:**
- 최악의 경우: 10 × 5 × 500 = 25,000 문자 비교
- 최신 CPU: 세그먼트당 ~1-2ms
- 번역 엔진 호출(~100-1000ms)에 비해 무시 가능

### 8.2 최적화 기회

**옵션 1: variant를 정규식으로 결합** (향후 최적화)
```swift
// 다음 대신:
for variant in variants {
    out = out.replacingOccurrences(of: variant, with: target)
}

// 사용:
let pattern = variants.map { NSRegularExpression.escapedPattern(for: $0) }
                      .joined(separator: "|")
let regex = try NSRegularExpression(pattern: pattern)
out = regex.stringByReplacingMatches(in: out, ..., withTemplate: target)
```
**이점:** V번의 패스 대신 1번의 패스
**복잡도:** V × T를 target당 1 × T로 감소
**트레이드오프:** 정규식 컴파일 오버헤드 추가

**권장사항:** 간단한 구현부터 시작; 프로파일링에서 Phase 4가 병목으로 나타나면 최적화

### 8.3 메모리 프로파일

**추가 메모리:**
- `processedTargets` Set: sizeof(String) × P ≈ 200-500 바이트
- 루프 내 임시 문자열: 무시 가능 (컴파일러 최적화)
- **전체:** 세그먼트당 < 1 KB

**영향:** 기존 정규화 오버헤드에 비해 무시 가능

---

## 9. 기존 코드와의 통합 지점

### 9.1 수정된 함수 시그니처

**변경 없음** - Phase 4는 `normalizeWithOrder()` 내부:
```swift
func normalizeWithOrder(
    in text: String,
    pieces: SegmentPieces,
    nameGlossaries: [NameGlossary]
) -> (text: String, ranges: [TermRange], preNormalizedRanges: [TermRange])
```

### 9.2 호출 사이트

**변경 불필요** - 모든 기존 호출자가 그대로 작동:
- `DefaultTranslationRouter.restoreOutput()` (548번째 줄)
- `normalizeWithOrder()`의 향후 호출자

### 9.3 데이터 흐름

```
입력: 번역 텍스트, SegmentPieces, NameGlossaries
  ↓
Phase 1: 순차 매칭 (target + variants)
  ↓ processed Set 업데이트
Phase 2: 패턴 fallback
  ↓ processed Set 업데이트
Phase 3: 전역 검색 (미처리 용어)
  ↓
**Phase 4: 처리된 용어에 대한 variant 일괄 교체** ← 신규
  ↓
출력: (정규화된 텍스트, ranges, preNormalizedRanges)
```

### 9.4 SegmentPieces 의존성

**현재 사용:**
```swift
let unmaskedTerms: [(index: Int, entry: GlossaryEntry)] =
    pieces.pieces.enumerated().compactMap { idx, piece in
        if case .term(let entry, _) = piece, entry.preMask == false {
            return (index: idx, entry: entry)
        }
        return nil
    }
```

**Phase 4 사용:**
```swift
let processedTargets = Set(
    processed.compactMap { idx -> String? in
        guard case .term(let entry, _) = pieces.pieces[idx] else { return nil }
        return entry.target
    }
)
```

**의존성:** `SegmentPieces.pieces` enum 구조에 의존
**위험:** 낮음 - SegmentPieces는 안정적 (SPEC_SEGMENT_PIECES_REFACTORING에 따라 이미 구현)

---

## 10. 검토된 대안 접근법

### 10.1 대안 1: 번역문 인스턴스 카운팅 + 재순회

**접근법:**
```swift
// 번역문의 실제 인스턴스 카운트
let actualCounts = countInstancesInTarget(out, nameGlossaries)

// expectedCount와 비교
for (target, actualCount) in actualCounts {
    if actualCount > expectedCount {
        // 추가 인스턴스 재실행
    }
}
```

**장점:**
- 더 정확함 (정확히 몇 개 추가인지 알 수 있음)
- 특정 위치 추적 가능

**단점:**
- 더 높은 복잡도
- 카운팅 로직 필요
- 어떤 특정 인스턴스가 "추가"인지 판단 어려움
- 순차 매칭을 재실행해야 할 수 있음

**판정:** 거부 - 미미한 이점 대비 너무 복잡함

### 10.2 대안 2: 범위 기반 매칭 (향후)

**접근법:**
```swift
// 원문 범위 힌트를 사용하여 번역문 범위 매칭
for extra instance {
    원문 범위를 기반으로 위치 추정
    해당 영역에서 검색
}
```

**장점:**
- 가장 높은 정확도 잠재력 (90-95%)
- 순서가 바뀐 번역을 더 잘 처리

**단점:**
- SegmentPieces에 범위 정보 필요 (아직 사용 불가)
- 복잡한 위치 추정
- 더 큰 리팩터링 노력

**판정:** 연기 - 좋은 향후 개선 (Phase 5+)

### 10.3 대안 3: 아무것도 하지 않음

**접근법:**
- 70-90% 커버리지를 충분한 것으로 수용
- 알려진 제약으로 문서화

**장점:**
- 구현 노력 없음
- 회귀 위험 없음

**단점:**
- 사용자 가시적 품질 문제 남김
- 쉬운 개선 기회 놓침

**판정:** 거부 - Phase 4는 낮은 위험, 높은 가치

---

## 11. 위험 분석

### 11.1 위험: 가양성 정규화

**시나리오:** Phase 4가 정규화되어서는 안 되는 variant를 정규화

**예시:**
```
원문: "케빈" 용어 있음 (Kevin Durant)
번역문: "케빈이... Kevin은..." (Kevin Durant 언급, 그 다음 Kevin Hart)
Phase 4: "Kevin" (Kevin Hart) → "케빈"으로 정규화 (잘못됨!)
```

**가능성:** 낮음 - 다음이 필요:
1. 같은 target 이름을 가진 여러 다른 개체
2. Phase 1-3이 하나는 처리하지만 다른 하나는 처리하지 않음
3. 두 번째 개체가 variant 형태 사용

**완화:**
- Phase 1-3이 모든 원문 용어 인스턴스를 처리해야 함
- 진정으로 "추가"된 인스턴스만 남아야 함
- 원문에 여러 인스턴스가 있으면 Phase 1-3이 모두 처리하고 모두 보호됨

**심각도:** 중간 - 혼란 야기 가능 (하지만 보호 로직으로 대부분 완화됨)

**권장사항:** 테스트에서 모니터링; 드물면 엣지 케이스로 수용

### 11.1.1 위험: 동음이의어 구분 파괴 (해결됨)

**시나리오:** Phase 4가 Phase 1-3에서 구분한 동음이의어를 재교체

**예시:**
```
원문: "凯和k" → 용어: "凯" → "가이" (variants: ["케이"]), "k" → "케이"
번역: "카이와 케이"
Phase 1-3: "카이" → "가이", "케이" → "케이" (올바름)
보호 없는 Phase 4: "케이" → "가이" (파괴!)
```

**가능성:** ~~높음~~ → **해결됨 (보호 로직 추가)**

**완화:**
- ✅ **보호 범위 메커니즘:** Phase 1-3에서 정규화된 범위는 protectedRanges에 포함
- ✅ **겹침 검사:** Phase 4는 보호된 범위와 겹치는 variant를 교체하지 않음
- ✅ **테스트 8:** `testPhase4RespectsProtectedRanges()`로 검증

**심각도:** ~~높음~~ → **낮음 (보호 로직으로 해결)**

**상태:** ✅ **해결됨** - Section 4.3 보호 알고리즘으로 완전히 방지

### 11.2 위험: 성능 저하

**시나리오:** Phase 4가 수용 불가한 지연 추가

**가능성:** 매우 낮음
- 예상: 세그먼트당 1-2ms
- 번역 엔진 호출: 100-1000ms
- 상대적 영향: < 1%

**완화:**
- 이전/이후 프로파일링
- 세그먼트당 > 5ms면 최적화

**심각도:** 낮음

### 11.3 위험: 기존 동작 파괴

**시나리오:** Phase 4가 기존 테스트 케이스의 출력을 변경

**가능성:** 매우 낮음
- Phase 4는 추가 인스턴스에만 작용
- 추가 인스턴스가 없으면 변경 없음
- 기존 테스트는 균형 잡힌 원문/번역문 인스턴스를 가짐

**완화:**
- 포괄적인 회귀 테스트
- 병합 전 이전/이후 side-by-side 비교

**심각도:** 발생 시 높음

**권장사항:** 병합 전 철저한 테스트

---

## 12. 구현 체크리스트

### 단계 1: 코드 구현
- [ ] `normalizeWithOrder()`의 Phase 3 이후에 Phase 4 로직 추가
- [ ] **Phase 1-3 ranges를 protectedRanges로 수집**
- [ ] `isRangeProtected()` 헬퍼 함수 구현
- [ ] `processed` set에서 `processedTargets` 추출
- [ ] **variant를 길이순(내림차순) 정렬**
- [ ] **보호되지 않은 variant 위치 수집 루프 구현**
- [ ] 빈 variant guard 추가
- [ ] **역순 교체로 범위 무효화 방지**
- [ ] **Phase 4 ranges를 ranges 배열에 추가**
- [ ] **protectedRanges 업데이트 (Phase 4 내 보호)**
- [ ] fallback variant 처리 포함 (동일한 보호 로직)
- [ ] 컴파일하고 문법 오류 없는지 확인

### 단계 2: 단위 테스트
- [ ] 기본 추가 인스턴스 정규화 테스트
- [ ] 혼합 variant 테스트 (다른 형태들)
- [ ] 미처리 용어는 건너뛰는지 테스트
- [ ] 빈 variant 처리 테스트
- [ ] 대소문자 구분 없음 테스트
- [ ] **보호 범위 존중 테스트 (동음이의어 구분 유지)** ← 중요!
- [ ] **Phase 4 범위 추적 테스트 (하이라이팅)**
- [ ] 모든 단위 테스트 통과

### 단계 3: 통합 테스트
- [ ] 1:N 매핑을 사용한 end-to-end 테스트
- [ ] 실제 번역 엔진을 사용한 테스트
- [ ] 범위 추적 검증 (구현된 경우)
- [ ] 모든 통합 테스트 통과

### 단계 4: 회귀 테스트
- [ ] 기존 테스트 스위트 실행
- [ ] Phase 1-3 변경 없는지 검증
- [ ] 이전/이후 출력 비교
- [ ] 회귀 감지 안 됨

### 단계 5: 성능 테스트
- [ ] Phase 4 실행 시간 측정
- [ ] 메모리 사용량 프로파일링
- [ ] 세그먼트당 < 5ms 오버헤드 검증
- [ ] 수용 가능한 성능

### 단계 6: 코드 리뷰 & 문서화
- [ ] 팀 코드 리뷰
- [ ] PROJECT_OVERVIEW.md 업데이트 (정규화 섹션)
- [ ] BUGS.md 업데이트 (BUG-004를 수정됨으로 표시)
- [ ] 인라인 코드 주석 추가
- [ ] TODO.md 업데이트

---

## 13. 성공 기준

### 13.1 기능 기준

- [ ] 추가 번역문 인스턴스가 성공적으로 정규화됨
- [ ] Phase 1-3 동작 변경 없음 (회귀 테스트 통과)
- [ ] BUG-004 시나리오 해결됨
- [ ] 새로운 버그 도입 안 됨

### 13.2 성능 기준

- [ ] Phase 4 오버헤드 < 세그먼트당 5ms
- [ ] 메모리 사용량 증가 < 세그먼트당 1 KB
- [ ] 전체 정규화 시간 증가 < 10%

### 13.3 품질 기준

- [ ] Phase 4 코드의 테스트 커버리지 > 80%
- [ ] 모든 엣지 케이스 테스트됨
- [ ] 코드 리뷰 승인됨
- [ ] 문서화 완료됨

---

## 14. 향후 개선 방향

### 14.1 Phase 5: 델타 추적 개선 (선택사항)

**동기:** 현재 Phase 4는 범위 추적을 하지만, 델타 계산은 하지 않음

**현재 상태:**
- Phase 4는 이미 `ranges`에 교체된 범위를 추가함 ✅
- 오버레이 하이라이팅에 표시됨 ✅
- 하지만 `cumulativeDelta`는 업데이트하지 않음 (Phase 1-3와 달리)

**구현 (선택사항):**
```swift
// Phase 4에서도 델타 추적 추가
var cumulativeDelta = 0  // Phase 1-3의 델타 이어받기

for repl in replacements.reversed() {
    let oldLen = repl.range.count
    let result = replaceWithParticleFix(...)
    let newLen = result.replacedRange?.count ?? 0

    cumulativeDelta += (newLen - oldLen)
    // ... 범위 조정에 델타 사용
}
```

**이점:** preNormalizedRanges 계산 시 더 정확한 델타 사용 가능
**노력:** 낮음
**우선순위:** 낮음 (현재 ranges 추적만으로도 충분함)

### 14.2 Phase 6: Phase 4에서 조사 교정

**동기:** 추가 인스턴스가 잘못된 조사를 가질 수 있음

**구현:**
```swift
// 각 일괄 교체 후
for each replacement {
    fixParticles(at: replacementRange)
}
```

**이점:** 추가 인스턴스의 문법 개선
**노력:** 중간
**위험:** Phase 4를 느리게 할 수 있음

### 14.3 Phase 7: 인스턴스 매칭을 위한 머신러닝

**동기:** 모호한 경우의 정확도 개선

**접근법:**
- 사용자 수정에서 패턴 학습
- 매핑에 대한 신뢰도 점수 구축
- Phase 4에서 적용하여 정규화할 인스턴스 결정

**이점:** 더 높은 정확도 (95%+)
**노력:** 높음
**타임라인:** 장기

---

## 15. 참고 자료

### 15.1 관련 문서

- `BUGS.md:423-801` - BUG-004 전체 설명
- `History/SPEC_ORDER_BASED_NORMALIZATION.md` - 현재 3단계 알고리즘 스펙
- `PROJECT_OVERVIEW.md` - 프로젝트 아키텍처
- `History/SPEC_SEGMENT_PIECES_REFACTORING.md` - SegmentPieces 구현

### 15.2 주요 파일

- `/Users/sailor.m/PrivateDevelop/MyTranslation/MyTranslation/Services/Translation/Masking/Masker.swift:1199-1327` - `normalizeWithOrder()` 구현
- `/Users/sailor.m/PrivateDevelop/MyTranslation/MyTranslation/Domain/Models/SegmentPieces.swift` - SegmentPieces 구조
- `/Users/sailor.m/PrivateDevelop/MyTranslation/MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift:548` - 통합 지점

### 15.3 관련 이슈

- BUG-002: 공백 삭제 버그 (수정됨) - 유사한 델타 계산 이슈
- BUG-001: 조사 매칭 버그 (진행 중) - 조사 교정 관련

---

**문서 상태:** 구현 준비 완료
**예상 구현 시간:** 4-6시간
**예상 테스트 시간:** 3-4시간
**전체 노력:** 1일

**작성자:** Claude Code
**검토자:** [할당 예정]
**승인:** [대기 중]

---

## 결론

이 스펙은 BUG-004를 해결하기 위한 Phase 4 - 잔여 일괄 교체에 대한 포괄적이고 구현 준비가 완료된 설계를 제공합니다.

**핵심 설계 결정:**

1. **하이브리드 접근:** 순차 매칭(Phase 1-3)의 높은 정확도를 유지하면서 일괄 교체(Phase 4)를 통해 추가 인스턴스 커버리지 추가

2. **보호 범위 메커니즘 (핵심!):** Phase 1-3에서 정규화된 범위를 보호하여 동음이의어 구분 파괴 방지
   - 순번 기반 정규화의 핵심 장점 유지
   - "凯" → "가이", "k" → "케이" 같은 구분이 Phase 4에서 파괴되지 않음

3. **완전한 범위 추적:** Phase 4 정규화도 ranges에 추가하여 오버레이 하이라이팅 지원

4. **기존 인프라 재사용:**
   - TermRange, TermHighlightMetadata 그대로 사용
   - DefaultTranslationRouter.restoreOutput() 수정 불필요
   - 오버레이 패널 자동 지원

**예상 효과:**

- ✅ 추가 인스턴스 커버리지: 0% → 90-95%
- ✅ 동음이의어 구분 유지 (보호 로직)
- ✅ 완전한 하이라이팅 지원
- ✅ 최소한의 성능 오버헤드 (~1-2ms)
- ✅ 기존 동작 파괴 없음

**구현 난이도:** 중간 (보호 로직 추가로 초기 제안보다 복잡하지만, 동음이의어 구분 유지를 위해 필수)
