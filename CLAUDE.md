# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MyTranslation is an iOS translation browser app built with SwiftUI that translates web pages in real-time using multiple translation engines. The app uses Apple Foundation Models (AFM), Google Translate, and DeepL for translation, with on-device AI models for post-editing and quality enhancement.

## Build and Test Commands

### Building
```bash
# Build the project
xcodebuild -scheme MyTranslation -configuration Debug build

# Build for release
xcodebuild -scheme MyTranslation -configuration Release build
```

### Testing
```bash
# Run all tests
xcodebuild test -scheme MyTranslation -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test target
xcodebuild test -scheme MyTranslation -only-testing:MyTranslationTests

# Run specific test case
xcodebuild test -scheme MyTranslation -only-testing:MyTranslationTests/MyTranslationTests/testExample
```

### Opening in Xcode
```bash
open MyTranslation.xcodeproj
```

## Architecture

### Core Architectural Patterns

**Clean Architecture with Domain-Driven Design**: The codebase follows a layered architecture separating concerns into Domain, Application, Presentation, Services, and Persistence layers.

**Translation Pipeline Architecture**: The app uses a streaming translation pipeline that processes web content through multiple stages:
1. **Content Extraction** → Web page segmentation into translatable units
2. **Translation Routing** → Engine selection and request orchestration
3. **Translation Streaming** → Progressive translation with real-time updates
4. **Post-Processing** → AI-powered quality enhancement (post-editing, comparison, reranking)
5. **Rendering** → Inline replacement or overlay display

### Key Components

#### Translation Router (`Services/Ochestration/`)
The `TranslationRouter` protocol defines the core streaming translation API. `DefaultTranslationRouter` orchestrates translation requests across multiple engines:

- **Cache-first strategy**: Checks cache before making engine requests
- **Streaming contract**: Events flow in this order: `cachedHit` → `requestScheduled` → `partial`/`final` → `failed` → `completed`
- **Engine routing**: Routes to AFM (on-device), Google, or DeepL based on user preference
- **Glossary integration**: Applies user-defined term glossaries during translation

Reference: `TranslationStreamingContract.swift` defines the streaming event types (`TranslationStreamEvent`, `TranslationStreamPayload`, `TranslationStreamSummary`).

#### Translation Engines (`Services/Translation/Engines/`)
Each engine implements the `TranslationEngine` protocol with streaming support:

- **AFMEngine**: Uses Apple Foundation Models via `Translation` framework with batched streaming
- **GoogleEngine**: Calls Google Translate V2 API
- **DeepLEngine**: Integrates DeepL API (supports free tier)

All engines return `AsyncThrowingStream<[TranslationResult], Error>` for progressive results.

#### FM (Foundation Model) Pipeline (`Services/Translation/FM/`)
On-device AI model orchestration for translation quality enhancement:

- **FMOrchestrator**: Coordinates post-edit, comparison, and reranking stages
- **FMModelManager** (`Core/`): Manages on-device model lifecycle
- **FMPostEditor** (`PostEdit/`): Style-aware translation refinement using local LLM
- **CrossEngineComparer** (`Consistency/`): Compares results from multiple engines
- **Reranker** (`Consistency/`): Semantic similarity-based result ranking
- **FMQueryService** (`Interactive/`): Interactive translation queries

Configuration via `FMConfig`:
```swift
FMConfig(
    enablePostEdit: true,  // Apply style-aware post-editing
    enableComparer: false, // Cross-engine comparison
    enableRerank: false    // Semantic reranking
)
```

#### Glossary System (`Domain/Glossary/`)
User-defined terminology management with SwiftData persistence:

- **Models**: `SDTerm`, `SDPattern`, `SDComponent`, `SDTag` (SwiftData models)
- **Persistence**: `GlossarySDSourceIndexMaintainer` manages term indexing
- **Import**: `GlossarySheetImport` supports Google Sheets import via API
- **Service**: `Glossary.Service` provides term matching and application during translation

Patterns support roles (e.g., character names with grammatical particle handling in Korean).

#### Web Rendering (`Services/WebRendering/`)
Bridges translation results to WKWebView display:

- **ContentExtractor**: Extracts translatable segments from web pages with `data-seg-id` attributes
- **InlineReplacer**: Uses JavaScript bridge (`window.__afmInline.upsertPayload`) to replace text inline
- **OverlayRenderer**: Displays translations as overlays with selection support
- **SelectionBridge**: Handles text selection for interactive translation

JavaScript contract reference: Comments in `WebViewInlineReplacer.swift:10`

#### Masking (`Services/Translation/Masking/`)
Protects sensitive terms during translation:

- **TermMasker**: Masks glossary terms and person names to prevent mistranslation
- **MaskedPack**: Encapsulates original text, masked version, and lock info for unmask
- **Hangul handling**: Special logic for Korean particles (받침/종성) via `hangulFinalJongInfo()`

### Dependency Injection

`AppContainer` is the main DI container initialized at app launch:

```swift
AppContainer(
    context: ModelContext,        // SwiftData persistence
    useOnDeviceFM: true,          // Enable Foundation Models
    fmConfig: FMConfig(...)       // FM configuration
)
```

All services (engines, router, cache, glossary) are instantiated here and injected into ViewModels.

### State Management

- **BrowserViewModel**: Main VM managing translation state, web navigation, language preferences
  - `currentPageTranslation: PageTranslationState?` tracks per-page translation status
  - `languagePreferenceByURL` remembers language choices per URL
  - `translateStream()` drives the streaming translation pipeline

- **GlossaryViewModel**: Manages glossary CRUD operations with SwiftData

### Persistence

- **SwiftData**: Used for glossary storage (terms, patterns, tags, groups)
- **UserSettings**: AppStorage-backed settings (@Published properties)
- **CacheStore**: In-memory translation cache (protocol-based, default implementation in `DefaultCacheStore`)
- **API Keys**: Retrieved from Info.plist (`GoogleAPIKey`, `DeepLAuthKey`)

## Common Development Patterns

### Adding a New Translation Engine

1. Create client in `Services/Translation/Engines/<EngineName>/`
2. Implement `TranslationEngine` protocol with streaming support
3. Add engine tag to `EngineTag` enum
4. Register in `AppContainer` and `DefaultTranslationRouter`
5. Update UI picker in `EnginePickerOptionsView`

### Modifying Translation Stream

The streaming contract is defined in `Domain/Translation/TranslationStreamingContract.swift`. Event order must be preserved:
1. `cachedHit` (if cache hit)
2. `requestScheduled` (before engine call)
3. `partial` / `final` (streaming results)
4. `failed` (on segment error)
5. `completed` (end of stream)

Update `DefaultTranslationRouter.translateStream()` for routing logic changes.

### Working with Glossary Models

Glossary uses SwiftData models under `Glossary.SDModel` namespace:
- Always perform operations within a `@MainActor` context
- Use `GlossaryService` for business logic, not direct model access
- Index maintenance is automatic via `GlossarySDSourceIndexMaintainer`

### Testing Translation Pipeline

Create mock implementations of core protocols:
- `TranslationEngine` → Mock engine returning test results
- `CacheStore` → In-memory cache for deterministic tests
- `PostEditor`, `ResultComparer` → Nop implementations or test doubles

## Configuration

### API Keys
API keys are stored in `MyTranslation/Resources/Info.plist`:
- `GoogleAPIKey`: Google Translate API key
- `DeepLAuthKey`: DeepL API authentication key

**Security note**: The Info.plist file contains API keys and should be excluded from version control in production. Consider using environment variables or secure key management.

### Feature Flags
Foundation Model features are toggled in `AppContainer` initialization:
```swift
FMConfig(
    enablePostEdit: true,   // On-device post-editing
    enableComparer: false,  // Cross-engine comparison
    enableRerank: false     // Semantic reranking
)
```

### Translation Settings
User-configurable settings in `UserSettings`:
- Source/target language preferences (per-URL via `BrowserViewModel.languagePreferenceByURL`)
- Preferred translation engine
- Translation style (via `TranslationStyle` value object)
- Apply glossary toggle

## Project Structure

```
MyTranslation/
├── Application/           # App entry point, DI container
├── Domain/               # Domain models and business logic
│   ├── Cache/           # Cache abstractions
│   ├── Glossary/        # Glossary domain (models, persistence, services)
│   ├── Models/          # Core domain models (Segment)
│   ├── Translation/     # Translation contracts
│   └── ValueObjects/    # Language, style, options
├── Presentation/         # SwiftUI views and ViewModels
│   ├── Browser/         # Main browser UI
│   ├── Glossary/        # Glossary management UI
│   └── Settings/        # Settings UI
├── Services/            # Application services
│   ├── Adapters/        # External adapters (WKWebView)
│   ├── Ochestration/    # Translation routing and orchestration
│   ├── Translation/     # Translation engines and FM pipeline
│   │   ├── Engines/     # AFM, Google, DeepL engines
│   │   ├── FM/          # Foundation Model components
│   │   ├── Masking/     # Term masking
│   │   └── PostEditor/  # Post-editing protocols
│   └── WebRendering/    # Web content extraction and rendering
├── Persistence/         # Data persistence (SwiftData, API keys)
└── Utils/               # Shared utilities
```

## Language and Localization

- Code comments and documentation are primarily in Korean
- UI strings use localized resources (via SwiftUI `LocalizedStringKey`)
- `LanguageCatalog` provides language metadata and defaults
- `AppLanguage` enum defines supported languages

## WebView Integration

The app uses WKWebView with custom JavaScript injection for:
- Content segmentation (adding `data-seg-id` attributes)
- Inline translation updates via `window.__afmInline` bridge
- Text selection and overlay positioning

Script injection happens in `WKWebViewScriptAdapter` and `WebViewInlineReplacer`.
