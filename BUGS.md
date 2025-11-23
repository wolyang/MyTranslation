# BUGS.md — 버그 목록 및 분석

이 문서는 발견된 버그들과 원인 분석을 기록합니다.
나중에 일괄 수정할 수 있도록 상세한 분석 내용을 포함합니다.

---

## 🐛 BUG-001: TermMasker 사후정규화에서 '이렇게'가 '가렇게'로 잘못 변환

### 발견일
2025-11-23

### 증상
번역 결과에서 한글 부사 "이렇게"가 "가렇게"로 잘못 정규화되는 현상

**예시:**
- **입력:** "히카리는 이렇게 말하며 엑스와 다이치가 있는 방향을 바라보았다."
- **잘못된 출력:** "히카리는 가렇게 말하며 엑스와 다이치가 있는 방향을 바라보았다."

### 원인 분석

**파일:** [Masker.swift:913](MyTranslation/Services/Translation/Masking/Masker.swift#L913)

```swift
.init(noBatchim: "가", withBatchim: "이", rieulException: false, prefersWithBatchimWhenAuxAttached: true),
```

#### 버그 발생 흐름

1. 원본 텍스트: "히카리는 **이렇게** 말하며..."
2. 번역/정규화 후, "이렇게" 앞의 어떤 용어가 정규화됨
3. `fixParticles()` 함수([Masker.swift:1715-1783](MyTranslation/Services/Translation/Masking/Masker.swift#L1715-L1783))가 호출되어 조사를 교정하려 함
4. 정규식 패턴이 공백 + "이"를 **조사(이/가)**로 잘못 매칭
5. `chooseJosa()` 함수([Masker.swift:977-1092](MyTranslation/Services/Translation/Masking/Masker.swift#L977-L1092))가 앞 단어의 받침을 보고 "가"를 선택
6. 결과: "이렇게" → "**가렇게**"

#### 근본 원인

조사 매칭 로직(`particleTokenAlternation` 정규식)이 다음을 구분하지 못함:

| 경우 | 예시 | 설명 |
|------|------|------|
| **"이"가 조사일 때** | "히카리**이** 말했다" | 주격 조사 (히카리가) |
| **"이"가 단어의 일부일 때** | "**이**렇게", "**이**것", "**이**번" | 부사/대명사의 일부 |

현재 정규식 패턴이 정규화된 용어 바로 뒤에 오는 "이"를 무조건 조사로 간주하여,
부사 "이렇게"의 "이"까지 조사로 잘못 인식하고 교정을 시도함.

### 관련 코드 위치

1. **[Masker.swift:913](MyTranslation/Services/Translation/Masking/Masker.swift#L913)**
   - 조사 쌍(JosaPair) 정의: `"가"/"이"` 패턴

2. **[Masker.swift:1715-1783](MyTranslation/Services/Translation/Masking/Masker.swift#L1715-L1783)**
   - `fixParticles()` 함수: 정규화된 용어 뒤의 조사를 받침 규칙에 맞게 교정

3. **[Masker.swift:1732-1742](MyTranslation/Services/Translation/Masking/Masker.swift#L1732-L1742)**
   - `particleTokenAlternation` 정규식 생성: 조사 매칭 패턴

4. **[Masker.swift:977-1092](MyTranslation/Services/Translation/Masking/Masker.swift#L977-L1092)**
   - `chooseJosa()` 함수: 받침 유무에 따라 적절한 조사 형태 선택

### 제안 해결 방법

**옵션 1: 정규식 패턴 개선 (권장)**
- "이" 뒤에 특정 문자가 오면 조사로 인식하지 않도록 negative lookahead 추가
- 예: `"이"(?!렇게|것|번|리|때)` 형태로 일반적인 부사/대명사 패턴 제외

**옵션 2: 예외 단어 목록 관리**
- "이렇게", "이것", "이번", "이리", "이때" 등 일반적인 단어를 예외 목록으로 관리
- `fixParticles()` 함수에서 예외 목록 확인 후 교정 스킵

**옵션 3: 조사 매칭 조건 강화**
- 조사 "이/가"는 명사 뒤에만 오므로, 앞 단어가 명사인지 확인하는 로직 추가
- (단, 품사 분석 필요로 구현 복잡도 높음)

### 영향 범위
- TermMasker의 사후정규화 로직 전반
- 한글 조사 자동 교정 기능을 사용하는 모든 번역 결과
- 특히 "이"로 시작하는 부사/대명사가 용어 정규화 직후에 오는 경우

### 우선순위
**중** - 번역 품질에 영향을 주지만, 모든 경우에 발생하지는 않음

---

## 🐛 BUG-002: 정규화 과정에서 용어 앞뒤 공백이 잘못 삭제되는 버그

### 발견일
2025-11-23

### 증상
정규화 대상 용어가 표준 번역과 동일하게 번역되어 실제로는 변경되지 않았음에도, 용어 앞뒤의 공백(띄어쓰기)이 정규화 과정에서 삭제되어 앞의 단어와 붙어버리는 현상

**예시:**
1. **입력:** "다시 사람으로 돌아온 리쿠는 제로의 손바닥에 서서 두 손을 꼭 쥐었다."
   **잘못된 출력:** "다시 사람으로 돌아온리쿠는 제로의 손바닥에 서서 두 손을 꼭 쥐었다."
   ('리쿠' 앞의 공백 삭제)

2. **입력:** "... 안고 있었다. 리쿠 역시 울트라맨이라는 걸 알면서도, ..."
   **잘못된 출력:** "...안고 있었다. 리쿠역시 울트라맨이라는 걸 알면서도, ..."
   ('리쿠' 앞뒤 공백 삭제)

**참고:** '리쿠'와 '제로'는 정규화 대상이지만 번역 엔진이 우연히 표준 번역과 동일하게 번역하여 실제로는 변경되지 않음. 그러나 공백만 삭제됨.

### 원인 분석

**핵심 파일:** [Masker.swift](MyTranslation/Services/Translation/Masking/Masker.swift)

#### 버그 발생 위치

이 버그는 `fixParticles()`, `replaceWithParticleFix()`, `normalizeWithOrder()` 세 함수의 상호작용에서 발생합니다.

**1. fixParticles() 함수 ([Masker.swift:1715-1783](MyTranslation/Services/Translation/Masking/Masker.swift#L1715-L1783))**

정규화된 용어 뒤의 한글 조사를 찾아 교정하는 함수입니다. 다음과 같은 정규식 패턴을 사용합니다:

```swift
let wsZ = "(?:\\s|\\u00A0|\\u200B|\\u200C|\\u200D|\\uFEFF)*"
let softPunct = "[\"'""'»«》〈〉〉》」』】）\\)\\]\\}]"
let gap = "(?:" + wsZ + "(?:" + softPunct + ")?" + wsZ + ")"
let pattern = "^(" + gap + ")(" + josaSequence + ")"
```

**문제점:**
- `gap` 패턴이 **0개 이상의 공백 문자**를 매칭할 수 있음
- 조사 교정이 필요 없을 때도 `gap`에 매칭된 공백을 소비함
- 1774번째 줄에서 원래 `canonRange`를 반환하지만, 이 범위는 매칭된 공백을 포함하지 않음

**2. replaceWithParticleFix() 함수 ([Masker.swift:1152-1175](MyTranslation/Services/Translation/Masking/Masker.swift#L1152-L1175))**

```swift
let (fixed, fixedRange) = fixParticles(...)
if let swiftRange = Range(fixedRange, in: fixed) {
    return (fixed, swiftRange, swiftRange.upperBound)  // nextIndex
}
```

**문제점:**
- `fixedRange`에서 `nextIndex`를 계산할 때, `fixParticles()`가 소비한 공백까지 포함됨
- 그러나 반환된 `fixedRange` 자체는 공백을 포함하지 않음
- `nextIndex`와 실제 교체된 범위 간의 불일치 발생

**3. normalizeWithOrder() 함수 ([Masker.swift:1238-1327](MyTranslation/Services/Translation/Masking/Masker.swift#L1238-L1327))**

델타 계산 코드 (1257-1258번째 줄):
```swift
let newLen = out.distance(from: out.startIndex, to: result.nextIndex) - lowerOffset
cumulativeDelta += (newLen - oldLen)  // 잘못된 델타!
```

**문제점:**
- `oldLen`은 `matched.range` 기반 (용어 자체의 길이만)
- `newLen`은 `result.nextIndex` 기반 (소비된 공백까지 포함)
- 델타 계산이 틀려져서 `preNormalizedRanges`의 범위가 잘못 계산됨
- 이후 작업에서 공백이 용어 범위에 잘못 포함되어 삭제됨

#### 버그 발생 흐름

"돌아온 리쿠는" 텍스트의 경우:

1. `normalizeWithOrder()`가 "리쿠" 발견 (이미 올바른 번역이므로 변경 불필요)
2. `matched.range`는 "리쿠"만 커버 (2글자)
3. `replaceWithParticleFix()` 호출 → `fixParticles()` 호출:
   - 정규식이 "리쿠" 뒤의 공백과 "는"을 매칭
   - `gap` 그룹에서 공백 소비
   - 조사 교정 불필요로 원래 `canonRange` 반환 ("리쿠"만)
4. 그러나 `result.nextIndex`는 공백을 지나간 위치를 가리킴
5. 1257번째 줄에서 `newLen` 계산 시 공백 포함
6. `oldLen` = 2, `newLen` = 3 (공백 포함)
7. `cumulativeDelta`에 +1 추가 (잘못된 값)
8. 이후 `preNormalizedRanges` 계산에 잘못된 델타 사용
9. 공백이 용어 범위에 포함되어 처리됨
10. 결과적으로 공백 삭제

### 관련 코드 위치

1. **[Masker.swift:1715-1783](MyTranslation/Services/Translation/Masking/Masker.swift#L1715-L1783)**
   - `fixParticles()` 함수: `gap` 패턴으로 공백을 소비하지만 반환 범위에 미포함
   - **1774번째 줄**: `return (out, canonRange)` - 공백 미포함 범위 반환

2. **[Masker.swift:1152-1175](MyTranslation/Services/Translation/Masking/Masker.swift#L1152-L1175)**
   - `replaceWithParticleFix()` 함수: `nextIndex` 계산에 소비된 공백 포함

3. **[Masker.swift:1238-1327](MyTranslation/Services/Translation/Masking/Masker.swift#L1238-L1327)**
   - `normalizeWithOrder()` 함수: 잘못된 델타 계산
   - **1238-1244번째 줄 (Phase 1)**: `oldLen` 계산 (용어만)
   - **1257-1258번째 줄**: `newLen` 계산 (공백 포함) → 잘못된 델타
   - **1275-1297번째 줄 (Phase 2)**: 동일한 문제

4. **[DefaultTranslationRouter.swift:514-593](MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift#L514-L593)**
   - `restoreOutput()` 함수: `normalizeWithOrder()` 호출 (548번째 줄)
   - 잘못된 `preNormalizedRanges` 사용 (545, 555, 585번째 줄)

### 제안 해결 방법

**옵션 1: nextIndex 대신 replacedRange 사용 (권장)**
- `normalizeWithOrder()`의 `newLen` 계산 시 `result.nextIndex` 대신 `result.replacedRange` 사용
- `nextIndex`는 검색 계속용이고, 델타 계산에는 실제 교체된 범위 사용해야 함

**옵션 2: fixParticles() 반환값 수정**
- `fixParticles()`가 `gap`에 매칭된 공백을 `canonRange`에 포함시켜 반환
- 또는 공백을 소비하지 않은 위치를 별도로 반환

**옵션 3: replaceWithParticleFix() nextIndex 수정**
- `nextIndex`를 실제 교체된 내용의 끝으로 설정 (소비된 공백 제외)

### 영향 범위
- TermMasker의 정규화 로직 전반
- 조사 교정 기능을 사용하는 모든 번역 결과
- 특히 정규화 대상이지만 실제로 변경되지 않은 용어의 앞뒤 공백
- `preNormalizedRanges` 계산 및 하이라이트 메타데이터

### 우선순위
**높음** - 텍스트 가독성에 직접적인 영향을 주며, 비교적 자주 발생 가능

---

## 🐛 BUG-003: preMask=true 용어가 패턴에 포함될 때 마스킹되지 않는 로직 문제

### 발견일
2025-11-23

### 증상 분류
**로직 설계 문제** - 코드 동작의 버그라기보다는 로직 설계의 구멍으로, 의도하지 않은 동작을 유발

### 증상
`preMask=true`로 설정된 용어가 `preMask=false`인 패턴에 포함될 경우, 번역 전 마스킹되지 않아 표준 번역 보장이 깨지는 현상

**배경:**
- `preMask=true` 용어는 번역 전 토큰으로 마스킹되어 항상 표준 번역 결과로 번역되어야 함
- 마스킹으로 인해 번역 품질이 다소 저하될 수 있지만, 번역 엔진이 토큰을 완전히 유실시키지 않는 한 일관된 번역이 보장되어야 함
- 그러나 해당 용어가 `preMask=false` 패턴에 포함되면 마스킹되지 않아, 번역 엔진이 가변적으로 번역할 수 있음

**예시 시나리오:**
- 용어 "红" (preMask=true, target="레드")
- 용어 "发" (preMask=false, target="헤어")
- 패턴 "person" (preMask=false, L="红", R="发")
- 원문: "红发"

**기대 동작:** "红"는 preMask=true이므로 항상 토큰으로 마스킹되어 "레드"로 번역
**실제 동작:** 패턴 엔트리의 preMask=false가 적용되어 마스킹되지 않음 → 번역 엔진이 "红发"를 가변적으로 번역 가능

### 원인 분석

**핵심 파일:**
- [GlossaryComposer.swift](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift)
- [Masker.swift](MyTranslation/Services/Translation/Masking/Masker.swift)

#### 근본 원인

**패턴 조합 시 preMask 플래그 결정 로직의 문제**

GlossaryComposer가 패턴 엔트리를 생성할 때, **패턴의 preMask 설정만을 사용하고 구성 요소 용어들의 preMask 플래그를 무시**합니다.

#### 버그 발생 흐름

**1. 패턴 조합 (GlossaryComposer.swift)**

**[GlossaryComposer.swift:150-211](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L150-L211)** - `buildEntriesFromPairs()`:
```swift
// 183번째 줄
preMask: pattern.preMask,  // 패턴의 플래그만 사용!
```

**[GlossaryComposer.swift:213-266](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L213-L266)** - `buildEntriesFromLefts()`:
```swift
// 242번째 줄
preMask: pattern.preMask,  // 패턴의 플래그만 사용!
```

**문제점:**
- 조합된 엔트리의 `preMask`는 `pattern.preMask`에서만 결정됨
- 구성 요소 용어들의 `preMask` 플래그는 `componentTerms` 배열에 저장되지만 마스킹 결정에 사용되지 않음

**2. 독립 용어 필터링 (GlossaryComposer.swift)**

**[GlossaryComposer.swift:29-31](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L29-L31)**:
```swift
let standaloneSourceSet = Set(standaloneEntries.map { $0.source })
let filteredComposed = composedEntries.filter { !standaloneSourceSet.contains($0.source) }
```

**결과:**
- "红" 단독 엔트리 (preMask=true)가 조합 엔트리 "红发"와 source가 겹쳐서 필터링됨
- 결과적으로 "红发" 조합 엔트리 (preMask=false)만 남음

**3. 마스킹 결정 (Masker.swift)**

**[Masker.swift:207-316](MyTranslation/Services/Translation/Masking/Masker.swift#L207-L316)** - `buildSegmentPieces()`:
- 224-247번째 줄: standalone, pattern-promoted, term-promoted 엔트리 결합
- 250번째 줄: source 중복 필터링 - 여기서 preMask=true 독립 용어가 제외됨

**[Masker.swift:318-380](MyTranslation/Services/Translation/Masking/Masker.swift#L318-L380)** - `maskFromPieces()`:
```swift
// 334번째 줄 - 마스킹 결정의 핵심
if entry.preMask {  // false for composed entry
    // 335-360번째 줄: 토큰 생성 및 마스킹
    let token = Self.makeToken(prefix: "E", index: localNextIndex)
    // ...
} else {
    // 361-366번째 줄: 마스킹 없이 source 그대로 사용
    out += entry.source
}
```

**문제점:**
- 조합 엔트리의 `preMask=false`만 확인
- 구성 요소 용어의 `preMask=true` 플래그는 전혀 고려되지 않음

#### ComponentTerm에서의 preMask 저장

**[GlossaryEntry.swift:6-48](MyTranslation/Domain/Glossary/Models/GlossaryEntry.swift#L6-L48)** - `ComponentTerm` 구조체:
```swift
// 22번째 줄
public let preMask: Bool  // 저장은 되지만 사용되지 않음
```

**[GlossaryComposer.swift:357-380](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L357-L380)** - `ComponentTerm.make()`:
```swift
// 374번째 줄
preMask: term.preMask,  // 용어의 preMask 복사
```

**결과:**
- 각 구성 요소의 preMask 플래그는 `componentTerms` 배열에 보존됨
- 그러나 이 정보는 참조용으로만 저장되고, 실제 마스킹 결정에는 사용되지 않음

### 관련 코드 위치

**1. 패턴 조합 로직**
- **[GlossaryComposer.swift:150-211](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L150-L211)**
  - `buildEntriesFromPairs()`: L+R 패턴 조합
  - **183번째 줄**: `preMask: pattern.preMask` - 패턴 플래그만 사용

- **[GlossaryComposer.swift:213-266](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L213-L266)**
  - `buildEntriesFromLefts()`: L-only 패턴 조합
  - **242번째 줄**: `preMask: pattern.preMask` - 패턴 플래그만 사용

**2. 독립 용어 필터링**
- **[GlossaryComposer.swift:29-31](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L29-L31)**
  - source 중복 필터링으로 preMask=true 독립 용어 제거

**3. ComponentTerm 생성 및 저장**
- **[GlossaryComposer.swift:357-380](MyTranslation/Services/Translation/Glossary/GlossaryComposer.swift#L357-L380)**
  - `ComponentTerm.make()`: 용어의 preMask 복사 (374번째 줄)

- **[GlossaryEntry.swift:6-48](MyTranslation/Domain/Glossary/Models/GlossaryEntry.swift#L6-L48)**
  - `ComponentTerm` 구조체: preMask 필드 정의 (22번째 줄)

**4. 마스킹 결정 로직**
- **[Masker.swift:207-316](MyTranslation/Services/Translation/Masking/Masker.swift#L207-L316)**
  - `buildSegmentPieces()`: 엔트리 활성화 결정
  - 250번째 줄: source 중복 필터링

- **[Masker.swift:318-380](MyTranslation/Services/Translation/Masking/Masker.swift#L318-L380)**
  - `maskFromPieces()`: 실제 마스킹 수행
  - **334번째 줄**: `if entry.preMask` - 마스킹 결정의 핵심

**5. 데이터 모델**
- **[GlossarySDModel.swift:13-50](MyTranslation/Domain/Glossary/Persistence/GlossarySDModel.swift#L13-L50)**
  - `SDTerm`: 용어 레벨 preMask 플래그 (19번째 줄)

- **[GlossarySDModel.swift:156-207](MyTranslation/Domain/Glossary/Persistence/GlossarySDModel.swift#L156-L207)**
  - `SDPattern`: 패턴 레벨 preMask 플래그 (183번째 줄)

- **[GlossaryEntry.swift:50-92](MyTranslation/Domain/Glossary/Models/GlossaryEntry.swift#L50-L92)**
  - `GlossaryEntry`: 실제 마스킹 동작을 결정하는 preMask 플래그 (53번째 줄)

### 우선순위 규칙 (현재 구현)

1. 패턴 엔트리가 독립 용어를 오버라이드 (GlossaryComposer.swift:30)
2. 패턴의 `preMask` 설정이 절대 우선순위
3. 구성 요소 용어의 `preMask` 플래그는 저장되지만 무시됨

**결과:** `preMask=true` 용어가 `preMask=false` 패턴에 포함되면 마스킹되지 않음

### 제안 해결 방법

**옵션 1: 구성 요소 preMask 전파 (권장)**
- 패턴의 구성 요소 중 **하나라도** `preMask=true`이면 조합 엔트리도 `preMask=true`로 강제
- GlossaryComposer.swift의 183, 242번째 줄 수정
- 장점: preMask=true 용어의 일관성 보장 유지
- 단점: 패턴 전체가 마스킹되어 번역 품질 저하 가능

```swift
// 예시 수정
preMask: pattern.preMask || componentTerms.contains { $0.preMask }
```

**옵션 2: 독립 용어 필터링 제외**
- preMask=true 독립 용어는 패턴에 포함되어도 필터링하지 않음
- GlossaryComposer.swift의 29-31번째 줄 수정
- 장점: preMask=true 용어의 독립적인 마스킹 보장
- 단점: 중복 엔트리로 인한 매칭 충돌 가능

**옵션 3: 이중 엔트리 생성**
- 패턴 엔트리 (preMask=false)와 preMask=true 구성 요소 독립 엔트리 모두 유지
- 중복 제거 로직 수정 필요
- 장점: 유연성 최대화
- 단점: 구현 복잡도 높음, 디듀플리케이션 로직 재설계 필요

### 설계 결정 필요 사항

이 문제는 근본적으로 **설계 철학의 선택** 문제:

1. **일관성 우선**: preMask=true 용어는 **항상** 마스킹되어 일관된 번역 보장
2. **품질 우선**: 패턴이 preMask 동작을 완전히 제어하여 번역 품질 최적화

현재는 (2) 품질 우선 방식이지만, 사용자는 (1) 일관성이 보장되기를 기대할 수 있습니다.

### 영향 범위
- GlossaryComposer의 패턴 조합 로직
- preMask=true 용어를 포함하는 모든 패턴
- 번역 일관성이 중요한 인명/고유명사 처리
- 마스킹 토큰 생성 및 번역 파이프라인

### 우선순위
**중-높음** - 논리적 일관성 문제로, 사용자 기대와 실제 동작 간 불일치 발생. 번역 품질과 일관성 간의 트레이드오프를 명확히 결정해야 함

---

## 🐛 BUG-004: 순번 기반 정규화에서 번역문의 추가 인스턴스가 정규화되지 않는 로직 문제

### 발견일
2025-11-23

### 증상 분류
**로직 설계 문제** - 순번 기반 매칭 방식 자체의 한계로 인한 문제

### 증상
번역 엔진이 자연스러운 번역을 위해 인물명을 원문보다 더 많이 추가하는 경우, 추가된 인스턴스들이 정규화되지 않고 variant 형태로 남는 현상

**배경:**
- 이전에는 세그먼트 전체 번역 결과를 대상으로 일괄 교체(batch replacement) 방식 사용
- 현재는 원문 등장 순서 기반으로 순차 매칭(sequential order-based matching) 방식 사용
- 순번 매칭은 동음이의어 구분 정확도가 높지만 (70-90%), 원문과 번역문의 용어 등장 횟수가 다를 때 문제 발생

**예시 시나리오:**
```
원문: "凯文说话时，杜兰特在听"
- 원문 등장: "凯文" 1회, "杜兰特" 1회
- SegmentPieces: [text, term(凯文), text, term(杜兰特), text]

번역 엔진 출력 (자연스러운 번역을 위해 인명 추가):
"케빈이 말할 때, 케빈·듀란트가 듣고 있었다"
- 번역문 등장: "케빈" 2회 (엔진이 1회 추가!), "듀란트" 1회

현재 동작:
1회차 순회: 원문 index=0 (凯文) → 첫 번째 "케빈" 정규화 → 완료 표시
2회차 순회: 원문 index=1 (杜兰特) → "듀란트" 정규화 → 완료 표시

결과: 두 번째 "케빈"은 정규화되지 않음 (variant 형태로 남음)
```

### 원인 분석

**핵심 파일:** [Masker.swift:1199-1327](MyTranslation/Services/Translation/Masking/Masker.swift#L1199-L1327)

#### 근본 원인

**순번 기반 정규화는 원문 주도(source-driven) 방식으로 1:1 또는 1:0 매핑을 가정**

현재 알고리즘의 구조적 특징:
1. ✅ 원문 용어별로 순회 (원문 등장 횟수만큼만 반복)
2. ✅ 순차 커서 이동 (sequential cursor advancement)
3. ✅ 원문 인덱스 기반 처리 완료 추적
4. ❌ **번역문의 추가 인스턴스 처리 불가** (1:N 매핑에서 N > 1인 경우)
5. ❌ **원문-번역문 간 등장 횟수 검증 없음**
6. ❌ **한 번 처리된 원문 용어는 재방문하지 않음**

#### 버그 발생 흐름

**1. 원문 기반 용어 추출 ([Masker.swift:1221-1226](MyTranslation/Services/Translation/Masking/Masker.swift#L1221-L1226))**

```swift
let unmaskedTerms: [(index: Int, entry: GlossaryEntry)] = pieces.pieces.enumerated().compactMap { idx, piece in
    if case .term(let entry, _) = piece, entry.preMask == false {
        return (index: idx, entry: entry)
    }
    return nil
}
```

**특징:**
- `pieces.pieces`는 **원문 텍스트의 구조**를 반영
- 각 `.term(entry, range)`는 **원문에서의 1회 등장**을 의미
- 원문에 "凯文"이 1회면 `unmaskedTerms`에도 1개만 포함

**2. Phase 1: 순차 매칭 ([Masker.swift:1228-1260](MyTranslation/Services/Translation/Masking/Masker.swift#L1228-L1260))**

```swift
for (index, entry) in unmaskedTerms {
    guard let name = nameByTarget[entry.target] else { continue }
    let candidates = makeCandidates(target: name.target, variants: name.variants)
    guard let matched = findNextCandidate(
        in: out,
        candidates: candidates,
        startIndex: lastMatchUpperBound ?? out.startIndex  // 순차 검색 커서
    ) else { continue }

    // 교체 및 커서 전진
    lastMatchUpperBound = result.nextIndex
    processed.insert(index)  // 원문 용어 처리 완료 표시
}
```

**문제점:**
1. **원문 주도 순회**: `unmaskedTerms` (원문 등장 횟수) 기반 루프
2. **1:1 가정**: 각 순회에서 번역문에서 정확히 1개 인스턴스를 찾을 것으로 가정
3. **커서 전진**: 매칭 후 `lastMatchUpperBound`가 전진하여 뒤쪽만 검색
4. **재방문 없음**: `processed.insert(index)`로 원문 인덱스를 완료 표시 → 다시 처리하지 않음
5. **선행 탐색 없음**: 같은 용어의 추가 인스턴스가 앞에 있는지 확인하지 않음

**3. 커서 기반 순차 검색 ([Masker.swift:1130-1150](MyTranslation/Services/Translation/Masking/Masker.swift#L1130-L1150))**

```swift
private static func findNextCandidate(
    in text: String,
    candidates: [String],
    startIndex: String.Index,
    // ...
) -> (canonString: String, range: Range<String.Index>)? {
    // Line 1139: 순차 검색 (startIndex부터 끝까지만)
    for candidate in candidates {
        if let range = text.range(of: candidate, range: startIndex..<text.endIndex, ...) {
            return (candidate, range)
        }
    }
    // Lines 1143-1148: 실패 시 전역 검색 fallback
    // (하지만 이미 processed 표시로 인해 재시도되지 않음)
}
```

**결과:**
- 첫 번째 인스턴스 매칭 후 커서가 그 위치 이후로 이동
- 같은 원문 용어는 다시 처리되지 않음 (processed 체크)
- 번역문의 추가 인스턴스는 검색되지 않음

#### SegmentPieces 구조

**[SegmentPieces.swift:10-19](MyTranslation/Domain/Models/SegmentPieces.swift#L10-L19)**

```swift
public struct SegmentPieces: Sendable {
    public let source: String
    public let pieces: [Piece]  // 원문 순서 기반 조각들
    public let lock: String
}

public enum Piece: Sendable {
    case text(String, Range<String.Index>)
    case term(GlossaryEntry, Range<String.Index>)  // 각 term = 원문의 1회 등장
}
```

**특징:**
- `pieces`는 **원문의 구조**를 표현
- 각 `.term` 케이스는 원문에서의 단일 등장을 나타냄
- 번역문의 등장 횟수 정보는 포함하지 않음

#### expectedCount는 원문 기준

**[Masker.swift:665-676](MyTranslation/Services/Translation/Masking/Masker.swift#L665-L676)** - `NameGlossary` 구조체:

```swift
struct NameGlossary {
    let target: String
    let variants: [String]
    let expectedCount: Int  // 원문에서의 등장 횟수
    let allowGlobalSearch: Bool
}
```

**[Masker.swift:740-745](MyTranslation/Services/Translation/Masking/Masker.swift#L740-L745)** - expectedCount 계산:

```swift
let occ = original.components(separatedBy: source).count - 1
if occ > 0 {
    expectedCountsByTarget[entry.target, default: 0] += occ
}
```

**용도:**
- 동음이의어 구분용 (`canonicalFor()` 함수에서 사용)
- **번역문의 실제 등장 횟수 검증에는 사용되지 않음**

#### 3단계 Fallback도 원문 주도

**[Masker.swift:1301-1324](MyTranslation/Services/Translation/Masking/Masker.swift#L1301-L1324)** - Phase 3:

```swift
// Phase 3: 전역 검색 fallback
let remainingTargets = nameByTarget.filter { targetName, _ in
    !processedTargets.contains(targetName)
}

for (targetName, name) in remainingTargets {
    // 전역 검색 시도
}
```

**문제점:**
- `remainingTargets`는 **처리되지 않은 원문 용어** 기준
- 번역문에 추가된 인스턴스는 `remainingTargets`에 없음
- Phase 3도 원문 기반으로 순회하므로 추가 인스턴스 처리 불가

### 이전 일괄 교체 방식과의 비교

#### 이전 방식 (Batch Replacement - 추론)

```swift
// 가정된 이전 구현
func normalizeVariantsGlobally(text: String, nameGlossaries: [NameGlossary]) -> String {
    var out = text
    for glossary in nameGlossaries {
        // 모든 variant에 대한 정규식 패턴
        let pattern = glossary.variants.joined(separator: "|")
        let regex = try? NSRegularExpression(pattern: pattern)

        // 번역문 전체에서 모든 매칭 찾기
        let matches = regex.matches(in: out, ...)

        // 등장 횟수와 무관하게 모든 매칭 교체
        for match in matches.reversed() {
            out.replaceSubrange(match.range, with: glossary.target)
        }
    }
    return out
}
```

**장점:**
- ✅ **번역문의 추가 인스턴스 처리 가능** (전체 교체)
- ✅ 원문 등장 횟수와 무관
- ✅ 번역문에서 발견되는 모든 인스턴스 정규화

**단점:**
- ❌ 동음이의어 구분 불가 (정확도 50-60%)
- ❌ 원문 순서 정보 미활용

**교체 이유 (SPEC_ORDER_BASED_NORMALIZATION.md 참고):**

```
원문: "凯和k,凯的情人的伽古拉去了学校"
용어: "凯" → "가이", "k" → "케이", "伽古拉" → "쟈그라"
번역: "카이와 케이, 카이의 연인 가고라가 학교에 갔다"

일괄 교체 시: 모든 "케이" → "가이"
결과: "가이와 가이, 가이의 연인 쟈그라가 학교에 갔다"
(잘못됨! "k"는 "케이"로 유지되어야 함)

순번 매칭 시: 원문 순서 기반 구분
- 첫 번째 매칭 → "凯" (1번째 용어)
- 두 번째 매칭 → "k" (2번째 용어)
결과: 정확한 구분 (70-90% 정확도)
```

### 관련 코드 위치

**1. 순번 기반 정규화 메인 로직**
- **[Masker.swift:1199-1327](MyTranslation/Services/Translation/Masking/Masker.swift#L1199-L1327)**
  - `normalizeWithOrder()` 함수 - 순번 기반 정규화
  - **1221-1226번째 줄**: 원문 기반 `unmaskedTerms` 추출
  - **1228-1260번째 줄**: Phase 1 - 순차 매칭
  - **1262-1299번째 줄**: Phase 2 - 패턴 fallback (동일한 순차 로직)
  - **1301-1324번째 줄**: Phase 3 - 전역 검색 fallback (여전히 원문 주도)

**2. 순차 검색 함수**
- **[Masker.swift:1130-1150](MyTranslation/Services/Translation/Masking/Masker.swift#L1130-L1150)**
  - `findNextCandidate()` 함수
  - **1139번째 줄**: `startIndex..<text.endIndex` 순차 검색

**3. SegmentPieces 데이터 구조**
- **[SegmentPieces.swift:10-19](MyTranslation/Domain/Models/SegmentPieces.swift#L10-L19)**
  - `SegmentPieces` 구조체: 원문 순서 기반
  - `Piece` enum: 각 `.term`은 원문의 1회 등장

- **[SegmentPieces.swift:33-35](MyTranslation/Domain/Models/SegmentPieces.swift#L33-L35)**
  - `unmaskedTerms()` 함수: `preMask == false` 용어 필터링

**4. expectedCount (원문 기준)**
- **[Masker.swift:665-676](MyTranslation/Services/Translation/Masking/Masker.swift#L665-L676)**
  - `NameGlossary` 구조체: `expectedCount` 필드 (원문 등장 횟수)

- **[Masker.swift:740-745](MyTranslation/Services/Translation/Masking/Masker.swift#L740-L745)**
  - expectedCount 계산 로직: 원문(`original`)에서 계산

**5. 통합 지점**
- **[DefaultTranslationRouter.swift:514-593](MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift#L514-L593)**
  - `restoreOutput()` 함수
  - **548번째 줄**: `termMasker.normalizeWithOrder()` 호출
  - 원문-번역문 등장 횟수 검증 없음

**6. 스펙 문서**
- **[SPEC_ORDER_BASED_NORMALIZATION.md:46-48](History/SPEC_ORDER_BASED_NORMALIZATION.md#L46-L48)**
  - 목표 정확도 70-90% (10-30% 실패율 인정)
  - 등장 횟수 불일치는 실패 케이스에 포함

- **[SPEC_ORDER_BASED_NORMALIZATION.md:220-228](History/SPEC_ORDER_BASED_NORMALIZATION.md#L220-L228)**
  - 3단계 fallback 전략 설명
  - Phase 3도 원문 주도 방식

### 근본적인 트레이드오프

이 문제는 **설계 철학의 선택** 문제:

| 구분 | 순번 기반 매칭 (현재) | 일괄 교체 (이전) |
|------|-------------------|---------------|
| **동음이의어 구분** | ✅ 높은 정확도 (70-90%) | ❌ 낮은 정확도 (50-60%) |
| **원문 순서 활용** | ✅ 순서 정보 활용 | ❌ 순서 무시 |
| **등장 횟수 불일치** | ❌ **실패** (1:N where N>1) | ✅ 모든 인스턴스 처리 |
| **추가 인스턴스** | ❌ **정규화 안 됨** | ✅ 정규화됨 |

**현재 시스템의 한계:**
- 원문 주도 순회로 인해 번역문의 추가 인스턴스 처리 불가
- `processed` Set이 원문 인덱스 기반이라 재방문 불가
- 등장 횟수 검증 로직 없음
- 번역문 인스턴스 카운팅 없음

### 제안 해결 방법

**옵션 1: 하이브리드 접근 - 순번 매칭 + 잔여 일괄 교체 (권장)**

Phase 4 추가: 순번 매칭 완료 후, 남은 variant를 전역 교체

```swift
// Phase 4: 추가 인스턴스 정규화
let normalizedTargets = Set(processedTargets)  // 이미 처리된 target들
for targetName in normalizedTargets {
    guard let name = nameByTarget[targetName] else { continue }
    // 남은 variant들을 target으로 전역 교체
    for variant in name.variants {
        out = out.replacingOccurrences(of: variant, with: name.target)
    }
}
```

**장점:**
- 순번 매칭의 높은 정확도 유지
- 추가 인스턴스도 정규화
- 기존 로직에 최소 영향

**단점:**
- Phase 4에서 동음이의어 구분 불가 (하지만 이미 Phase 1-3에서 구분된 상태)

**옵션 2: 번역문 기반 카운팅 + 재순회**

번역문에서 각 용어의 실제 등장 횟수를 세고, 원문 등장 횟수보다 많으면 재순회

```swift
// 번역문에서 실제 등장 횟수 카운팅
let actualCounts = countInstancesInTarget(out, nameGlossaries)

// 원문 등장 횟수와 비교
for (targetName, actualCount) in actualCounts {
    let expectedCount = expectedCountsByTarget[targetName] ?? 0
    if actualCount > expectedCount {
        // 추가 인스턴스 처리 로직
        let extraCount = actualCount - expectedCount
        // ... 추가 인스턴스 재검색 및 정규화
    }
}
```

**장점:**
- 정확한 불일치 감지
- 필요한 경우만 재처리

**단점:**
- 복잡도 증가
- 추가 인스턴스의 순서/위치 판단 어려움

**옵션 3: 범위 정보 기반 매칭 (장기)**

SPEC 문서에서 제안한 범위 정보 활용 (lines 843-864)

```swift
// 원문 및 번역문의 위치 정보 활용
// 원문 앞부분의 용어 → 번역문 앞부분에서 검색
// 원문 뒷부분의 용어 → 번역문 뒷부분에서 검색
```

**장점:**
- 위치 기반으로 더 정확한 매칭
- 추가 인스턴스도 위치 기반으로 처리 가능

**단점:**
- 대규모 리팩터링 필요
- 번역 엔진이 순서를 바꾸는 경우 여전히 어려움

### 영향 범위
- TermMasker의 순번 기반 정규화 로직 (`normalizeWithOrder()`)
- 모든 `preMask=false` 용어의 정규화 과정
- 특히 번역 엔진이 자연스러운 번역을 위해 인명을 추가하는 경우
- 동음이의어가 있는 텍스트의 정규화 정확도
- 스펙 문서의 70-90% 목표 정확도

### 우선순위
**중-높음** - 번역 품질에 영향을 주며, 순번 매칭의 장점(동음이의어 구분)을 유지하면서 등장 횟수 불일치를 처리하는 보완 로직 필요. 스펙의 10-30% 실패율 중 일부를 개선 가능

---

## 🐛 BUG-005: "용어집에 추가" 바텀 시트 중간 크기 상태에서 컨텐츠 스크롤 불가 및 UI 겹침

### 발견일
2025-11-23

### 증상
"용어집에 추가" 바텀 시트가 중간 크기 상태일 때, 컨텐츠 영역이 시트 높이보다 커도 스크롤되지 않아 상단 내용이 바텀 시트 타이틀과 닫기 버튼 뒤에 가려지는 UI 문제

**증상 상세:**
- 바텀 시트에 내용이 많아지면서 컨텐츠 영역이 시트 높이를 초과
- 중간 크기 상태: 컨텐츠 스크롤 불가 → 상단 내용이 타이틀/닫기 버튼에 가려짐
- 최대 크기 상태: 자연스럽게 표시됨 (충분한 높이 확보)
- 사용자가 중간 크기에서도 모든 컨텐츠를 볼 수 있어야 함

### 원인 분석

**예상 원인:**
바텀 시트의 중간 크기 상태에서 컨텐츠 영역에 대한 스크롤 설정이 누락되었거나, 컨텐츠 영역의 최대 높이가 시트 크기에 맞춰지지 않음

**관련 가능성 있는 UI 컴포넌트:**
- SwiftUI `Sheet` 또는 커스텀 바텀 시트 구현
- "용어집에 추가" 기능의 View 구조
- `ScrollView` 또는 `List` 설정

### 제안 해결 방법

**옵션 1: ScrollView로 컨텐츠 감싸기 (권장)**
```swift
// 바텀 시트 컨텐츠를 ScrollView로 감싸기
ScrollView {
    VStack {
        // 용어집 추가 폼 컨텐츠
    }
}
.frame(maxHeight: availableHeight)  // 시트 크기에 맞춰 최대 높이 제한
```

**옵션 2: presentationDetents와 함께 스크롤 설정**
```swift
.presentationDetents([.medium, .large])
.presentationDragIndicator(.visible)
.presentationContentInteraction(.scrolls)  // 스크롤 가능하게 설정
```

**옵션 3: GeometryReader로 동적 높이 계산**
```swift
GeometryReader { geometry in
    ScrollView {
        // 컨텐츠
    }
    .frame(maxHeight: geometry.size.height - headerHeight)
}
```

### 영향 범위
- "용어집에 추가" 바텀 시트 UI
- 바텀 시트를 사용하는 다른 UI (있다면)
- 사용자 경험 (중간 크기 시트 사용 시)

### 우선순위
**중** - UI/UX 문제이지만 기능 자체는 동작함 (최대 크기로 변경하면 해결). 사용자 불편 해소를 위해 수정 필요

---

