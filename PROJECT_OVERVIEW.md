# PROJECT_OVERVIEW.md — Project Overview

## 프로젝트 개요

MyTranslation은 **SwiftUI로 만든 iOS 번역 브라우저 앱**입니다.

주요 특징:

* WKWebView로 웹 페이지를 로딩하고, 페이지 본문을 세그먼트 단위로 추출
* Apple Foundation Models (AFM), Google Translate, DeepL 등 **여러 번역 엔진** 사용
* 번역 결과에 대해 **온디바이스 Foundation Model 기반 후처리(포스트에딧, 비교, 리랭킹)** 지원
* Glossary/마스킹 시스템으로 인명·용어 번역 품질 제어

---

## 아키텍처 개요

이 프로젝트는 대략 아래 레이어로 나뉩니다.

* **App**: 앱 엔트리 포인트, DI 컨테이너(`AppContainer`) 초기화
* **Features**: Glossary/Browser/Settings UI와 ViewModel 등 사용자 기능
* **Core**: 번역 라우터/엔진, 마스킹, Web 렌더링, Glossary 엔진, FM 파이프라인 등 핵심 로직
* **Shared**: 공통 모델/유틸/저장소 정의
* **Resources**: Info.plist 등 앱 리소스

### 1. 번역 파이프라인 흐름

웹 페이지 번역은 대략 다음 단계를 거칩니다.

1. **Content Extraction**

   * WKWebView에 JS를 주입해 `data-seg-id`를 붙인 세그먼트 단위 텍스트를 추출
2. **Text Entity Processing 준비**

   * `Glossary.Repository`가 페이지 텍스트에서 매칭된 Term/패턴을 조회
   * `TextEntityProcessor`가 `buildSegmentPieces()`로 세그먼트별 GlossaryEntry를 생성하고 `SegmentPieces`를 구성
   * `MaskingEngine`이 preMask 용어를 `__E#N__` 토큰으로 치환하여 `MaskedPack` 생성
   * 정규화(variants→target) 및 언마스킹에 필요한 메타데이터(`TermHighlightMetadata`)를 함께 추적
3. **Translation Routing & Streaming**

   * `TranslationRouter`가 AFM / Google / DeepL 중 하나 또는 여러 개를 선택해 호출
   * `AsyncThrowingStream` 기반으로 partial/final 결과를 스트리밍하며, 스트림 페이로드에 하이라이트 메타데이터를 포함
4. **Normalization & Unmasking**

   * `NormalizationEngine`이 번역 결과에서 variant를 target으로 정규화 (`normalizeWithOrder()`)
   * `MaskingEngine`이 토큰을 원래 용어로 복원하면서 한글 조사를 자동 보정 (`unmaskWithOrder()`)
   * 모든 치환 작업에서 range를 추적하여 하이라이트 메타데이터 구성
5. **Rendering**

   * 인라인 교체(InlineReplacer) 또는 오버레이(OverlayRenderer) 방식으로 결과 반영하며, 하이라이트 메타데이터로 용어 배경색을 표시
   * (향후) 온디바이스 LLM 기반 포스트에딧/비교/리랭킹을 추가할 예정

---

## 주요 컴포넌트/모듈

### 1. Translation Router (`Core/Translation/Router/`)

* `TranslationRouter` 프로토콜과 기본 구현체 `DefaultTranslationRouter`.
* 역할:

  * 번역 요청을 스트리밍 형태로 오케스트레이션
  * 캐시를 먼저 조회하고 필요 시 엔진 호출
  * AFM, Google, DeepL 등으로 라우팅
  * Glossary 적용을 위한 훅 제공
  * 마스킹 컨텍스트 공유 API(`prepareMaskingContext`, `translateStreamInternal`)로 다중 엔진/오버레이에서 Glossary/SegmentPieces 재사용
  * `TextEntityProcessor`, `MaskingEngine`, `NormalizationEngine` 활용
* 스트림 이벤트(`TranslationStreamingContract`) 예:

  * `cachedHit` → `requestScheduled` → `partial`/`final` → `failed` → `completed`

### 2. Translation Engines (`Core/Translation/Engines/`)

각 엔진은 `TranslationEngine` 프로토콜을 구현합니다.

* **AFMEngine**: Apple `Translation` 프레임워크 + Foundation Models 기반
* **GoogleEngine**: Google Translate V2 API
* **DeepLEngine**: DeepL API (free tier 포함)

반환 타입은 공통적으로 `AsyncThrowingStream<[TranslationResult], Error>`.

### 3. FM (Foundation Model) Pipeline (`Core/Translation/FM/`)

온디바이스 LLM을 이용한 번역 품질 향상 파이프라인.

* `FMOrchestrator`: 포스트에딧, 비교, 리랭킹 단계 오케스트레이션
* `FMModelManager`: 로컬 모델 라이프사이클 관리
* `FMPostEditor`: 스타일 기반 포스트에딧
* `CrossEngineComparer`, `Reranker`: 다중 엔진 결과 비교/리랭킹

구성은 `FMConfig`로 제어:

```
FMConfig(
    enablePostEdit: true,
    enableComparer: false,
    enableRerank: false
)
```

### 4. Glossary System (`Core/GlossaryEngine/`)

SwiftData 기반 Glossary 엔진을 Core 레이어로 분리했습니다.

**데이터 계층 (Core/GlossaryEngine/Persistence/)**
* `Glossary.Repository`: 페이지 텍스트로 매칭된 Term/패턴 조회
* `GlossarySDModel`: SwiftData 모델 (SDTerm, SDPattern, SDComponent 등)
* `GlossarySDSourceIndexMaintainer`: Q-gram 인덱스 자동 유지
* `AutoVariantStoreManager`, `AutoVariantRecord`

**서비스/유틸 (Core/GlossaryEngine/Services/)**
* `GlossaryJSONParser`, `GlossarySheetImport`, `KeyGenerator`, `GlossaryJSON`

**알고리즘 (Core/GlossaryEngine/Algorithms/)**
* `AhoCorasick`: 텍스트 매칭
* `Deduplicator`: GlossaryEntry 중복 병합

### 5. Web Rendering (`Core/WebRendering/`)

WKWebView 번역 결과 반영.

* `ContentExtractor`: 세그먼트 추출 및 `data-seg-id` 주입
* `InlineReplacer`: JS 브리지(`window.__afmInline.upsertPayload`)로 인라인 교체
* `OverlayRenderer`: 세그먼트 선택 및 오버레이 기반 렌더링, 용어 하이라이트 반영
* `SelectionBridge`: 텍스트 선택 이벤트 Swift 쪽으로 전달

### 6. Text Entity Processing (`Core/TextEntityProcessing/`)

용어/인명을 보호하고 정규화하기 위한 텍스트 엔티티 처리 시스템.

**아키텍처**: 모듈화된 엔진 구조로, 각 엔진은 독립적으로 사용 가능하며 TextEntityProcessor가 오케스트레이션 제공

**Engines (`Core/TextEntityProcessing/Engines/`)**
* `SegmentTermMatcher`: 용어 검출 (Glossary 매칭 결과 활용)
* `SegmentEntriesBuilder`: 패턴 기반 GlossaryEntry 구성
* `SegmentPiecesBuilder`: 세그먼트를 텍스트/용어 조각으로 분할
* `MaskingEngine`: 토큰화(마스킹)/언마스킹 처리
  * `maskFromPieces()`: preMask 용어를 `__E#N__` 토큰으로 치환
  * `unmaskWithOrder()`: 순서 기반 토큰 복원 및 조사 자동 보정
  * `normalizeTokensAndParticles()`: 잔여 토큰 일괄 정규화
  * `normalizeDamagedETokens()`: LLM 출력에서 손상된 토큰 복구
* `NormalizationEngine`: variant → target 정규화
  * `makeNameGlossariesFromPieces()`: 정규화용 NameGlossary 생성
  * `normalizeWithOrder()`: 순서 기반 variant 정규화 및 조사 보정
  * `normalizeVariantsAndParticles()`: 잔여 variant 일괄 정규화 (보호 범위 관리)
* `TextEntityProcessor`: Orchestration layer
  * `buildSegmentPieces()`: 용어 검출 → Entry 생성 → Pieces 구성 파이프라인

**Rules (`Core/TextEntityProcessing/Rules/`)**
* `KoreanParticleRules`: 한글 조사 자동 보정 규칙
  * `hangulFinalJongInfo()`: 받침(종성) 판별
  * `chooseJosa()`: 받침에 따른 조사 선택 (`이/가`, `을/를`, `은/는`, `과/와`, `으로/로` 등)
  * `fixParticles()`: 용어 치환 후 뒤따르는 조사 자동 보정
  * `replaceWithParticleFix()`: 치환 + 조사 보정 통합 헬퍼

**Models (`Core/TextEntityProcessing/Models/`)**
* `SegmentPieces`: 세그먼트 내 텍스트/용어 조각 시퀀스
* `MaskedPack`: 마스킹된 텍스트/락/토큰-엔트리 매핑 묶음
* `LockInfo`: 토큰 메타데이터 (target, 받침 정보, appellation 여부)
* `TermRange`: 하이라이트 범위 추적 (masked/normalized 타입 구분)

**주요 특징**:
* 모듈화: 각 엔진은 독립적으로 사용 가능 (Option B 아키텍처)
* 순서 기반 처리: 용어 출현 순서를 추적하여 정확한 매칭/치환
* 보호 범위 관리: 이미 정규화된 범위를 보호하고 1글자 variant는 건너뛰어 오정규화 방지
* 한글 조사 자동 보정: 받침 판별 및 조사 형태 자동 선택

### 7. Dependency Injection

* `AppContainer`: DI 컨테이너

  * SwiftData ModelContext
  * 번역 엔진들
  * Glossary: `Glossary.Repository`
  * `DefaultTranslationRouter`
  * FM 파이프라인 구성
  * Text Entity Processing: `TextEntityProcessor`, `MaskingEngine`, `NormalizationEngine` 조립

### 8. State Management

* `BrowserViewModel`: 페이지 번역 상태, 언어 설정, `translateStream()`로 스트리밍 제어
* `GlossaryViewModel`: Glossary CRUD 및 SwiftData 연동
* `TermEditorViewModel`: Glossary 편집/유효성 검사/Sheets import 연동

### 9. Persistence & Configuration

* **CacheStore**: 번역 결과 메모리 캐시
  * `DefaultCacheStore`: Dictionary 기반 인메모리 캐시
  * 세그먼트·엔진·옵션 조합으로 캐시 키 생성
  * `clearAll()`: 전체 캐시 삭제
  * `clearBySegmentIDs(_:)`: 특정 세그먼트 캐시만 선택적 삭제
  * 새로고침 시 캐시 삭제로 항상 최신 번역 보장
* **HistoryStore**: UserDefaults(JSON)로 방문 기록을 저장하고 중복 URL을 최신 순으로 정리, `HistoryView`에서 날짜별 그룹/검색/삭제·재방문 지원
* SwiftData: 용어/패턴 저장
* UserSettings: 번역/엔진/스타일 설정
* API Keys: `Info.plist` 기반 (Google/DeepL)

### 10. Shared (공통 모델/유틸)

* **Models**: `Segment`, `SegmentPieces`, `BrowsingHistory`, `TranslationOptions`, `TranslationStyle`, `AppLanguage`, `TranslationStreamingContract`, `TermHighlightMetadata`, `GlossaryAddModels`
* **Persistence**: `CacheStore`, `SwiftDataModel`, `Migrations`, `APIKeys` 등 공통 설정/저장소 정의
* **Utils**: `Logging`, `URLTools`, `String+Extension`, `Array+Extension`, `TextNormalize`, `LanguageCatalog`
* **Services**: `HistoryStore` (방문 기록 저장/조회)

---

## 프로젝트 구조

예시:

```
MyTranslation/
├── Shared/
│   ├── Models/
│   ├── Persistence/
│   ├── Services/
│   └── Utils/
├── Core/
│   ├── Translation/
│   │   ├── Router/
│   │   ├── Engines/
│   │   ├── FM/
│   │   └── PostEditor/
│   ├── TextEntityProcessing/
│   │   ├── Engines/
│   │   ├── Rules/
│   │   └── Models/
│   ├── WebRendering/
│   └── GlossaryEngine/
│       ├── Models/
│       ├── Persistence/
│       ├── Services/
│       └── Algorithms/
├── Features/
│   ├── Browser/
│   ├── Glossary/
│   │   ├── UI/
│   │   ├── ViewModels/
│   │   ├── ImportExport/
│   │   └── Components/
│   └── Settings/
│       └── UI/
├── App/
├── Resources/
└── Assets.xcassets
```

---

## 핵심 타입/모듈 목록

> 이 목록은 **핵심 타입/모듈**만 요약합니다. 변경 시 반드시 최신 상태로 유지해야 합니다.

* `AppContainer`
* `BrowserViewModel`
* `GlossaryViewModel`
* `TranslationRouter` / `DefaultTranslationRouter`
* `TranslationEngine` (AFM/Google/DeepL)
* `TextEntityProcessor` / `MaskingEngine` / `NormalizationEngine`
* `KoreanParticleRules`
* `TermHighlightMetadata`
* `SegmentPieces` / `MaskedPack` / `TermRange`
* `ContentExtractor` / `InlineReplacer` / `OverlayRenderer`
* `FMOrchestrator`, `FMPostEditor`, `CrossEngineComparer`, `Reranker`
* `HistoryStore` / `HistoryView`

---

## Build & Test

> ⚠ Xcode + iOS 시뮬레이터가 설치된 macOS 환경에서만 실행 가능합니다.

### Build

```
xcodebuild -scheme MyTranslation -configuration Debug build
xcodebuild -scheme MyTranslation -configuration Release build
```

### Test

```
xcodebuild test -scheme MyTranslation -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme MyTranslation -only-testing:MyTranslationTests
xcodebuild test -scheme MyTranslation -only-testing:MyTranslationTests/MyTranslationTests/testExample
```

### Open in Xcode

```
open MyTranslation.xcodeproj
```

## ## Common Development Patterns

### 1. Adding a New Translation Engine

1. `Core/Translation/Engines/<EngineName>/` 경로에 클라이언트 생성
2. `TranslationEngine` 프로토콜 구현 (스트리밍 지원 필수)
3. `EngineTag` enum에 엔진 식별자 추가
4. `AppContainer` 및 `DefaultTranslationRouter`에 등록
5. UI 측 `EnginePickerOptionsView` 업데이트

### 2. Modifying Translation Stream

스트리밍 계약은 `Shared/Models/TranslationStreamingContract.swift`에 정의되어 있으며 이벤트 순서는 반드시 유지해야 합니다:

1. `cachedHit`
2. `requestScheduled`
3. `partial` / `final`
4. `failed`
5. `completed`

라우팅 로직 변경 시 `DefaultTranslationRouter.translateStream()`을 수정합니다. (위치: `Core/Translation/Router/DefaultTranslationRouter.swift`)

### 3. Working with Glossary Models

Glossary는 SwiftData 기반이며 `Glossary.SDModel` 네임스페이스 아래에 모델이 위치합니다.

* 모든 Glossary 조작은 **`@MainActor`** 컨텍스트 내에서 수행
* 비즈니스 로직은 `GlossaryService`를 통해 처리 (직접 모델 접근 지양)
* 인덱스 관리는 `GlossarySDSourceIndexMaintainer`에 의해 자동 수행

### 4. Testing Translation Pipeline

주요 프로토콜에 대한 Mock 구현을 사용해 번역 파이프라인을 테스트합니다:

* `TranslationEngine` → 스트리밍 테스트 결과를 반환하는 mock
* `CacheStore` → 결정적 테스트를 위한 인메모리 캐시
* `PostEditor`, `ResultComparer` → NOP 또는 테스트 더블 구현

---

## Configuration

### 1. API Keys

API 키는 `MyTranslation/Resources/Info.plist`에 저장됩니다:

* `GoogleAPIKey`
* `DeepLAuthKey`

⚠️ **보안 주의:** 프로덕션 환경에서는 Info.plist에 API 키를 포함하지 말고, 환경 변수나 보안 저장소 사용을 고려합니다.

### 2. Feature Flags

Foundation Model 파이프라인의 기능 플래그는 `AppContainer` 초기화 시 설정합니다:

```
FMConfig(
    enablePostEdit: true,
    enableComparer: false,
    enableRerank: false
)
```

### 3. Translation Settings

`UserSettings`에서 설정 가능한 항목:

* URL별 소스/타깃 언어 설정 (`BrowserViewModel.languagePreferenceByURL`)
* 기본 번역 엔진 선택
* 번역 스타일 (`TranslationStyle` 값 객체)
* Glossary 적용 여부 토글

---

## 아키텍처 & 디자인 원칙

### 1. 의존성 방향

* 흐름: **Features → Core → Shared/Resources**. 상위(UI)에서 하위(핵심/공통)로만 의존하도록 유지합니다.
* Core는 플랫폼 의존성을 최소화하고, Shared는 순수 모델/유틸을 담아 재사용성을 높입니다.

### 2. DI와 결합도

* `AppContainer`에서 엔진/라우터/저장소 등을 조립해 Feature 레이어에 주입합니다.
* ViewModel과 Core 로직은 가능하면 프로토콜에 의존하고, 구체 타입은 조립 단계에만 노출합니다.

### 3. 테스트 가능성

* Shared/Core의 모델/로직은 순수 Swift로 유지하고, WebView/네트워크/엔진은 프로토콜로 추상화해 테스트 대역(Mock)을 쉽게 교체할 수 있게 합니다.

### 4. 기능 확장 순서

1. Shared/Core에 필요한 타입·계약을 정의하고 구현을 추가
2. AppContainer에서 새 구현을 조립
3. Features(UI)에서 새 기능을 사용하는 흐름으로 확장

이 순서를 따르면 의존성 방향을 깨지 않고 기능을 확장할 수 있습니다.
