# REFACTORING_PATTERN_REMAINING_PLAN

## 목표
- 패턴 리팩토링으로 바뀐 스키마(source_templates + target_template/variant_templates, roles 배열, role_combinations 분리)를 Glossary UI와 테스트까지 반영해 기존 기능(용어/패턴 목록, 편집, 임포트)이 정상 동작하도록 정리한다.

## 우선 작업 (Glossary UI)
- [ ] 패턴/용어 목록(`GlossaryHomeViewModel`): 컴포넌트 템플릿 인덱스 고정값 제거, pattern.roles 기반 역할 표기 및 프리뷰 렌더링을 slot-aware 헬퍼로 교체, group 필터/복제 시 새 필드 유지 확인.
- [ ] 패턴 편집(`PatternEditorViewModel`): left/right 필드 대신 roles 배열(또는 role_combinations 입력) + `target_template`/`variant_templates` 편집 UI로 교체하고 저장/로딩 로직을 새 스키마에 맞게 정리(불필요한 sourceJoiners 필드 제거 포함).
- [ ] 용어 편집(`TermEditorViewModel`): 패턴 옵션에서 target/variant 템플릿을 분리해 보여주고 템플릿 인덱스 선택 UI 제거, pattern.roles 기반 role 선택만 유지, 컴포넌트 저장/불러오기 시 새 모델 필드만 다루도록 수정.
- [ ] 패턴 목록 화면: PatternSummary가 메타 roles 없이도 roles/variant 정보를 노출하도록 설계 재검토(표시용 label/플레이스홀더 업데이트).

## 데이터/임포트/테스트 정리
- [ ] `GlossaryJSONParser`/Sheets import: `target_template` 단일/다중 입력 처리 규칙 명확화(세미콜론 분리 여부 결정) 후 코드/문서 반영, role_combinations 분해 로직 검증 케이스 추가.
- [ ] 테스트 업데이트: `GlossaryImportTests` 등 srcTplIdx/tgtTplIdx/joiner 의존 테스트를 새 스키마로 수정하고, slot 기반 `SegmentEntriesBuilder`(동일 role 반복, preMask 스킵, grouping) 케이스 단위 테스트 추가.
- [ ] 문서 정리: `REFACTORING_PATTERN.md` 진행 상황/새 스키마 예제를 최신 상태로 갱신하고, 필요 시 관련 스펙 문서에서 제거된 필드 언급 삭제.

## 검증 체크리스트
- [ ] 샘플 시트/JSON을 role_combinations, variant_templates 포함해 임포트 → Pattern/Term 목록/편집 화면에서 데이터가 기대대로 표시·수정되는지 확인.
- [ ] slot 기반 GlossaryEntry 생성이 이름 패턴({name}{name} 등)과 preMask 패턴에서 정상 동작하며, 렌더링 결과가 세그먼트 텍스트에 존재하는지 필터링되는지 확인.
- [ ] Glossary 추가/하이라이트 흐름(`BrowserViewModel+GlossaryAdd`, TextEntityProcessing 파이프라인)에서 composer termKeys로 바뀐 origin 구조를 사용해도 후보/하이라이트가 정상인지 수동 점검.
