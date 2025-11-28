# AGENTS.md — Multi-Agent Entry

이 리포지토리는 Claude / Codex / ChatGPT 등을 포함한 **여러 에이전트가 함께 작업하는 코드베이스**입니다.

모든 에이전트는 작업을 시작하기 전에 **아래 문서를 이 순서로 확인**해야 합니다.

1. `AGENT_RULES.md`  
   - 멀티 에이전트 공통 규칙, 코드/문서 편집 규칙, 체크리스트.
2. `PROJECT_OVERVIEW.md`  
   - 프로젝트 개요, 폴더 구조, 아키텍처, 핵심 타입/모듈 설명.
3. `TODO.md`  
   - 현재 진행 중인 작업 목록과 상태.

## 기본 원칙 (요약)

- 규칙/프로세스를 바꾸고 싶으면 **`AGENT_RULES.md`를 수정**합니다.
- 프로젝트 설명, 폴더 구조, 핵심 타입/모듈 설명을 바꾸면 **`PROJECT_OVERVIEW.md`를 수정**합니다.
- 실제 작업(구현/리팩터링/버그픽스 등)을 하면 **`TODO.md`를 업데이트**합니다.
- Xcode 빌드/테스트 명령은 **Xcode와 iOS 시뮬레이터가 준비된 환경에서만** 실행합니다.  
  (로컬·CI 환경이 지원하지 않으면, 명령을 실행하지 말고 참고용으로만 사용합니다.)
- 번역 파이프라인은 `MyTranslation/Core/Translation/` 아래로 이동했습니다. (Router/Engines/FM/PostEditor 하위 디렉터리 구성)
- Glossary 엔진/저장소는 `MyTranslation/Core/GlossaryEngine/` 아래에 위치합니다. (Models/Persistence/Services/Algorithms 하위 디렉터리)
- Glossary UI/ViewModel/ImportExport는 `MyTranslation/Features/Glossary/` 아래에 위치합니다.
- Browser UI/ViewModel은 `MyTranslation/Features/Browser/` 아래에 위치합니다.
- Settings UI는 `MyTranslation/Features/Settings/` 아래에 위치합니다.

자세한 규칙과 체크리스트는 `AGENT_RULES.md`를 반드시 참고하세요.
