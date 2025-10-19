# 스트리밍 번역 계약 요약

이 문서는 TranslationRouter/Engine 계층과 Web UI가 공유하는 스트리밍 번역 계약을 설명합니다. 동일한 계약은 `TranslationStreamEvent`, `TranslationStreamPayload`, `TranslationStreamSummary` 타입과 InlineReplacer/BrowserViewModel 구현에서 사용됩니다.

## 주요 타입

- **TranslationStreamPayload**
  - `segmentID`: 세그먼트 고유 ID (`Segment.id`)
  - `originalText`: 원문 텍스트 (DOM 복구 시 사용)
  - `translatedText`: 최신 번역문 (없을 경우 `nil`)
  - `engineID`: 실행한 엔진 식별자 (`TranslationEngineID`, 현재는 `EngineTag.rawValue`)
  - `sequence`: 이벤트 순서를 유지하기 위한 증가 수 (0부터 시작)
- **TranslationStreamEvent.Kind**
  - `cachedHit`: 캐시 적중 시점. 이어서 `final` 이벤트가 따라옵니다.
  - `requestScheduled`: 엔진 호출이 예약되었음을 의미합니다.
  - `partial(segment:)`: 엔진에서 부분 결과를 수신했을 때.
  - `final(segment:)`: 최종 결과가 확정되었을 때. UI는 이 payload를 즉시 반영합니다.
  - `failed(segmentID:error:)`: 해당 세그먼트 처리 실패.
  - `completed`: 모든 세그먼트 처리가 종료되었음을 의미합니다.
- **TranslationStreamSummary**
  - `totalCount`, `succeededCount`, `failedCount`, `cachedCount` 를 포함하여 Router가 전체 처리 결과를 요약합니다.

## 이벤트 호출 순서

Router/Engine 구현은 다음 순서를 보장해야 합니다. (세그먼트마다 `partial`/`final`/`failed` 순서는 상황에 따라 반복 가능)

1. `cachedHit` (캐시 적중 시 즉시 발생하며 `final` 이벤트로 이어짐)
2. `requestScheduled` (엔진 호출이 시작될 때)
3. `partial` / `final` (엔진에서 세그먼트 결과를 받는 즉시)
4. `failed` (세그먼트 처리 실패 시)
5. `completed` (요청 전체 완료 시)

## 예시 스트림

- **모두 캐시 적중**
  - `cachedHit` → `final(segment A)`
  - `cachedHit` → `final(segment B)`
  - `completed`
- **부분 캐시 + 엔진 호출**
  - `cachedHit` → `final(segment A)`
  - `requestScheduled`
  - `partial(segment B seq=1)`
  - `final(segment B seq=2)`
  - `completed`
- **엔진 오류**
  - `requestScheduled`
  - `failed(segment C, error: .engineFailure)`
  - `completed`

## JS 브리지

`WebViewInlineReplacer` 는 다음 JS 함수를 사용합니다.

```javascript
window.__afmInline.setAll(payloads, { observer: 'keep|restart|disable' })
window.__afmInline.upsertPair(payload, { immediate: true, schedule: true, highlight: true })
window.__afmInline.applyAll()
window.__afmInline.restoreAll()
```

payload 구조는 `TranslationStreamPayload` 와 동일하며 BrowserViewModel의 스트리밍 이벤트 처리에서도 그대로 사용합니다. 새로운 이벤트 타입을 추가할 경우 위 두 컴포넌트와 본 문서를 함께 업데이트하십시오.

## TODO / NOTE

- [NOTE] InlineReplacer와 BrowserViewModel은 동일한 payload 구조를 공유합니다. 계약 수정 시 두 구현과 본 문서를 동시에 갱신하세요.
