### 폴더 구조
- Masking → TextEntityProcessing로 폴더명 변경
```
Core/
  TextEntityProcessing/
    Models/
      NameGlossary.swift
      SegmentGlossaryModels/
        AppearedTerm.swift
        AppearedComponent.swift
      MaskedPack.swift
      LockInfo.swift
    Engines/
      SegmentTermMatcher.swift      // allOccurrences, deactivatedContexts 등
      SegmentPiecesBuilder.swift    // SegmentPieces 조립
      SegmentEntriesBuilder.swift   // buildComposerEntries, buildEntriesFromPairs/Lefts 등
      MaskingEngine.swift
      NameNormalizationEngine.swift
    Rules/
      KoreanParticleRules.swift
```

### 파일 분리, 병합
- NameGlossary 분리
    - Models/NameGlossary.swift
- AppearedTerm / AppearedComponent 분리
    - Models/SegmentGlossaryModels/AppearedTerm.swift
    - Models/SegmentGlossaryModels/AppearedComponent.swift
- TermActivationFilter.swift 제거
    - shouldDeactivate 함수 SegmentTermMatcher.swift로 이동
    - class TermActivationFilter 제거
    - 전체 코드에서 TermActivationFilter 의존성 제거
- 세그먼트 -> 용어 조각 생성 단계
    - Engines/SegmentTermMatcher.swift
        세그먼트에서 뭐가 어디에 등장했는지 계산하는 레이어
        - 텍스트 검색/비활성 컨텍스트 관련 유틸:
            - allOccurrences(of:in:)
            - deactivatedContexts(of:)
            - TermActivationFilter.shouldDeactivate(...)
        - AppearedTerm, AppearedComponent를 만들어내는 로직이 있다면 여기
        - 패턴/role 매칭의 기초 계산 (left/right 판단 등)도 이쪽에 넣기 좋음
        한마디로 “Segment + SDTerm + 패턴을 받아서 AppearedTerm/Component 목록을 만드는 부분”.
    - Engines/SegmentPiecesBuilder.swift
        SegmentPieces 그 자체를 만드는 부분
        - 실제로 SegmentPieces를 구성하는 함수들:
            - buildSegmentPieces(...)
            - 텍스트를 term piece / plain text piece로 쪼개는 내부 헬퍼들
        - SegmentTermMatcher에서 나온 AppearedTerm/Component를 받아
            - 앞/뒤 텍스트 쪼개기
            - 겹치는 범위 조정
            - SegmentPieces.Piece 배열을 최종 확정하는 부분
        즉, “세그먼트를 어떻게 term/text 조각 배열로 바꿀까”에만 집중.
    - Engines/SegmentEntriesBuilder.swift
        패턴과 roles를 기반으로 GlossaryEntry 조합을 만드는 부분
        - 아래 같은 함수들 여기에:
            - buildComposerEntries(...)
            - matchedPairs(for:...)
            - matchedLeftComponents(...)
            - buildEntriesFromPairs(...)
            - buildEntriesFromLefts(...)
            - filterBySourceOcc(...)
        - 패턴의 leftRoles/rightRoles에 따라 term를 양쪽으로 매칭하는 로직,
        - fallback용 entry 생성 같은 것들
        “SegmentPieces + AppearedTerm/Component → 실제로 사용할 GlossaryEntry[] 확정” 단계.
- 마스킹 & 언마스킹 엔진
    - 이름: MaskingEngine
    - 역할
        - SegmentPieces 기반으로 토큰을 만들고 마스킹
        - locks, tokenEntries, maskedRanges 관리
        - 언마스킹 시 토큰 순서 기반 복원 + 조사 보정
        - 손상된 토큰(E#깨짐 등) 복원
        - 이 모듈은 기본적으로 “토큰 문자열 ↔ LockInfo/GlossaryEntry” 사이의 변환을 책임지고, 조사 보정 / 이름 정규화는 외부 서비스(ParticleRules, NameNormalizer)에 의존
    - 옮길 것
        - 토큰 정의/생성 관련
            - nextIndex, tokenSpacingBehavior
            - tokenRegexPattern, tokenRegex
            - makeToken(prefix:index:)
            - extractTokenIDs(...)
            - sortedTokensByIndex(...)
        - 마스킹
            - maskFromPieces(...)
            - surroundTokenWithNBSP(...)
            - insertSpacesAroundTokensOnlyIfSegmentIsIsolated_PostPass(...)
        - 언마스킹
            - unlockTermsSafely(...)
            - unmaskWithOrder(...) (단, 조사 보정/정규화 유틸은 별 모듈 참조)
            - normalizeTokensAndParticles(...)
            - normalizeDamagedETokens(...)
            - ReplacementDelta
- 정규화 / 변형 처리 엔진
    - 이름: NormalizationEngine
    - 역할
        - 같은 용어 원문에 대해 target + variants 집합을 만들고
        - 세그먼트 내 등장 순서/빈도에 기반해서
            - 어떤 변형이 어떤 canonical로 매핑될지 결정
            - 조사 보정까지 포함해서 정규화 텍스트를 생성
        - 패턴 기반 조합어(fallback)까지 고려
        - 이 모듈은 SegmentPieces + NameGlossary[] + (필요시 GlossaryEntry[])를 받아서, **“이 텍스트에서 인물명/용어를 어떻게 하나의 canonical 표기로 통합할 것인가”**를 전담
    - 옮길 것
        - 이름 정보 모델링
            struct NameGlossary
            makeNameGlossaries(seg:entries:)
            makeNameGlossariesFromPieces(pieces:allEntries:)
        - 이름 정규화 파이프라인
            normalizeWithOrder(...)
            normalizeVariantsAndParticles(...)
        - 변형 검색 유틸
            makeCandidates(target:variants:)
            findNextCandidate(...)
            replaceWithParticleFix(...) (실제 구현은 나중에 ParticleRules 쪽으로 옮겨도 됨)
            canonicalFor(...)
- 한국어 조사/공백 규칙
    - 이름: KoreanParticleRules
    - 안에 둘 것
        - 종성 유틸
            hangulFinalJongInfo(_:)
        - 조사 규칙들
            JosaPair, josaPairs
            caseSingleParticles, auxiliaryParticles
            pairFormsByString
            particleTokenAlternation, particleTokenRegex
            particleWhitespaceRegex
            cjkOrWord
            chooseJosa(...)
        - 공백/문장부호 유틸
            wsClass
            collapseSpaces_PunctOrEdge_whenIsolatedSegment(...)
            String.isPunctOrSpaceOnly, isPunctOrSpaceOnly_loose
        - 최종 엔트리 포인트
            fixParticles(...)
    - 참고: TokenMaskingEngine, NameNormalizationEngine 둘 다 여기만 바라보게 하면, 조사 규칙 수정이 한 군데로 모임.