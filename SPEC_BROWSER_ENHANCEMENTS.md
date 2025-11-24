# 브라우저 편의 기능 개선 테크스펙

## 1. 개요

MyTranslation 브라우저뷰의 사용자 경험을 개선하기 위한 편의 기능들을 정의합니다.
이 문서는 사용자가 요청한 검색 리다이렉트 기능과 추가로 제안하는 편의 기능들의 구현 사양을 포함합니다.

---

## 2. 현재 브라우저 구현 분석

### 2.1 주소창 URL 처리 로직
- **파일**: `BrowserViewModel.swift`
- **메서드**: `normalizedURL(from: String) -> URL?` (108-112줄)
- **현재 동작**:
  1. URL 스킴이 있으면 그대로 사용
  2. 스킴이 없으면 "https://" 접두사 추가
  3. URL 파싱 실패 시 `nil` 반환 → 페이지 로딩 안 함

### 2.2 기존 구현된 기능
- ✅ 즐겨찾기 관리 (추가/편집/삭제/이동)
- ✅ 번역 기능 (다중 엔진, 스트리밍)
- ✅ 용어집 통합
- ✅ WKWebView 네비게이션 제스처 (뒤로/앞으로 스와이프)
- ✅ 최근 URL 추천
- ✅ 클립보드 URL 붙여넣기

---

## 3. 신규 기능 사양

### 3.1 주소창 검색어 입력 시 구글 검색 리다이렉트 (사용자 요청)

#### 3.1.1 요구사항
- 주소창에 입력한 문자열이 URL 형식이 아닐 경우, 구글 검색 결과 페이지로 자동 리다이렉트
- URL 형식 판별 실패 시에도 사용자가 웹 검색을 수행할 수 있도록 지원

#### 3.1.2 URL vs 검색어 판별 기준

다음 조건을 **모두 만족**하면 **URL**로 간주:
1. 문자열에 공백이 포함되지 않음
2. 다음 중 하나를 만족:
   - 유효한 URL 스킴 포함 (`http://`, `https://`, `file://` 등)
   - 점(`.`)을 포함하고 도메인 형식으로 파싱 가능 (`example.com`, `www.naver.com` 등)

위 조건을 만족하지 못하면 **검색어**로 간주합니다.

#### 3.1.3 검색 엔진 URL 구성
```swift
// 예시 URL 템플릿
let searchQuery = userInput.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
let googleSearchURL = "https://www.google.com/search?q=\(searchQuery)"
```

#### 3.1.4 구현 위치
- **파일**: `BrowserViewModel.swift`
- **메서드**: `normalizedURL(from: String) -> URL?` 수정
- **로직**:
  ```swift
  func normalizedURL(from string: String) -> URL? {
      guard !string.isEmpty else { return nil }
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

      // 1. 스킴이 있으면 URL로 간주
      if let url = URL(string: trimmed), url.scheme != nil {
          return url
      }

      // 2. 점이 포함되고 공백이 없으면 도메인으로 간주 (https:// 추가)
      if !trimmed.contains(" ") && trimmed.contains(".") {
          return URL(string: "https://" + trimmed)
      }

      // 3. 그 외에는 검색어로 간주
      let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
      return URL(string: "https://www.google.com/search?q=\(encoded)")
  }
  ```

#### 3.1.5 테스트 케이스
| 입력 | 결과 URL |
|------|----------|
| `https://example.com` | `https://example.com` |
| `example.com` | `https://example.com` |
| `www.naver.com` | `https://www.naver.com` |
| `번역 앱 개발` | `https://www.google.com/search?q=번역%20앱%20개발` |
| `swift programming` | `https://www.google.com/search?q=swift%20programming` |
| `localhost:8080` | `https://localhost:8080` (점 포함) |

---

### 3.2 뒤로/앞으로 가기 버튼

#### 3.2.1 요구사항
- URL 바 영역에 뒤로/앞으로 가기 버튼 추가
- WKWebView의 `canGoBack`, `canGoForward` 상태에 따라 버튼 활성화/비활성화
- 현재 제스처 기반 네비게이션은 유지

#### 3.2.2 UI 구성
- **위치**: `URLBarView.swift`의 `HStack` 내부, URL 입력 필드 왼쪽
- **아이콘**:
  - 뒤로 가기: `chevron.left`
  - 앞으로 가기: `chevron.right`
- **버튼 스타일**: `.buttonStyle(.plain)`, 비활성화 시 `.opacity(0.3)`

#### 3.2.3 구현 방법
1. `BrowserViewModel`에 `@Published var canGoBack: Bool = false`, `canGoForward: Bool = false` 추가
2. `attachWebView(_:)` 또는 페이지 로딩 완료 시 WKWebView 상태 관찰 (KVO 또는 delegate)
3. `URLBarView`에 버튼 추가, 클릭 시 콜백 호출
4. `BrowserRootView`에서 콜백 구현 → `webView.goBack()`, `webView.goForward()` 호출

#### 3.2.4 예상 구현 위치
- **BrowserViewModel.swift**: 네비게이션 상태 프로퍼티 추가
- **URLBarView.swift**: 버튼 UI 추가
- **BrowserRootView.swift**: 버튼 액션 핸들러 연결

---

### 3.3 페이지 내 검색 (Find in Page)

#### 3.3.1 요구사항
- 사용자가 현재 페이지 내에서 특정 텍스트를 검색할 수 있는 기능
- 검색 결과 하이라이트 표시 및 다음/이전 결과로 이동
- iOS 16+ WKWebView의 `FindInteraction` API 활용

#### 3.3.2 UI 구성
- **진입점**: MoreMenuView에 "페이지 내 검색" 메뉴 항목 추가
- **검색 바**: iOS 기본 Find 인터페이스 사용 (`WKWebView.findInteraction`)

#### 3.3.3 구현 방법
1. iOS 16+ 타겟 확인 (`if #available(iOS 16.0, *)`)
2. `WebContainerView`의 `WKWebView` 설정 시 `findInteraction` 활성화:
   ```swift
   webView.isFindInteractionEnabled = true
   ```
3. MoreMenuView에 버튼 추가 → 탭 시 Find 인터페이스 호출:
   ```swift
   webView.findInteraction?.presentFindNavigator(showingReplace: false)
   ```

#### 3.3.4 예상 구현 위치
- **WebContainerView.swift**: `isFindInteractionEnabled = true` 설정
- **BrowserViewModel.swift**: `showFindInPage()` 메서드 추가
- **MoreMenuView.swift**: "페이지 내 검색" 메뉴 항목 추가

---

### 3.4 데스크톱 모드 요청 (Request Desktop Site)

#### 3.4.1 요구사항
- 모바일 사이트가 아닌 데스크톱 버전 사이트를 로딩
- WKWebView의 User-Agent 문자열 변경으로 구현

#### 3.4.2 구현 방법
1. `BrowserViewModel`에 `@Published var isDesktopMode: Bool = false` 추가
2. `WebContainerView` 또는 `WKWebView` 설정에서 User-Agent 변경:
   ```swift
   if isDesktopMode {
       webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
   } else {
       webView.customUserAgent = nil // 기본 모바일 User-Agent
   }
   ```
3. MoreMenuView에 토글 추가 → 변경 시 페이지 reload

#### 3.4.3 UI 구성
- **위치**: MoreMenuView 내 토글 스위치
- **레이블**: "데스크톱 모드"
- **동작**: 토글 변경 시 페이지 새로고침

#### 3.4.4 예상 구현 위치
- **BrowserViewModel.swift**: `isDesktopMode` 프로퍼티 및 User-Agent 제어 로직
- **WebContainerView.swift**: User-Agent 적용
- **MoreMenuView.swift**: 토글 UI 추가

---

### 3.5 히스토리 관리

#### 3.5.1 요구사항
- 사용자가 방문한 페이지 기록 저장 및 조회
- 날짜별 그룹화, 검색 기능 제공
- 히스토리 삭제 기능 (전체/선택/날짜별)

#### 3.5.2 데이터 모델
```swift
struct BrowsingHistory: Codable, Identifiable {
    let id: UUID
    let url: String
    let title: String
    let visitedAt: Date
}
```

#### 3.5.3 저장소
- **방법 1**: `@AppStorage` + JSON 인코딩 (간단하지만 용량 제한)
- **방법 2**: SwiftData 모델로 저장 (권장, 용어집과 동일한 스택 활용)

#### 3.5.4 UI 구성
- **진입점**: MoreMenuView에 "히스토리" 메뉴 추가
- **뷰**: `HistoryView.swift` (NavigationStack 또는 Sheet)
  - Section으로 날짜별 그룹화 (`DateFormatter`로 "오늘", "어제", "2025년 1월 20일" 등)
  - 각 항목 탭 → 해당 URL 로드
  - 검색 바 (`.searchable(text:)`)
  - Toolbar의 편집 버튼 → 삭제 모드

#### 3.5.5 히스토리 기록 시점
- `BrowserViewModel.swift`의 `load(urlString:)` 호출 시 또는 `onDidFinish` 콜백에서 기록
- 중복 방지: 같은 URL을 연속 방문 시 시간만 업데이트

#### 3.5.6 예상 구현 위치
- **Domain/Models/BrowsingHistory.swift**: 데이터 모델 (또는 SwiftData 모델)
- **Services/History/HistoryStore.swift**: 히스토리 저장/조회/삭제 로직
- **Presentation/Browser/View/HistoryView.swift**: 히스토리 UI
- **BrowserViewModel.swift**: 히스토리 기록 통합

---

### 3.6 새로고침 버튼

#### 3.6.1 요구사항
- 현재 URL 바에는 새로고침 버튼이 따로 없음 (`onRefresh` 콜백은 있지만 UI 버튼 없음)
- URL 입력 중이 아닐 때 새로고침 버튼 노출

#### 3.6.2 UI 구성
- **위치**: `URLBarView.swift`의 URL 입력 필드 우측 (현재 Go 버튼 위치와 공유)
- **아이콘**: `arrow.clockwise`
- **조건**:
  - 편집 중 (`isFocused = true`): Go 버튼 표시
  - 편집 중이 아닐 때: 새로고침 버튼 표시

#### 3.6.3 구현 방법
```swift
// URLBarView+Field.swift 내부
if isFocused.wrappedValue {
    // 기존 Go 버튼
} else {
    Button(action: { onRefresh(urlString) }) {
        Image(systemName: "arrow.clockwise")
            .font(.title3)
            .foregroundStyle(Color.accentColor)
    }
    .buttonStyle(.plain)
}
```

#### 3.6.4 예상 구현 위치
- **URLBarView+Field.swift**: 새로고침 버튼 조건부 렌더링

---

### 3.7 탭 관리 (선택적 확장 기능)

#### 3.7.1 요구사항
- 여러 웹페이지를 탭 형태로 관리
- Safari처럼 탭 간 전환, 새 탭 열기, 탭 닫기 지원

#### 3.7.2 구현 복잡도
- **High**: 브라우저 아키텍처 전반 변경 필요
  - 각 탭마다 별도의 `WKWebView` 인스턴스 필요
  - `BrowserViewModel` → `TabManager` + 여러 `TabViewModel`로 리팩토링
  - 메모리 관리 (탭 수 제한, 비활성 탭 중지)
- **우선순위**: P2 (장기 로드맵)

#### 3.7.3 권장사항
- 현재는 단일 탭 브라우저로 유지하고, 기본 편의 기능 먼저 구현
- 탭 관리는 사용자 피드백 및 요구사항 수집 후 별도 스펙으로 분리

---

## 4. 구현 우선순위

| 기능 | 우선순위 | 구현 복잡도 | 예상 공수 |
|------|----------|-------------|-----------|
| 검색어 구글 검색 리다이렉트 | P0 | Low | 0.5일 |
| 새로고침 버튼 | P0 | Low | 0.5일 |
| 뒤로/앞으로 가기 버튼 | P1 | Low | 1일 |
| 페이지 내 검색 | P1 | Low | 0.5일 |
| 데스크톱 모드 | P2 | Low | 1일 |
| 히스토리 관리 | P2 | Medium | 2-3일 |
| 탭 관리 | P3 | High | 5-7일 |

---

## 5. 기술 스택 및 호환성

- **iOS 버전**: iOS 16.0+ (WKWebView Find API 활용)
- **SwiftUI**: 현재 프로젝트 버전 유지
- **WKWebView**: 네비게이션, User-Agent, Find Interaction API 활용
- **저장소**:
  - 히스토리: SwiftData (기존 Glossary와 동일 스택)
  - 설정값: `@AppStorage` 또는 `UserSettings` 확장

---

## 6. 보안 및 성능 고려사항

### 6.1 검색 리다이렉트
- URL 인코딩 필수: `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`
- 잠재적 XSS 공격 방지: 사용자 입력을 직접 URL에 삽입하지 않고 인코딩

### 6.2 히스토리 저장
- 프라이버시: 사용자가 히스토리 삭제 기능에 쉽게 접근할 수 있도록 UI 제공
- 저장 용량: 오래된 기록 자동 삭제 정책 (예: 30일 이상 기록 삭제 옵션)

### 6.3 User-Agent 변경
- 데스크톱 모드 활성화 시 렌더링 성능 저하 가능 (복잡한 데스크톱 사이트)
- 사용자에게 성능 저하 가능성 안내

---

## 7. 문서 변경 계획 (AGENT_RULES.md 준수)

이 기능들이 구현되면 아래 문서를 업데이트해야 합니다:

1. **PROJECT_OVERVIEW.md**:
   - "주요 컴포넌트/모듈" 섹션에 히스토리 저장소 추가 (구현 시)
   - "아키텍처 개요" 섹션에 브라우저 편의 기능 설명 추가

2. **TODO.md**:
   - 각 기능별 구현 항목 추가/완료 상태 업데이트

---

## 8. 다음 단계

1. 사용자 승인 및 우선순위 확정
2. P0 기능부터 순차 구현:
   - 검색어 구글 검색 리다이렉트
   - 새로고침 버튼
3. P1 기능 구현 후 사용자 피드백 수집
4. P2/P3 기능은 별도 스펙 문서로 분리 검토

---

## 9. 참고 자료

- [WKWebView Documentation](https://developer.apple.com/documentation/webkit/wkwebview)
- [WKWebView Find Interaction](https://developer.apple.com/documentation/webkit/wkwebview/4002935-isfindinteractionenabled)
- [User-Agent 커스터마이징](https://developer.apple.com/documentation/webkit/wkwebview/1414950-customuseragent)
