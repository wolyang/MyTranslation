# TODO.md — Project Tasks

형식 제안:
- 상태: `[ ]` 미완료 / `[x]` 완료
- 우선순위: (P0 / P1 / P2)
- 가능하면 한 줄에 “무엇을, 왜”까지 간단히.

---

## 진행 중/우선 작업
- [ ] (P1) Glossary auto-variant 기능 구현(감지된 Term에 variants를 자동 추가해 관리 편의 개선).
- [ ] (P2) 페이지 전체 번역 시 생성된 MaskingContext를 오버레이 엔진 호출에서도 재사용하도록 통합 (중복 생성 여부 판단 및 캐시/옵션 정합성 검증).

## 완료된 작업
- [x] (P0) Glossary Service 리팩토링(`History/SPEC_GLOSSARY_SERVICE_REFACTOR.md`):
  - [x] Phase 1: 타입 및 파일 분리
  - [x] Phase 2: 데이터 계층 리팩토링 (GlossaryDataProvider)
  - [x] Phase 3: 서비스 계층 구현 (GlossaryComposer)
  - [x] Phase 4: TranslationRouter 통합
  - [x] Phase 5: 레거시 코드 제거 및 문서 업데이트
- [x] (P1) Term 문맥 기반 비활성화 기능 구현(`History/SPEC_TERM_DEACTIVATION.md` 참조):
  - [x] Phase 1: 핵심 기능 — SDSource/GlossaryEntry 모델 확장, GlossaryComposer 수정, TermMasker에 filterByContextDeactivation 구현
  - [x] Phase 2: Import & UI — Google Sheets 파싱/Validation, TermEditorSheet UI, Import Preview
  - [x] Phase 3: 테스트 & 문서 — 단위/통합 테스트, 문서 업데이트
- [x] (P1) 오버레이 패널에서 용어집 추가 기능 구현(`History/SPEC_OVERLAY_GLOSSARY_ADD.md` 참조):
  - [x] Phase 1: 기본 플로우 (번역문 선택 → variants 추가) — 컨텍스트 메뉴/시트/TermEditor 진입점, 기존 용어/새 용어 추가까지 연결
  - [x] Phase 2: 원문 선택 지원 — 하이라이트 매칭된 기존 용어 편집/새 용어 추가 흐름 완료
  - [x] Phase 3: 고급 기능 — 번역문 선택 시 후보 추출·우선순위(위치·유사도) 표시, 후보 기반 변형 추가/원문 입력 UI, 추천 없음/잘림 안내, 대규모 후보 스캔/표시 상한 적용
  - [x] Phase 4: 최적화 및 테스트 — 후보 스캔 상한·표시 제한으로 성능/안정성 보완, 수동 확인 및 핵심 단위테스트(후보 정렬/상한, 매칭 검증) 추가 완료
- [x] (P2) 번역 엔진들이 전체 문서에 나타나는 GlossaryEntry 배열, 세그먼트 별 SegmentPiece 배열을 엔진마다 새로 요청하고 생성하지 않고 공통으로 사용하도록 수정 (MaskingContext 공유 API 추가, 오버레이에서 재사용 적용). 
- [x] (P1) Phase 4 변형 추적 및 1글자 변형 필터링 추가(실제 매칭 변형만 재사용하여 잔여 정규화 시 오염 방지).
- [x] (P2) Phase 4 잔여 일괄 교체 구현(BUG-004) 및 보호 범위/하이라이트 추적 포함.
- [x] (P2) 오버레이 패널 기능 확장(정규화 전/후 원문 노출, 감지된 용어/마스킹·정규화 결과를 원문/번역문에 색상 표시).
- [x] (P1) 새로고침 시 캐시 삭제 및 번역 상태 초기화 기능 구현(CacheStore에 clearAll/clearBySegmentIDs 메서드 추가, refreshAndReload에서 페이지별 캐시 삭제로 항상 최신 번역 보장).
- [x] (P2) 순서 기반 용어 정규화/언마스킹 개선(SegmentPieces 원문 순서를 활용한 3단계 fallback으로 동음이의어·동명이인 정규화 정확도를 70-90% 개선).
- [x] (P1) 세그먼트에서 용어집 용어 감지 로직 리팩토링(텍스트와 용어 집합으로 변환 후 마스킹/정규화까지 range 정보를 보존해 후속 처리/오버레이 개선 용이).
