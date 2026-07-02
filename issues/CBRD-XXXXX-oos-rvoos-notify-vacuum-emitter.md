# [OOS] RVOOS_NOTIFY_VACUUM: emitter 추가 또는 enum/dispatch 정리 결정

## Issue Triage

**이슈 수행 목적** (필수): emitter (이 로그 레코드를 실제로 기록하는 코드) 가 없는 `RVOOS_NOTIFY_VACUUM` 을 "용도와 함께 emitter 추가" 또는 "정리(매크로/주석 cleanup)" 중 하나로 결론짓는다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: `RVOOS_NOTIFY_VACUUM` (rcvindex - recovery index, WAL 로그 레코드의 복구 핸들러 식별자 - 값 134) 가 enum (`src/transaction/recovery.h:197`), no-op dispatch stub (`src/transaction/recovery.c:869`), `LOG_IS_MVCC_OPERATION` 매크로 절 (`src/transaction/mvcc.h`) 에 등록돼 있으나, 이를 기록하는 emitter (`log_append...RVOOS_NOTIFY_VACUUM`) 가 코드베이스에 0개다. 현재는 4곳(`recovery.h:192`, `recovery.h:278`, `recovery.c:869`, `mvcc.h:261`)에 TODO 주석만 달려 있다.
- **영향**: 기술 부채. 사용되지 않는 reserved 슬롯이 남아 의도가 모호하다. on-disk rcvindex 값 134 는 pinned (기존 디스크 로그가 이 값을 들고 있을 수 있어 재번호 불가) 이므로, 제거하더라도 enum 값 자체는 함부로 못 옮긴다. PR #6986 에서 hornetmj 가 지적(코멘트 3121522645).

**이슈 수행 방안**:

- 둘 중 하나로 결정한다:
  - (a) 의도된 용도가 있으면(예: OOS 페이지 측 bestspace 캐시 invalidation 신호) emitter + 복구 핸들러를 추가한다.
  - (b) 미사용으로 확정하면, enum 슬롯은 pinned 로 두되 매크로/주석을 정리하고 dispatch 는 no-op stub 으로 유지한다.
- 결정 시 4곳 TODO 주석을 동기화해 정리한다.
- `TBD - 합의 미확인`: (a)/(b) 중 어느 쪽인지는 본 이슈에서 결정한다. PR #6986 에서는 보류했다.

---

## AI-Generated Context

> 아래 내용은 AI 가 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하다.

### Summary

- **문제 / 목적**: emitter 없는 reserved rcvindex 의 거취 결정.
- **원인 / 배경**: M1 범위에서 enum/dispatch 만 등록되고 emitter 가 도입되지 않음.
- **제안 / 변경**: emitter 추가 또는 매크로/주석 정리 중 택일.
- **영향 범위**: `recovery.h`, `recovery.c`, `mvcc.h`. on-disk 값 변경 없음(제거해도 enum 값 보존).

---

## Description

`RVHF_UPDATE_NOTIFY_VACUUM` / `RVES_NOTIFY_VACUUM` 같은 notify-vacuum 계열과 달리 `RVOOS_NOTIFY_VACUUM` 만 기록 지점이 없다. 향후 OOS 페이지 vacuum 신호 용도로 예약된 것으로 보이나 현재 구현이 없다. 새로 추가된 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` (rcvindex 136, PR #6986) 가 MVCC relocation 누수를 이미 처리하므로, `RVOOS_NOTIFY_VACUUM` 의 원래 용도가 여전히 필요한지 재평가가 필요하다.

## Specification Changes

N/A (사용자 가시 동작 변화 없음. on-disk 로그 포맷은 결정 (a) 채택 시에만 영향).

## Implementation

결정 (a)/(b) 에 따라 `recovery.h` enum/매크로, `recovery.c` RV_fun 핸들러, `mvcc.h` 분류, 그리고 emitter 지점을 정리한다. 세부는 결정 후 확정.

## Acceptance Criteria

- [ ] (a) 또는 (b) 채택 결정 기록
- [ ] 4곳 TODO 주석 정리 또는 emitter 추가 완료
- [ ] 회귀 테스트 통과

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] 문서/주석 반영
