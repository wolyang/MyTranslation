# MyTranslation 코드베이스 리팩토링 계획

## 개요

MyTranslation 코드베이스를 레이어 우선 아키텍처(Domain/Services/Presentation)에서 기능 우선 아키텍처(Features/Core/Shared)로 재구성하며, 각 기능 내부에 적절한 레이어링을 적용합니다.

**현재:** 125개 Swift 파일이 기술 레이어별로 구성됨 (최근 PR에서 히스토리 기능 추가: BrowsingHistory.swift, HistoryView.swift, HistoryStore.swift)
**목표:** ~153개 파일(분할 후)이 기능/도메인별로 구성됨


## 목표 구조

```
MyTranslation/
├── App/
│   ├── MyTranslateApp.swift
│   ├── AppContainer.swift
│   ├── UserSettings.swift
│   └── DebugConfig.swift
│
├── Features/
│   ├── Browser/
│   │   ├── UI/
│   │   │   ├── BrowserRootView.swift
│   │   │   ├── WebContainerView.swift
│   │   │   ├── GlossaryAddSheet.swift
│   │   │   ├── FavoritesManagerView.swift
│   │   │   ├── MoreMenuView.swift
│   │   │   ├── HistoryView.swift
│   │   │   ├── HighlightedText.swift
│   │   │   └── URLBar/
│   │   │       ├── URLBarView.swift
│   │   │       ├── URLBarView+Field.swift
│   │   │       ├── URLBarView+ControlGroup.swift
│   │   │       ├── URLBarView+Suggestions.swift
│   │   │       ├── URLSuggestionsView.swift
│   │   │       ├── EnginePickerButton.swift
│   │   │       └── EnginePickerOptionsView.swift
│   │   ├── Overlay/
│   │   │   ├── OverlayPanelContainer.swift (OverlayPanel에서 분할)
│   │   │   ├── OverlayPanelView.swift (OverlayPanel에서 분할)
│   │   │   ├── TranslationSectionView.swift (OverlayPanel에서 분할)
│   │   │   └── SelectableTextView.swift (OverlayPanel에서 분할)
│   │   └── ViewModels/
│   │       ├── BrowserViewModel.swift
│   │       ├── BrowserViewModel+State.swift
│   │       ├── BrowserViewModel+Translation.swift (분할)
│   │       ├── BrowserViewModel+TranslationSegments.swift (분할)
│   │       ├── BrowserViewModel+TranslationOverlay.swift (분할)
│   │       ├── BrowserViewModel+Overlay.swift
│   │       └── BrowserViewModel+GlossaryAdd.swift
│   │
│   ├── Glossary/
│   │   ├── UI/
│   │   │   ├── GlossaryHost.swift
│   │   │   ├── GlossaryTabView.swift
│   │   │   ├── GlossaryHomeView.swift
│   │   │   ├── TermEditorSheet.swift
│   │   │   ├── TermEditorView.swift (분할)
│   │   │   ├── TermEditorView+BasicFields.swift (분할)
│   │   │   ├── TermEditorView+ComponentEditor.swift (분할)
│   │   │   ├── TermPickerSheet.swift
│   │   │   ├── PatternEditorView.swift
│   │   │   ├── PatternListView.swift
│   │   │   ├── PersonEditorView.swift
│   │   │   ├── TagChips.swift
│   │   │   └── GlossaryConstants.swift
│   │   ├── ViewModels/
│   │   │   ├── GlossaryViewModel.swift
│   │   │   ├── GlossaryHomeViewModel.swift
│   │   │   ├── TermEditorViewModel.swift (분할)
│   │   │   ├── TermEditorViewModel+Validation.swift (분할)
│   │   │   ├── TermEditorViewModel+ComponentManagement.swift (분할)
│   │   │   ├── TermEditorViewModel+Persistence.swift (분할)
│   │   │   ├── PatternEditorViewModel.swift
│   │   │   └── SheetsImportViewModel.swift
│   │   └── ImportExport/
│   │       ├── SheetsImportCoordinatorView.swift
│   │       ├── SheetsURLInputView.swift
│   │       ├── SheetsTabPickerView.swift
│   │       └── SheetsImportPreviewView.swift
│   │
│   └── Settings/
│       └── UI/
│           └── SettingsView.swift
│
├── Core/
│   ├── GlossaryEngine/
│   │   ├── Models/
│   │   │   ├── Glossary.swift
│   │   │   ├── GlossaryData.swift
│   │   │   ├── GlossaryEntry.swift
│   │   │   ├── GlossaryUtil.swift
│   │   │   ├── GlossaryAddModels.swift
│   │   │   └── RecallOptions.swift
│   │   ├── Persistence/
│   │   │   ├── GlossarySDModel.swift
│   │   │   ├── GlossarySDUpserter.swift (분할)
│   │   │   ├── GlossarySDUpserter+DryRun.swift (분할)
│   │   │   ├── GlossarySDUpserter+TermSync.swift (분할)
│   │   │   ├── GlossarySDUpserter+PatternSync.swift (분할)
│   │   │   ├── GlossarySDUpserter+Snapshots.swift (분할)
│   │   │   ├── GlossarySDSourceIndexMaintainer.swift
│   │   │   ├── AutoVariantRecord.swift
│   │   │   ├── AutoVariantStoreManager.swift
│   │   │   └── GlossaryRepository.swift (GlossaryDataProvider에서 이름 변경)
│   │   ├── Services/
│   │   │   ├── GlossaryJSONParser.swift
│   │   │   ├── GlossarySheetImport.swift
│   │   │   ├── KeyGenerator.swift
│   │   │   └── GlossaryJSON.swift
│   │   └── Algorithms/
│   │       ├── AhoCorasick.swift
│   │       └── Deduplicator.swift
│   │
│   ├── Translation/
│   │   ├── Router/
│   │   │   ├── TranslationRouter.swift
│   │   │   ├── DefaultTranslationRouter.swift
│   │   │   ├── RouterCancellationCenter.swift
│   │   │   ├── EngineTag.swift
│   │   │   ├── RouterDecision.swift
│   │   │   ├── Rules.swift
│   │   │   └── TranslationResult.swift
│   │   ├── Engines/
│   │   │   ├── TranslationEngine.swift
│   │   │   ├── AFMEngine.swift
│   │   │   ├── AFMTranslationService.swift
│   │   │   ├── GoogleEngine.swift
│   │   │   ├── GoogleTranslateV2Client.swift
│   │   │   ├── GooglePublicModels.swift
│   │   │   ├── DeepLEngine.swift
│   │   │   └── DeepLTranslateClient.swift
│   │   ├── FM/
│   │   │   ├── FMModelManager.swift
│   │   │   ├── FMOrchestrator.swift
│   │   │   ├── FMConfig.swift
│   │   │   ├── FMPostEditor.swift
│   │   │   ├── FMStylePresets.swift
│   │   │   ├── CrossEngineComparer.swift
│   │   │   ├── Reranker.swift
│   │   │   ├── FMQueryService.swift
│   │   │   ├── DefaultFMQueryService.swift
│   │   │   ├── FMProtocols.swift
│   │   │   ├── Embeddings.swift
│   │   │   ├── FMJSON.swift
│   │   │   ├── Sanitizers.swift
│   │   │   └── FMCacheKeys.swift
│   │   └── PostEditor/
│   │       ├── PostEditor.swift
│   │       └── NopPostEditor.swift
│   │
│   ├── Masking/
│   │   ├── TermMasker.swift (Masker.swift에서 이름 변경, 분할)
│   │   ├── TermMasker+SegmentPieces.swift (분할)
│   │   ├── TermMasker+PersonProcessing.swift (분할)
│   │   ├── TermMasker+Normalization.swift (분할)
│   │   ├── HangulUtils.swift (분할)
│   │   ├── MaskedPack.swift
│   │   ├── LockInfo.swift
│   │   └── TermActivationFilter.swift
│   │
│   └── WebRendering/
│       ├── Extraction/
│       │   ├── ContentExtractor.swift
│       │   └── WKContentExtractor.swift
│       ├── Inline/
│       │   ├── InlineReplacer.swift
│       │   └── WebViewInlineReplacer.swift
│       ├── Overlay/
│       │   ├── OverlayRenderer.swift
│       │   └── SelectionBridge.swift
│       └── Adapters/
│           ├── WebViewScriptExecutor.swift
│           └── WKWebViewScriptAdapter.swift
│
├── Shared/
│   ├── Models/
│   │   ├── Segment.swift
│   │   ├── SegmentPieces.swift
│   │   ├── BrowsingHistory.swift (신규 추가)
│   │   ├── AppLanguage.swift
│   │   ├── TranslationOptions.swift
│   │   ├── TranslationStyle.swift
│   │   ├── TranslationStreamingContract.swift
│   │   └── TermHighlightMetadata.swift
│   ├── Services/
│   │   └── HistoryStore.swift (신규 추가)
│   ├── Persistence/
│   │   ├── SwiftDataModel.swift
│   │   ├── Migrations.swift
│   │   ├── APIKeys.swift
│   │   └── CacheStore.swift
│   └── Utils/
│       ├── Logging.swift
│       ├── URLTools.swift
│       ├── String+Extension.swift
│       ├── Array+Extension.swift
│       ├── TextNormalize.swift
│       └── LanguageCatalog.swift
│
└── Resources/
    ├── Info.plist
    ├── Localizable.xcstrings
    └── Assets.xcassets/
```

## 주요 변경 사항 요약

### 파일 이름 변경
- `Masker.swift` → `TermMasker.swift` (파일명이 클래스명과 일치)
- `GlossaryDataProvider.swift` → `GlossaryRepository.swift` (Repository 패턴을 더 잘 반영)

### 아키텍처 재구성
**용어집을 Features와 Core로 분리:**
- **Features/Glossary/**: UI 관련사항만 (Views, ViewModels, ImportExport UI)
- **Core/GlossaryEngine/**: 플랫폼 독립적 도메인 로직, 퍼시스턴스, 알고리즘
  - TranslationRouter와 Browser가 UI를 몰라도 Core/GlossaryEngine에 의존 가능
  - Glossary UI는 Features/Glossary + Core/GlossaryEngine 둘 다 사용

### 분할할 파일들 (500줄 이상 모든 파일)

**필수 분할 (>700줄):**
1. **Masker.swift (2,153줄) → 5개 파일**
   - TermMasker.swift (~400줄): 핵심 API
   - TermMasker+SegmentPieces.swift (~500줄): 조립 로직
   - TermMasker+PersonProcessing.swift (~550줄): 인명 마스킹
   - TermMasker+Normalization.swift (~500줄): 정규화/언마스킹
   - HangulUtils.swift (~200줄): 한글 유틸리티

2. **GlossarySDUpserter.swift (902줄) → 5개 파일**
   - GlossarySDUpserter.swift (~200줄): 메인 클래스
   - GlossarySDUpserter+DryRun.swift (~150줄): 시뮬레이션
   - GlossarySDUpserter+TermSync.swift (~250줄): 용어 동기화
   - GlossarySDUpserter+PatternSync.swift (~200줄): 패턴 동기화
   - GlossarySDUpserter+Snapshots.swift (~102줄): 스냅샷 로직

3. **BrowserViewModel+Translation.swift (747줄) → 3개 파일**
   - BrowserViewModel+Translation.swift (~300줄): 메인 오케스트레이션
   - BrowserViewModel+TranslationSegments.swift (~250줄): 세그먼트 추출
   - BrowserViewModel+TranslationOverlay.swift (~197줄): 오버레이 번역

4. **TermEditorViewModel.swift (743줄) → 4개 파일**
   - TermEditorViewModel.swift (~250줄): 핵심 상태
   - TermEditorViewModel+Validation.swift (~200줄): 유효성 검사
   - TermEditorViewModel+ComponentManagement.swift (~200줄): 컴포넌트 CRUD
   - TermEditorViewModel+Persistence.swift (~93줄): 영속성

**우선순위 높은 분할 (500-700줄):**
5. **OverlayPanel.swift (593줄) → 4개 파일**
   - OverlayPanelContainer.swift (~100줄): 컨테이너
   - OverlayPanelView.swift (~230줄): 메인 패널
   - TranslationSectionView.swift (~150줄): 섹션 컴포넌트
   - SelectableTextView.swift (~113줄): UITextView 래퍼

6. **TermEditorView.swift (522줄) → 3개 파일**
   - TermEditorView.swift (~250줄): 구조
   - TermEditorView+BasicFields.swift (~150줄): 필드
   - TermEditorView+ComponentEditor.swift (~122줄): 컴포넌트

**폴더 재구성 후 고려할 추가 분할:**
7. **DefaultTranslationRouter.swift (674줄)** - 마이그레이션 중 응집도 문제 발견 시 분할
8. **WebViewInlineReplacer.swift (525줄)** - 마이그레이션 중 응집도 문제 발견 시 분할

**전략**: 먼저 폴더 재구성, 그 다음 Phase 10에서 500줄 이상 모든 파일을 새 위치 컨텍스트에 맞춰 적절한 하위 폴더로 체계적으로 분할.

**결과:** 122개 파일 → ~150개 파일, 500줄 초과 파일 없음

## 마이그레이션 단계

### Phase 0: 테스트 구조 설정
**목표:** 새 아키텍처에 맞춰 테스트 구조 재정리

**작업:**
1. MyTranslationTests/ 내 기존 테스트 분석
   - MyTranslationTests.swift
   - UnitTests/
   - Fixtures/
   - Mocks/
2. 병렬 테스트 구조 생성:
   - MyTranslationTests/Core/GlossaryEngine/
   - MyTranslationTests/Core/Translation/
   - MyTranslationTests/Core/Masking/
   - MyTranslationTests/Features/Browser/
   - MyTranslationTests/Features/Glossary/
   - MyTranslationTests/Shared/
3. 기존 테스트를 적절한 위치로 이동

**문서 업데이트:** 아직 없음

**검증:**
- 모든 테스트가 여전히 실행되고 통과함
- 테스트 구조가 메인 코드 구조를 반영함

### Phase 1: Shared 기반
**목표:** 의존성이 없는 기반 코드 이동

**이동할 파일 (21개):**
- Utils/ (6개 파일) → Shared/Utils/
- Domain/Models/ (4개 파일, **BrowsingHistory.swift 포함**) → Shared/Models/
- Domain/ValueObjects/ (4개 파일) → Shared/Models/
- Domain/Translation/ (2개 파일) → Shared/Models/
- Domain/Cache/ (1개 파일) → Shared/Persistence/
- Persistence/ (3개 파일) → Shared/Persistence/
- Services/History/ (1개 파일, **HistoryStore.swift**) → Shared/Services/

**Import 변경:** 0 (기반 레이어)

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Shared/ 섹션 추가 (Models, Persistence, Utils 하위섹션 포함)

**검증:**
- 빌드 성공
- 모든 테스트 통과

### Phase 2: Core/Masking
**목표:** 마스킹 시스템 이름 변경 및 분할

**작업:**
1. Masker.swift → TermMasker.swift로 이름 변경
2. 5개 파일로 분할 (TermMasker + 4개 확장/유틸)
3. MaskedPack.swift, LockInfo.swift, TermActivationFilter.swift 이동
4. 10-20개 import 업데이트
5. 관련 테스트 이동/업데이트

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Core/Masking 섹션 추가
- AGENTS.md 업데이트: Core/Masking을 별도 모듈로 추가

**검증:**
- 마스킹 테스트 통과
- 번역 테스트 통과

### Phase 3: Core/Translation
**목표:** 번역 인프라 이동

**이동할 파일 (30개):**
- Services/Orchestration/ → Core/Translation/Router/
- Services/Translation/Engines/ → Core/Translation/Engines/
- Services/Translation/FM/ → Core/Translation/FM/
- Services/Translation/PostEditor/ → Core/Translation/PostEditor/

**Import 변경:** 60-100개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Core/Translation 섹션 추가 (Router, Engines, FM 하위섹션 포함)
- AGENTS.md 업데이트: Translation 파이프라인 아키텍처 문서화

**검증:**
- 번역 테스트 통과
- 수동 번역 테스트 (AFM, Google, DeepL)

### Phase 4: Core/WebRendering
**목표:** 웹 렌더링 인프라 이동

**이동할 파일 (8개):**
- Services/WebRendering/ → Core/WebRendering/

**Import 변경:** 15-25개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Core/WebRendering 섹션 추가

**검증:**
- 브라우저가 페이지를 올바르게 로드함
- 콘텐츠 추출이 작동함

### Phase 5: Core/GlossaryEngine
**목표:** 용어집 도메인 로직과 퍼시스턴스를 Core로 추출

**이동할 파일 (27개 → 분할 포함 32개):**
- Domain/Glossary/Models/ → Core/GlossaryEngine/Models/ (6개 파일, GlossaryAddModels는 UI 전용이므로 제외)
- Domain/Glossary/Persistence/ → Core/GlossaryEngine/Persistence/ (GlossarySDUpserter 분할 포함 10개 파일)
  - GlossarySDUpserter.swift를 이동하면서 5개 파일로 분할
  - GlossaryDataProvider → GlossaryRepository로 이름 변경
- Domain/Glossary/Services/ → Core/GlossaryEngine/Services/ (4개 파일: JSON 파서, Sheets import 오케스트레이션, 키 생성기)
- Domain/Glossary/AhoCorasick.swift → Core/GlossaryEngine/Algorithms/
- Services/Translation/Glossary/Deduplicator.swift → Core/GlossaryEngine/Algorithms/

**Import 변경:** 80-120개 import (영향 큼 - Translation과 Browser에서 사용됨)

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Core/GlossaryEngine 섹션 추가 (Models, Persistence, Services, Algorithms 하위섹션 포함)
- AGENTS.md 업데이트: GlossaryEngine을 핵심 도메인 모듈로 문서화
- TranslationRouter가 Features/Glossary가 아닌 Core/GlossaryEngine에 의존함을 강조

**검증:**
- GlossaryEngine 테스트 통과
- 용어 마스킹을 포함한 번역 작동
- 용어 활성화/비활성화 작동

### Phase 6: App 레이어
**목표:** 애플리케이션 부트스트랩 이동

**이동할 파일 (4개):**
- Application/ → App/

**Import 변경:** 10-20개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: App/ 섹션 추가

**검증:**
- 앱이 성공적으로 실행됨

### Phase 7: Features/Glossary
**목표:** 용어집 UI 기능 이동 (Core/GlossaryEngine이 이미 제자리에 있은 후)

**이동할 파일 (14개 → 분할 포함 21개):**
- Presentation/Glossary/Views/ → Features/Glossary/UI/ (14개 파일)
  - TermEditorView.swift를 이동하면서 3개 파일로 분할
- Presentation/Glossary/ViewModel/ → Features/Glossary/ViewModels/ (5개 → 8개 파일)
  - TermEditorViewModel.swift를 이동하면서 4개 파일로 분할
- Presentation/Glossary/ImportExport/ → Features/Glossary/ImportExport/ (4개 파일: Sheets import UI)
- Domain/Glossary/GlossaryAddModels.swift → Features/Glossary/Models/ (UI 전용 모델)

**Import 변경:** 60-90개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Features/Glossary 섹션 추가
- AGENTS.md 업데이트: Glossary 기능 구조 문서화
- 명확화: Features/Glossary는 Core/GlossaryEngine에 의존

**검증:**
- 용어집 UI 로드됨
- 용어/패턴 CRUD 작동
- Sheets import UI 플로우 작동
- 편집기 유효성 검사 작동

### Phase 8: Features/Browser
**목표:** 분할을 포함한 브라우저 기능 이동

**이동할 파일:** 24개 → 분할 포함 29개 (**HistoryView.swift 포함**)

**작업:**
1. UI 파일 이동 → Features/Browser/UI/ + URLBar/ + Overlay/
   - **HistoryView.swift (신규 파일) 포함**
2. OverlayPanel.swift → 4개 파일로 분할
3. ViewModels 이동 → Features/Browser/ViewModels/
4. BrowserViewModel+Translation.swift → 3개 파일로 분할

**Import 변경:** 50-80개 import

**주의사항:**
- BrowserViewModel.swift에 히스토리 관련 기능 추가됨 (historyStore 의존성)
- URLBarView.swift에 뒤로/앞으로 버튼 기능 추가
- WebContainerView.swift에 Find 인터랙션 및 네비게이션 상태 업데이트 추가

**검증:**
- 브라우저 탐색 작동
- 번역 오버레이 작동
- 선택에서 용어집 추가 작동

### Phase 9: Features/Settings
**목표:** 설정 기능 이동

**이동할 파일:** 1개
- Presentation/Settings/SettingsView.swift → Features/Settings/UI/

**Import 변경:** 2-5개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: Features/Settings 섹션 추가

**검증:**
- 설정 화면 로드됨

### Phase 10: 파일 분할 패스
**목표:** 남은 500줄 이상 파일 체계적 분할

**분할할 파일:**
1. 새 구조의 모든 파일 검토
2. 500줄 이상 남은 파일을 위치에 따라 적절한 하위 폴더로 분할
3. 잠재적 후보: DefaultTranslationRouter.swift, WebViewInlineReplacer.swift

**Import 변경:** 20-40개 import

**문서 업데이트:**
- PROJECT_OVERVIEW.md 업데이트: 중요한 파일 분할 기록

**검증:**
- 모든 테스트 통과
- 전체 앱 스모크 테스트

### Phase 11: 정리
**목표:** 이전 디렉토리 제거 및 문서화 완료

**작업:**
1. 이전 빈 디렉토리 삭제 (Application/, Domain/, Persistence/, Presentation/, Services/)
2. 최종 문서 업데이트:
   - AGENTS.md: 새 아키텍처 완전한 개요
   - PROJECT_OVERVIEW.md: 모든 모듈을 포함한 전체 구조 문서
   - TODO.md 업데이트: 재구성 완료로 표시
   - 필요시 CLAUDE.md 업데이트
3. 전체 테스트 스위트 실행
4. 모든 주요 플로우를 포함한 전체 앱 스모크 테스트

**검증:**
- 모든 테스트 통과
- 모든 기능이 엔드투엔드로 작동:
  - 브라우저 탐색
  - 모든 엔진으로 번역
  - 용어집 CRUD
  - Sheets import
  - 용어 마스킹/활성화
  - 오버레이 패널
  - 설정

## 구현 전략

### Git 전략
```bash
git checkout -b refactor/feature-first-architecture
# Phase 0-11 작업 진행
# 각 단계 = 하나의 원자적 커밋
git commit -m "Phase N: 설명"
```

**커밋 메시지 형식:**
- Phase 0: 새 아키텍처를 반영하도록 테스트 재구성
- Phase 1: Shared 기반 이동 (Models, Persistence, Utils)
- Phase 2: Core/Masking 이동 및 분할
- Phase 3: Core/Translation 인프라 이동
- Phase 4: Core/WebRendering 이동
- Phase 5: Domain에서 Core/GlossaryEngine 추출
- Phase 6: App 부트스트랩 레이어 이동
- Phase 7: Features/Glossary UI 이동
- Phase 8: Features/Browser 이동 및 분할
- Phase 9: Features/Settings 이동
- Phase 10: 남은 큰 파일 분할 (>500줄)
- Phase 11: 이전 디렉토리 제거 및 문서 완성

### 파일 이동 기법
```bash
# 히스토리 보존을 위해 git mv 사용
git mv old/path/File.swift new/path/File.swift
```

### 파일 분할 기법
1. 새 이름으로 파일을 여러 번 복사
2. 각 복사본을 편집하여 관련 섹션만 유지
3. 새 파일에서 import/extend하도록 원본 파일 업데이트
4. 각 분할 후 빌드 및 테스트
5. 모든 분할이 작동하면 원본 삭제

### Import 업데이트
- 대량 업데이트를 위해 Xcode Find & Replace 사용
- 컴파일러가 남은 변경사항 안내하도록 함
- 점진적으로 오류 수정
- 5-10개 파일 이동 후마다 빌드

## 위험도 평가

| Phase | 위험도 | 이유 |
|-------|--------|------|
| 0 | 낮음 | 테스트 구조 재정리, 독립적 |
| 1 | 낮음 | 기반 레이어, 의존성 없음 |
| 2 | 중간 | 복잡한 파일 분할, 번역의 중심 |
| 3 | 중상 | 큰 이동, 앱 기능의 중심 |
| 4 | 중간 | 중간 복잡도, 웹 전용 |
| 5 | 높음 | 큰 도메인 추출, 영향 큼 (Translation + Browser에서 사용) |
| 6 | 낮음 | 간단한 부트스트랩 코드 |
| 7 | 중간 | UI 기능, 이미 이동된 Core/GlossaryEngine에 의존 |
| 8 | 중상 | 큰 기능, Core + Glossary에 의존성 |
| 9 | 낮음 | 단일 파일 |
| 10 | 중간 | 파일 분할, 신중한 추출 필요 |
| 11 | 낮음 | 정리만 |

## 기대 결과

**변경 전:**
- 6개 디렉토리의 125개 파일 (Application, Domain, Persistence, Presentation, Services, Utils)
  - **최근 추가**: BrowsingHistory.swift, HistoryView.swift, HistoryStore.swift
- 500줄 이상 8개 파일 (최대: 2,153줄)
- 기능 관련 코드 찾기 어려움
- 큰 파일에 관심사 혼재
- 용어집 도메인 로직이 UI 레이어와 혼재
- 테스트가 모듈별로 정리되지 않음

**변경 후:**
- 4개 최상위 디렉토리의 ~153개 파일 (App, Features, Core, Shared)
- 500줄 초과 파일 0개 (최대: ~400줄)
- 명확한 기능 경계 (Browser, Glossary, Settings)
- 깨끗한 Core 인프라 (Translation, Masking, GlossaryEngine, WebRendering)
- UI 의존성 없이 Translation 파이프라인에서 사용 가능한 플랫폼 독립적 GlossaryEngine
- 기능 또는 인프라 관심사별 쉬운 탐색
- 테스트가 코드 구조 반영
- 더 나은 유지보수성과 테스트 가능성

## 중요 파일

구현 중 세심한 주의가 필요한 파일:

1. [Services/Translation/Masking/Masker.swift](MyTranslation/Services/Translation/Masking/Masker.swift) (2,153줄) - 이름 변경 + 5방향 분할
2. [Domain/Glossary/Persistence/GlossarySDUpserter.swift](MyTranslation/Domain/Glossary/Persistence/GlossarySDUpserter.swift) (902줄) - 5방향 분할
3. [Presentation/Browser/ViewModel/BrowserViewModel+Translation.swift](MyTranslation/Presentation/Browser/ViewModel/BrowserViewModel+Translation.swift) (747줄) - 3방향 분할
4. [Presentation/Glossary/ViewModel/TermEditorViewModel.swift](MyTranslation/Presentation/Glossary/ViewModel/TermEditorViewModel.swift) (743줄) - 4방향 분할
5. [Services/Ochestration/DefaultTranslationRouter.swift](MyTranslation/Services/Ochestration/DefaultTranslationRouter.swift) (674줄) - 중앙 번역 라우팅

## 적용된 사용자 결정사항

사용자 피드백을 기반으로 다음 결정사항이 반영되었습니다:

1. **파일 분할 범위**: 500줄 이상 모든 파일 분할 (700줄 이상만이 아님)
   - 먼저 폴더 재구성, 그 다음 Phase 10에서 파일 체계적 분할

2. **용어집 아키텍처**: 옵션 B - 용어집을 Features와 Core로 분리
   - **Features/Glossary/**: UI, ViewModels, ImportExport UI 플로우
   - **Core/GlossaryEngine/**: 도메인 모델, 퍼시스턴스, 알고리즘, Import/Export 서비스
   - TranslationRouter가 UI 결합 없이 Core/GlossaryEngine에 의존 가능

3. **테스트**: MyTranslationTests/ 디렉토리에 테스트 존재
   - Phase 0에서 새 코드 아키텍처를 반영하도록 테스트 구조 재정리
   - 각 단계에 테스트 검증 포함

4. **마이그레이션 접근법**: 점진적 (11단계, 단계당 하나의 커밋)
   - 단계 사이 검토 가능
   - 각 단계가 작동 상태 유지

5. **문서 업데이트**: 각 단계마다 점진적 업데이트
   - 모듈 이동에 따라 PROJECT_OVERVIEW.md 업데이트
   - 아키텍처 변경에 따라 AGENTS.md 업데이트
   - Phase 11에서 최종 종합 업데이트

## 주요 아키텍처 인사이트

### 의존성 흐름
```
Features/Browser ──→ Core/Translation ──→ Core/Masking ──→ Core/GlossaryEngine
       ↓                                          ↓
Features/Glossary ─────────────────────→ Core/GlossaryEngine
       ↓
  Shared/Models, Shared/Utils
```

### Core/GlossaryEngine 분리 근거
- **문제점**: 현재 구조는 Domain/Glossary에 용어집 도메인 로직이 있지만 Presentation 레이어와 밀접하게 결합됨
- **해결책**: Core/GlossaryEngine으로 추출하여:
  - TranslationRouter가 Glossary UI를 몰라도 용어집 매칭 사용 가능
  - TermMasker가 UI 의존성 없이 용어집 항목에 접근 가능
  - Browser가 깨끗한 도메인 인터페이스를 통해 용어집에 용어 추가 가능
  - Glossary UI가 Core/GlossaryEngine의 또 다른 소비자가 됨
- **결과**: 더 나은 테스트 가능성, 더 명확한 의존성, 더 재사용 가능한 도메인 로직
