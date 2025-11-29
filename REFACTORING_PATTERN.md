# Pattern 리팩토링 구현 계획

> 목표: Pattern에서 `joiners`, `srcTplIdx`, `tgtTplIdx`를 제거하고, `source_templates` / `variant_templates`(+ `target_template`)를 중심으로 **원문/번역문 변형을 모두 템플릿 레벨에서 표현**하는 구조로 전환한다. DB 마이그레이션은 필요 없으며, 앱 삭제 후 재설치로 초기화한다.

---

## 1. 현재/목표 구조 요약

### 1.1. 현재 구조 (개략)

- Pattern
  - `source_template` + `source_templates?`
  - `target_template`
  - `joiners` (source/target 양쪽 variants와 canonical joiner 역할)
  - `srcTplIdx` / `tgtTplIdx`
- Term / Component
  - `srcTplIdx` / `tgtTplIdx`를 통해 **어떤 템플릿 조합을 쓰는지** 지정
- 엔트리 생성/정규화
  - `tplIdx` 조합 + `joiners`에서 실제 문자열 variants를 생성해 GlossaryEntry/NameGlossary 등에 주입

### 1.2. 목표 구조 (개략)

- Pattern
  - 템플릿 레벨에서 모든 변형을 표현
  - `joiners`, `srcTplIdx`, `tgtTplIdx` 제거
  - 원문 변형: `source_templates: [String]`
  - 번역문 변형: `target_template: String` + `variant_templates: [String]` (필요 시)
  - **preMask == true**인 패턴은 정규화 variants 생성에서 제외 (마스킹에만 사용)
- Term / Component
  - 더 이상 템플릿 인덱스를 신경 쓰지 않음 (패턴 분리로 대체)
  - 한 Pattern에 Term이 1개만 사용되는 경우:
    - `variant_templates`가 비어 있으면 `target_template`에 Term의 variants만 대입해서 정규화용 variants 생성
- Glossary JSON / SwiftData / Entry Composer
  - 위 구조를 기준으로 모두 수정

---

## 2. 데이터 모델 변경 설계

### 2.1. JSON 스키마 변경

#### 2.1.1. Pattern JSON 예시 (새로운 형태)

```jsonc
{
  "key": "person_full_name",
  "kind": "person",          // 기존에 사용 중이면 유지
  "preMask": false,

  // 원문 변형들
  "source_templates": [
    "{family}{given}",
    "{given}{family}",
    "{family} {given}",
    "{given} {family}"
  ],

  // 번역문 canonical
  "target_template": "{family} {given}",

  // 번역문 변형 템플릿 (필요한 패턴에서만 사용)
  "variant_templates": [
    "{given} {family}",
    "{family}{given}",
    "{given}{family}"
  ]
}
```

- 제거되는 필드
  - `joiners`
  - `srcTplIdx` / `tgtTplIdx` (Pattern 레벨에서 더 이상 사용하지 않음)

- 기본 규칙
  1. **source_templates**
     - 원문에서 나타날 수 있는 모든 패턴 문자열.
     - 비어있지 않으면 **source 매칭은 반드시 이 배열만 사용**.
  2. **target_template**
     - canonical 번역 패턴.
  3. **variant_templates**
     - 번역 결과에서 추가로 등장할 수 있는 패턴들.
     - 비어 있으면 Pattern은 `target_template`만을 기준으로 정규화 variants를 생성.
  4. `preMask == true`인 Pattern은:
     - source_templates만 사용해 마스킹 대상만 결정.
     - 정규화 variants는 생성하지 않음.

#### 2.1.2. Term JSON/Sheet와의 관계

- Term 단위에서 이미:
  - `variants` (중국어 표기 variants, 한글 표기 variants 등)
  - 역할(role: family/given/suffix 등)
  - preMask 여부
  를 관리.

- Pattern은 더 이상 Term별 템플릿 인덱스를 참조하지 않고,
  - **“이 패턴이 어떤 역할를 어떤 순서로 나열하는가”**만 템플릿 문자열로 표현.

- **단일 Term 패턴 (예: ultraman, simple appellation)**
  - `variant_templates`가 비어 있는 경우,
  - 정규화 단계에서 `target_template`에 Term의 variants를 직접 대입하여 variants 생성.

---

### 2.2. SwiftData 모델 변경 (GlossaryEngine/Persistence)

#### 2.2.1. SDPattern

- 필드 변경
  - 제거
    - `joiners: String?`
    - `srcTplIdx: Int?`
    - `tgtTplIdx: Int?`
  - 추가/변경
    - `sourceTemplates: [String]`  // JSON `source_templates`
    - `targetTemplate: String`      // JSON `target_template`
    - `variantTemplates: [String]`  // JSON `variant_templates`

- 마이그레이션은 불필요 (앱 삭제 후 재설치). 기존 코드/모델은 그냥 수정.

#### 2.2.2. SDTerm / SDComponent

- SDComponent에서 템플릿 인덱스를 참조하던 필드 제거
  - `srcTplIdx`, `tgtTplIdx` 제거
  - 그 외 패턴에 대한 연결은 Pattern → Component(들) 관계로만 유지.
  - 각 SDPattern은 **하나의 source_template/target_template 조합 개념**으로 쓰되,
    - 실제로는 `sourceTemplates` / `variantTemplates`로 “문자열 레벨” 변형을 관리.

- SDTerm은 기존 구조 유지
  - Term의 `variants`, `role`, `isPreMasked` 등은 그대로.

---

## 3. Import / Export (JSON, Google Sheet) 수정 계획

### 3.1. GlossaryJSONParser / Sheet Import

1. **Google Sheet 스키마 업데이트**
   - Pattern 시트:
     - `source_templates` 열: 세미콜론(`;`)으로 구분된 템플릿 리스트
     - `target_template` 열: canonical target 템플릿
     - `variant_templates` 열: 세미콜론(`;`)으로 구분된 추가 target 템플릿 리스트 (optional)
     - `preMask` 열: `TRUE/FALSE`
   - 기존 `joiners`, `srcTplIdx`, `tgtTplIdx` 열 제거

2. **Sheet → JSON 변환 로직 수정**
   - 한 셀의 `source_templates` / `variant_templates`를 `;` 기준으로 split → `[String]`.
   - 공백/빈 문자열 처리 규칙 정의
     - 빈 셀 → 빈 배열
     - split 후 빈 토큰 제거.

3. **GlossaryJSONParser**
   - Pattern 디코딩/인코딩에서 새 스키마 사용.
   - joiners/템플릿 인덱스 관련 로직 삭제.

### 3.2. JSON Import → SwiftData 저장

- `GlossarySheetImport` 또는 JSON Import 경로에서:
  - 새 Pattern DTO (예: `JSPattern`)에
    - `sourceTemplates`, `targetTemplate`, `variantTemplates`, `preMask`를 채우고
  - `SDPattern` 초기화 시 해당 필드를 그대로 매핑.

---

## 4. TextEntityProcessing 쪽 영향 및 수정 포인트

### 4.1. SegmentTermMatcher / SegmentEntriesBuilder

1. **SegmentTermMatcher**
   - 기존: Pattern + Term + tplIdx/joiners 조합으로 후보 문자열 생성 후 매칭.
   - 변경 후:
     - 원문 매칭은 항상 `pattern.sourceTemplates` 기준.
       - `sourceTemplates`가 비어 있다면, 필요 시 `sourceTemplate` 하나로 대체 (혹은 스키마 상 항상 1개 이상 보장).
     - preMask 패턴인지 아닌지는 `pattern.preMask`로만 판단.

2. **SegmentEntriesBuilder**
   - GlossaryEntry(또는 내부 Entry DTO) 생성 시
     - Pattern가 가진 `sourceTemplates` / `targetTemplate` / `variantTemplates`만 참조.
     - Term 단위 정보 (variants, role, appellation 여부 등)는 그대로 사용.

### 4.2. MaskingEngine

- `preMask == true` 패턴은 **마스킹에만 사용**
  - `pattern.sourceTemplates`에서 매칭된 구간을 `__E#N__` 토큰으로 치환.
  - 해당 Pattern에 대해서는 **정규화 variants를 생성하지 않음**.

- `preMask == false` 패턴만 NormalizationEngine에 전달.

### 4.3. NormalizationEngine

1. **variants 생성 전략 변경**

   **Case A. 패턴에 `variantTemplates`가 있는 경우 (복수 target 패턴)**

   - `variantTemplates` + `targetTemplate` 전체를 **target-side 템플릿 목록**으로 사용:
     - `allTargetTemplates = [targetTemplate] + variantTemplates`
   - 각 템플릿에 대해:
     - Term들의 canonical/variants를 꽂아서 정규화용 `surfaceVariants`를 생성.
   - canonicalTarget은 항상 `targetTemplate`에 canonical Term만 꽂은 결과.

   **Case B. 패턴에 `variantTemplates`가 없는 경우 (단일 target 패턴)**

   - Term이 하나만 사용되는 패턴이라면:
     - `targetTemplate`에 Term의 **모든 variants**를 꽂아서 `surfaceVariants`를 생성.
     - canonicalTarget은 `targetTemplate`에 Term의 canonical만 꽂은 결과.
   - Term이 여러 개 사용되는 패턴이라면:
     - `targetTemplate`만 이용하여, Term 개수/role에 맞게 variants 전략 정의 (기존 정책 유지 or 추후 확장).

2. **정규화 알고리즘 변경 포인트**

   - 더 이상 `joiners`, `tplIdx`를 보지 않음.
   - 모든 정규화 대상 문자열은 다음에서 파생:
     1. Pattern의 target-side 템플릿 리스트 (`targetTemplate` + `variantTemplates`)
     2. Term의 variants (중국어→한국어 표기 변형 등)
   - `preMask == true` 패턴의 Entries는 Normalization 단계에서 스킵.

---

## 5. GlossaryEntry / NameGlossary 생성 경로 수정

### 5.1. GlossaryEntry 구조 재확인

- GlossaryEntry가 최소한 아래 정보들을 필요로 한다고 가정:
  - patternKey / termKey
  - pattern의 targetTemplate / variantTemplates
  - term의 canonical/variants
  - preMask 여부, appellation 여부 등 메타데이터

- 기존에 `tplIdx` 기반으로 어떤 템플릿을 선택했는지 기록했다면, 이제는:
  - **Pattern 자체가 템플릿 조합을 다 포함**하므로, Entry에는 **템플릿 인덱스 필요 없음**.

### 5.2. NameGlossary / Appellation 처리

- 이름 패턴(예: `{family}{given}`, `{given}{family}` 등)에서 성/이름 순서 변형을 다루기 위해:
  - 원문: `source_templates`에 순서 바뀐 패턴을 모두 기록.
  - 번역문: 순서 바뀐 패턴을 `variant_templates`로 기록.
- NameGlossary 생성 시:
  - Pattern의 target-side 템플릿들을 이용해 이름 관련 표면형을 생성.
  - preMask 패턴(예: `{L}{R} → __E#N__` 류)이면 NameGlossary에는 참여시키지 않음.

---

## 6. 구현 순서 제안

1. **모델/스키마 변경부터**
   1. `SDPattern` 수정 (SwiftData 모델)
   2. Pattern DTO/JSON 스키마 (`JSPattern` 등) 수정
   3. Code compile이 깨지는 부분을 최소한으로 임시 주석 처리

2. **Import 계층 수정 (Sheet/JSON → SDPattern)**
   1. `GlossarySheetImport`에서 Pattern 로딩 로직 수정
   2. `GlossaryJSONParser`에서 Pattern 디코딩/인코딩 수정
   3. 간단한 유닛 테스트 / 임시 Playground로 parsing 검증

3. **TextEntityProcessing 연동 수정**
   1. `SegmentTermMatcher`에서 Pattern 매칭 시 `source_templates`만 사용하도록 변경
   2. `SegmentEntriesBuilder`에서 Pattern/Term 조합 로직에서 tplIdx/joiners 제거
   3. `MaskingEngine`에서 preMask 패턴만 사용되도록 필터링 확인

4. **NormalizationEngine 리팩터링**
   1. 정규화 variants 생성 진입점에서 Pattern 구조에 맞게 분기 (Case A/B)
   2. `joiners` / tplIdx 관련 코드 제거
   3. NameGlossary 관련 부분이 Pattern 변경과 맞물려 있는지 점검

5. **전체 파이프라인 연동 테스트**
   1. 단일 Term 패턴 (ultraman 등)에 대한 end-to-end 테스트
   2. 이름 패턴 (성/이름 순서 변형) e2e 테스트
   3. preMask-only 패턴 (appellation preMask 등) e2e 테스트

6. **정리 및 정리 주석 추가**
   - Pattern의 역할/필드 의미를 파일 상단에 주석으로 명확히 기술
   - 과거 `joiners`, `srcTplIdx`, `tgtTplIdx` 관련 TODO/주석 제거

---

## 7. 추가로 고려할 점 (추후 작업 후보)

1. **roles 기반 템플릿으로의 확장**
   - `{L}` / `{R}`를 `{family}` / `{given}` / `{suffix}` 등 role로 치환하는 리팩토링은
     - 이번 구조 변경 후에, Pattern 템플릿 문자열만 role로 바꾸는 방향으로 수행.

2. **스키마 버전 명시**
   - Glossary JSON에 `schema_version` 필드를 추가해, 추후 구조 변경 시 버전별 대응 여지를 남김.

3. **preMask 패턴의 관리**
   - preMask 전용 Pattern을 별도 kind로 구분하거나, 시트에서 시각적으로 구분해 유지보수성을 높일 수 있음.

---

> 이 계획을 기준으로, 먼저 Pattern/JSON/SwiftData 모델을 손보고, 이후 TextEntityProcessing → Normalization 순으로 단계적으로 수정하면 리스크를 줄이면서 리팩토링을 진행할 수 있다.

