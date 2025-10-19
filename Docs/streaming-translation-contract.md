# Streaming Translation Contract

`TranslationStreamEvent`, `TranslationStreamPayload`, 그리고 `TranslationStreamSummary` 는 Router ↔︎ Engine ↔︎ Presentation 계층이 공통으로 준수해야 하는 스트리밍 번역 계약입니다. 모든 계층은 **동일한 이벤트 순서**와 **payload 구조**를 공유해야 하며, InlineReplacer 및 BrowserViewModel 또한 이 구조를 그대로 재사용합니다.

## 이벤트 순서

Progress 콜백(`(TranslationStreamEvent) -> Void`)은 다음 순서를 보장합니다.

1. `cachedHit` – 캐시 적중 시 즉시 전달 (해당 세그먼트는 바로 `final` 이벤트가 뒤따름)
2. `requestScheduled` – 엔진 호출이 시작될 때 1회 전달
3. `partial(segment:)` – 엔진이 부분 번역을 반환하는 즉시 전달 (선택적)
4. `final(segment:)` – 세그먼트 번역이 확정되면 즉시 전달
5. `failed(segmentID:error:)` – 오류 발생 시 해당 세그먼트에 대해 전달
6. `completed` – 전체 요청이 종료되면 1회 전달 (요약 정보는 `translateStream` 의 반환값으로 전달)

## Payload 구조

```swift
struct TranslationStreamPayload: Codable, Sendable, Equatable {
    let segmentID: String
    let originalText: String
    let translatedText: String?
    let engineID: TranslationEngineID
    let sequence: Int
}
```

* `segmentID` – 원본 세그먼트 식별자.
* `originalText` – Router/Engine 이 판단한 원문 (마스킹 등 전처리 후의 텍스트 포함 가능).
* `translatedText` – 번역문. `partial` 단계에서는 `nil` 또는 미완성 값일 수 있습니다.
* `engineID` – Router 가 선택한 엔진 ID 문자열. (예: `"afm"`, `"google"`).
* `sequence` – Router 가 보장하는 증가 숫자. Presentation 계층은 이 값을 이용해 수신 순서를 정렬합니다.

> **NOTE**: `InlineReplacer` 와 `BrowserViewModel` 은 위 payload 를 그대로 저장/재사용합니다. JS 브릿지(`window.__afmInline.upsertPayload`) 역시 동일한 키 (`segmentID`, `originalText`, `translatedText`, `engineID`, `sequence`) 를 사용합니다.

## TranslationStreamSummary

Router 는 `translateStream` 완료 시 `TranslationStreamSummary` 를 반환합니다.

```swift
struct TranslationStreamSummary: Codable, Sendable, Equatable {
    let totalCount: Int
    let succeededCount: Int
    let failedCount: Int
    let cachedCount: Int
}
```

요약은 이벤트 스트림과 별도로 반환되며, `completed` 이벤트는 순수 종료 신호입니다.

## 예시 스트림 시퀀스

아래는 3개의 세그먼트 요청이 혼합된 예시입니다.

- `cachedHit`
- `final(segment: #1)`
- `requestScheduled`
- `partial(segment: #2)`
- `final(segment: #2)`
- `partial(segment: #3)`
- `failed(segmentID: #3, error: engineFailure(code: "TIMEOUT"))`
- `completed`

이후 Router 는 `TranslationStreamSummary(totalCount: 3, succeededCount: 2, failedCount: 1, cachedCount: 1)` 를 반환합니다.

## 후속 작업 참고

- Engine 구현체는 `TranslationStreamPayload` 의 schema 를 그대로 사용해야 하며, 새로운 필드가 필요할 경우 Domain 계약부터 확장해야 합니다.
- Presentation 계층은 `TranslationStreamEvent.Kind` 의 모든 케이스를 처리해야 합니다. 특히 `cachedHit`/`requestScheduled` 는 부가 정보가 없는 신호라는 점을 명시했습니다.
- InlineReplacer 수정 시 본 문서를 재검토하고 BrowserViewModel 과 동기화되어 있는지 확인하세요. (`TODO`/`NOTE` 주석 참조)
