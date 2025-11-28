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
* **Domain**: 번역/세그먼트/Glossary 등 비즈니스 도메인 모델과 계약(프로토콜)
* **Presentation**: SwiftUI View + ViewModel (Browser, Glossary, Settings 등) — 주소창에서 뒤로/앞으로/새로고침, 페이지 내 검색, 데스크톱 모드 토글, 히스토리 진입점을 제공
* **Services**: 번역 엔진/라우터, 마스킹, Web 렌더링, FM 파이프라인 등
* **Persistence**: SwiftData 기반 Glossary 저장소, 설정, 캐시/키 관리
* **Utils**: 공통 유틸리티

### 1. 번역 파이프라인 흐름

웹 페이지 번역은 대략 다음 단계를 거칩니다.

1. **Content Extraction**

   * WKWebView에 JS를 주입해 `data-seg-id`를 붙인 세그먼트 단위 텍스트를 추출
2. **Masking & Normalization 준비**

* `Glossary.Repository`가 페이지 텍스트에서 매칭된 Term/패턴을 조회하고, `TermMasker`가 세그먼트별 GlossaryEntry를 직접 생성
   * `TermMasker`가 `SegmentPieces`를 생성해 용어 위치를 식별하고, preMask 용어를 토큰으로 치환할 준비를 함
   * 정규화(variants→target) 및 언마스킹에 필요한 메타데이터(`TermHighlightMetadata`)를 함께 추적
3. **Translation Routing & Streaming**

   * `TranslationRouter`가 AFM / Google / DeepL 중 하나 또는 여러 개를 선택해 호출
   * `AsyncThrowingStream` 기반으로 partial/final 결과를 스트리밍하며, 스트림 페이로드에 하이라이트 메타데이터를 포함
4. **Normalization & Unmasking**

   * 번역 결과에서 variant를 target으로 정규화하고, 토큰을 원래 용어로 복원하면서 range를 보정
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

### 6. Masking & Normalization (`Services/Translation/Masking/`)

민감한 용어/인명을 보호하기 위한 마스킹 로직.

* `Glossary.Repository`가 매칭된 Term/패턴을 조회하고, `TermMasker`가 세그먼트별 GlossaryEntry를 생성
* `TermMasker`: 마스킹/언마스킹 처리, variants 정규화, 하이라이트 range 추적
  * Phase 4 잔여 일괄 교체: 이미 정규화된 범위는 보호하고, 실제 매칭된 변형만 재사용하며 1글자 변형은 건너뛰어 오정규화를 방지하면서 여분 인스턴스를 일괄 정규화하고 범위를 함께 추적
* `MaskedPack`: 원문/마스킹된 텍스트/락/토큰-엔트리 매핑 묶음
* `TermHighlightMetadata`: 원문/정규화 전/최종 번역문 하이라이트 정보
* **Hangul handling**: 한글 조사 선택을 위해 받침(종성) 여부를 판별하는 `hangulFinalJongInfo()` 로직을 포함해,
  `이/가`, `을/를`, `은/는`, `과/와`, `으로/로` 등 조사 자동 판정 기능을 제공

### 7. Dependency Injection

* `AppContainer`: DI 컨테이너

  * SwiftData ModelContext
  * 번역 엔진들
  * Glossary: `Glossary.Repository`
  * `DefaultTranslationRouter`
  * FM 파이프라인 구성
  * Masking: `SegmentPieces` 기반 마스킹/정규화 컨텍스트 조립

### 8. State Management

* `BrowserViewModel`: 페이지 번역 상태, 언어 설정, `translateStream()`로 스트리밍 제어
* `GlossaryViewModel`: Glossary CRUD 및 SwiftData 연동

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
│   ├── WebRendering/
│   └── GlossaryEngine/
│       ├── Models/
│       ├── Persistence/
│       ├── Services/
│       └── Algorithms/
├── App/
├── Domain/
│   ├── Glossary/
│   └── Models/         # (Glossary 도메인 모델 및 기타 잔여 모델)
├── Presentation/
│   ├── Browser/
│   ├── Glossary/
│   └── Settings/
├── Services/
│   ├── Adapters/
│   └── Translation/    # Glossary/Masking 등 나머지 Translation 서비스
├── Persistence/       # (Legacy, 정리 예정)
└── Utils/             # (Legacy, 정리 예정)
```

---

## 핵심 타입/모듈 목록

> 이 목록은 **핵심 타입/모듈**만 요약합니다. 변경 시 반드시 최신 상태로 유지해야 합니다.

* `AppContainer`
* `BrowserViewModel`
* `GlossaryViewModel`
* `TranslationRouter` / `DefaultTranslationRouter`
* `TranslationEngine` (AFM/Google/DeepL)
* `TermMasker`
* `TermHighlightMetadata`
* `SegmentPieces`
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

이 프로젝트는 전통적인 레이어드 아키텍처에 **클린 아키텍처(Clean Architecture)** 개념을 일부 섞어서 설계하는 것을 지향합니다.

### 1. 레이어 개념

* **Domain 레이어**

  * 번역, Glossary, 세그먼트, FM 파이프라인 등 "문제 영역 자체"를 표현하는 레이어입니다.
  * 비즈니스 규칙, 도메인 모델, 값 객체, 인터페이스(프로토콜)를 정의합니다.
  * 외부 프레임워크(iOS UI, 네트워크 클라이언트, DB 등)에 최대한 의존하지 않도록 합니다.

* **Application / Services 레이어**

  * Domain 레이어의 규칙을 이용해 실제 유스케이스를 수행하는 애플리케이션 서비스 레이어입니다.
  * `TranslationRouter`, FM 파이프라인 오케스트레이션, Glossary 서비스 등이 여기에 속합니다.
  * 외부 인프라(네트워크, WebView, 번역 엔진 클라이언트)를 조합해 도메인 규칙을 수행합니다.

* **Presentation 레이어**

  * SwiftUI View 및 ViewModel로 구성된 레이어입니다.
  * ViewModel은 가능한 한 UI 상태 관리와 애플리케이션 서비스 호출에만 집중하고,
    Domain/Services 레이어의 구체 구현에 강하게 결합되지 않도록 합니다.

* **Infrastructure 레이어 (Adapters, Persistence, WebRendering 등)**

  * 번역 엔진 API 클라이언트, WKWebView 연동, SwiftData, 로컬 저장소 등
    "환경 의존적인 것"을 캡슐화하는 레이어입니다.
  * Domain / Application에서 정의한 인터페이스를 구현하는 어댑터 역할을 합니다.

### 2. 의존성 방향 (Dependency Rule)

* 의존성은 가능한 한 **바깥 → 안쪽**(UI → Services → Domain) 방향으로만 흐르도록 합니다.
* Domain 레이어는 어떤 상위 레이어(Presentation, Infrastructure)에 대해서도 알지 못해야 합니다.
* 구체 구현(예: 특정 번역 엔진, 특정 WebView 연동 방식)에 대한 의존성은
  Domain이 아닌 Services/Infrastructure 레이어에 머무르게 합니다.

### 3. DI(Dependency Injection)와 결합도

* `AppContainer`는 DI 컨테이너로서, 상위 레이어에서 사용할 구체 구현을 조립하는 역할을 합니다.
* ViewModel / Services는 가능하면 프로토콜(또는 추상 타입)에 의존하게 하고,
  실제 인스턴스 생성은 `AppContainer`나 팩토리에서 담당하는 것을 권장합니다.
* 이렇게 하면 번역 엔진 교체, FM 파이프라인 구성을 변경하는 등의 작업을
  Domain/Presentation 코드를 최소 변경으로 수행할 수 있습니다.

### 4. 테스트 가능성

* Domain 레이어의 타입과 규칙은 **순수 Swift 코드**로 유지해 단위 테스트를 쉽게 합니다.
* 번역 엔진, WebView, 네트워크 연동 등은 프로토콜로 추상화하고,
  테스트 환경에서는 인메모리/목(Mock) 구현으로 교체할 수 있게 설계합니다.

### 5. 기능 단위 확장 전략

* 새로운 번역 관련 기능(예: 새로운 후처리 단계, 새로운 Glossary 규칙)을 추가할 때는:

  1. 우선 Domain/Services 레이어에 필요한 타입/인터페이스를 정의하고,
  2. Infrastructure 레이어에서 실제 구현을 추가한 뒤,
  3. 마지막으로 Presentation 레이어에서 이를 사용하는 방향으로 확장합니다.
* 이 순서를 지키면 UI에서 출발해 무작정 아래로 파고드는 것보다
  구조를 일관되게 유지하기 쉽습니다.

> 위 원칙들은 "완전한 정석 클린 아키텍처" 구현을 강제하기보다는,
> 현재 코드 구조를 크게 벗어나지 않는 선에서 **의존성 방향과 책임 분리를 의식적으로 유지하기 위한 가이드**입니다.
