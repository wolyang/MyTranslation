# IMPROVEMENTS.md — 개선 아이디어 목록

이 문서는 버그가 아닌 **개선 아이디어**와 **기능 제안**을 기록합니다.
향후 구현 우선순위를 정하거나 개발 방향을 잡을 때 참고할 수 있습니다.

---

## 💡 IDEA-001: '이 용어에 변형 추가' 버튼 즉시 저장 기능

### 제안일
2025-11-23

### 현재 동작
"용어집에 추가" 바텀 시트에서 **'이 용어에 변형 추가'** 버튼을 누르면:
1. 용어 편집 뷰(View)로 이동
2. 사용자가 수동으로 저장 버튼 클릭
3. 시트 닫힘

### 제안 개선
버튼 클릭 시 **자동으로 variants에 추가 및 저장** 후 시트 닫기

**UX 흐름:**
1. 사용자가 '이 용어에 변형 추가' 버튼 클릭
2. 즉시 variants에 추가 & 저장 (백그라운드 처리)
3. 성공 토스트 메시지 표시 ("변형이 추가되었습니다" 등)
4. 시트 자동으로 닫힘

**장점:**
- ✅ 사용자 액션 감소 (2단계 제거: 편집 뷰 이동 + 저장 버튼)
- ✅ 빠르고 직관적인 UX
- ✅ 일반적인 사용 시나리오에 최적화 (단순히 변형 추가만 하는 경우)

**고려사항:**
- 사용자가 추가 전 검토/수정을 원하는 경우 대응 방법
  - **대안 1**: 별도의 "편집 후 추가" 버튼 제공
  - **대안 2**: 토스트에 "실행 취소(Undo)" 옵션 추가
  - **대안 3**: 설정에서 "자동 저장" vs "편집 후 저장" 선택 가능

### 구현 예시

```swift
Button("이 용어에 변형 추가") {
    // 현재: 편집 뷰로 이동
    // navigationPath.append(.editTerm(term))

    // 개선: 즉시 저장
    addVariantToTerm(term: targetTerm, variant: newVariant)
    showToast(message: "변형 '\(newVariant)'이(가) 추가되었습니다")
    dismissSheet()
}

func addVariantToTerm(term: SDTerm, variant: String) {
    term.variants.append(variant)
    try? modelContext.save()
}
```

### 우선순위
**낮음-중간** - UX 개선이지만 현재 동작도 정상 작동. 사용자 편의성 향상을 위한 Nice-to-have

---

## 💡 IDEA-002: 브라우저 도메인 판별 로직 강화

### 제안일
2025-11-25

### 현재 동작
주소창에 입력된 문자열이 URL인지 검색어인지 판별하는 `isLikelyDomain()` 메서드:
- 공백이 없고 점(`.`)이나 포트(`:`)가 포함되면 도메인으로 간주
- `https://` 접두사를 붙여 URL로 변환

**문제점:**
- `localhost` (점이 없는 유효한 도메인)를 검색어로 처리
- `example..com` (연속 점) 같은 잘못된 입력을 도메인으로 인식 가능

### 제안 개선
도메인 판별 정확도 향상을 위한 로직 추가:

```swift
func isLikelyDomain(_ text: String) -> Bool {
    guard text.contains(" ") == false else { return false }

    // localhost는 도메인으로 처리
    if text.lowercased() == "localhost" { return true }

    let hasDot = text.contains(".")
    let hasPort = text.contains(":")

    // 점이나 포트가 있어야 도메인으로 간주
    guard hasDot || hasPort else { return false }

    // 기본 유효성 검사
    if let url = URL(string: "https://" + text),
       let host = url.host,
       host.isEmpty == false,
       host.contains("..") == false { // 연속 점 방지
        return true
    }
    return false
}
```

**장점:**
- ✅ localhost 개발 환경 지원
- ✅ 잘못된 도메인 입력 방지
- ✅ 더 정확한 URL vs 검색어 구분

**고려사항:**
- 192.168.1.1 같은 IP 주소는 현재 로직으로도 정상 처리 (점 포함)
- 특수한 TLD (.local, .test 등)도 점이 있으면 도메인으로 인식

### 우선순위
**낮음** - 현재 로직도 대부분의 케이스 처리 가능. 엣지 케이스 개선

---

## 💡 IDEA-003: iOS 16 미만에서 페이지 내 검색 메뉴 숨김

### 제안일
2025-11-25

### 현재 동작
- `WebContainerView`에서 iOS 16+ 체크 후 `isFindInteractionEnabled = true` 설정
- `MoreMenuView`에는 OS 버전 체크 없이 "페이지 내 검색" 메뉴 항목 표시
- iOS 16 미만 기기에서 메뉴를 탭해도 아무 동작 없음

### 제안 개선
iOS 버전별 조건부 렌더링:

```swift
// MoreMenuView.swift
Section("페이지") {
    if #available(iOS 16.0, *) {
        Button {
            onFindInPage()
        } label: {
            Label("페이지 내 검색", systemImage: "magnifyingglass")
        }
    }

    Toggle(isOn: Binding(get: { isDesktopMode }, set: { onToggleDesktopMode($0) })) {
        Label("데스크톱 모드", systemImage: "desktopcomputer")
    }
}
```

**장점:**
- ✅ iOS 16 미만에서 동작하지 않는 메뉴 숨김
- ✅ 사용자 혼란 방지
- ✅ 일관성 있는 UX

**고려사항:**
- iOS 16+ 타겟으로 전환하면 불필요한 체크
- 현재 최소 지원 버전 확인 필요

### 우선순위
**낮음-중간** - iOS 16 채택률이 높으면 낮음, 구형 기기 사용자가 많으면 중간

---

## 💡 IDEA-004: 히스토리 자동 삭제 정책 (30일)

### 제안일
2025-11-25

### 현재 동작
`HistoryStore`는 최대 500개 항목만 저장:
- 500개 초과 시 오래된 항목부터 자동 삭제
- 날짜 기반 자동 삭제 정책 없음

### 제안 개선
사용자 설정 기반 자동 삭제 정책 추가:

**1. UserSettings에 설정 추가:**
```swift
@AppStorage("historyMaxEntries") public var historyMaxEntries: Int = 500
@AppStorage("historyRetentionDays") public var historyRetentionDays: Int = 30
```

**2. HistoryStore 개선:**
```swift
func trim(_ items: inout [BrowsingHistory]) {
    let maxEntries = settings.historyMaxEntries
    let retentionDate = Calendar.current.date(
        byAdding: .day,
        value: -settings.historyRetentionDays,
        to: Date()
    )!

    // 날짜 기준 삭제
    items.removeAll { $0.visitedAt < retentionDate }

    // 개수 기준 삭제
    if items.count > maxEntries {
        items = Array(items.prefix(maxEntries))
    }
}
```

**3. Settings UI 추가:**
- 히스토리 보관 기간 선택 (7일/30일/90일/무제한)
- 최대 항목 수 선택 (100/500/1000/무제한)

**장점:**
- ✅ 프라이버시 보호 강화 (오래된 기록 자동 삭제)
- ✅ 저장 공간 관리 (UserDefaults 용량 제한)
- ✅ 사용자 선택권 제공

**고려사항:**
- 무제한 선택 시 UserDefaults 용량 한계 (일반적으로 ~1MB 권장)
- 대량 히스토리는 SwiftData로 마이그레이션 고려

### 우선순위
**중간** - 프라이버시와 저장 공간 관리 측면에서 유용. SPEC 문서 6.2에 명시됨

---

## 💡 IDEA-005: 데스크톱 모드 전환 시 페이지 상태 보존

### 제안일
2025-11-25

### 현재 동작
데스크톱 모드 토글 시 `refreshAndReload(urlString:)` 호출:
- 번역 캐시 전체 삭제
- 번역 상태 초기화
- 폼 입력 데이터, 스크롤 위치 등 모두 손실

### 제안 개선
User-Agent만 변경하고 일반 reload 수행:

```swift
func reloadForUserAgentChange(using webView: WKWebView) {
    guard webView.url != nil else { return }

    // 옵션 1: 일반 reload (페이지 상태 최대한 보존)
    webView.reload()

    // 옵션 2: 번역 상태만 초기화
    resetTranslationState()
    webView.reload()
}
```

**장점:**
- ✅ 폼 입력 데이터 보존 (일부 사이트)
- ✅ 불필요한 캐시 삭제 방지
- ✅ 더 나은 UX

**고려사항:**
- 일부 사이트는 User-Agent 변경 시 완전 새로고침 필요
- 번역 상태 초기화 필요 여부 (현재 번역본은 모바일 버전 기준)

**대안:**
- 사용자에게 선택권 제공: "데스크톱 모드로 전환 시 번역을 초기화할까요?"
- 또는 토글 전 경고 알림 표시

### 우선순위
**낮음-중간** - UX 개선이지만 현재 동작도 명확함. 사용 빈도에 따라 우선순위 조정

---

## 💡 템플릿 섹션

### 제안일
YYYY-MM-DD

### 현재 동작
(현재 어떻게 작동하는지 설명)

### 제안 개선
(어떻게 개선할지 설명)

**장점:**
- ✅
- ✅

**고려사항:**
-

### 우선순위
**낮음/중간/높음** - (우선순위 설명)

---

