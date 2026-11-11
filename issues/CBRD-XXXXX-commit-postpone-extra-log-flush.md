# [Log] postpone이 있는 트랜잭션은 커밋마다 로그를 두 번 동기 flush한다

**한 줄 요약**: OOS 작업(CBRD-27781)에서 한 행씩 커밋하는 UPDATE가 65% 느려진 원인을 추적한 결과, `LOG_COMMIT_WITH_POSTPONE`을 기록한 직후의 동기 로그 flush 때문에 postpone이 있는 트랜잭션이 커밋마다 디스크 동기화를 한 번 더 기다리는 것으로 확인되어, 이 flush가 필요한지 검토하고 불필요하면 없애는 이슈다.

## Issue Triage

**이슈 수행 목적**: postpone을 남긴 트랜잭션도 postpone이 없는 트랜잭션처럼 커밋 한 번에 로그 동기화를 한 번만 기다리게 해서, 작은 트랜잭션의 커밋 지연을 줄인다.

**이슈 수행 이유**: 트랜잭션이 postpone(커밋 뒤에 실행할 작업)을 남기면 커밋은 두 단계로 진행된다. 먼저 `LOG_COMMIT_WITH_POSTPONE`을 기록하고, postpone을 실행한 뒤 `LOG_COMMIT`을 기록한다. 지금은 두 기록 뒤에서 모두 로그 flush를 기다린다(`log_append_commit_postpone`의 `logpb_flush_pages`, develop `9f9f9d715` 기준 `src/transaction/log_manager.c:4482`). 같은 구조의 sysop postpone에서는 이 flush가 10.1에서 이미 제거되었다(CBRD-20097). 그런데 transaction 커밋 쪽에는 아직 남아 있다.

**영향**: postpone을 남기는 트랜잭션을 한 행씩 자주 커밋하는 사용자는 커밋마다 로그 동기화 한 번만큼 더 기다린다. OOS 컬럼 UPDATE에서는 3000번 커밋에 18.8초가 31.1초로 늘었다(+65%). 이는 CBRD-27781이 병합되면 모든 OOS UPDATE가 postpone을 남기게 되면서 드러난 것이다. develop에서 postpone을 남기는 작업(파일 삭제, heap 슬롯 재사용 표시, btree 등)이 실제 부하에서 얼마나 자주 생기는지는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 커밋 경로

postpone이 있는 트랜잭션의 커밋은 다음 순서로 진행된다(`log_tran_do_postpone`, `log_complete`).

1. `LOG_COMMIT_WITH_POSTPONE`을 기록하고 로그 flush를 기다린다(`log_append_commit_postpone`).
2. postpone을 실행한다(`log_do_postpone`). 각 실행은 redo 로그를 남긴다.
3. 복제 정보와 `LOG_COMMIT`을 기록하고 로그 flush를 기다린 뒤 클라이언트에 응답한다(`log_change_tran_as_completed`).

postpone이 없는 트랜잭션은 3단계의 flush만 기다린다. 1단계의 flush는 `git log -L` 기준 저장소 초기 이력부터 있었고, 추가된 이유를 남긴 기록은 찾지 못했다.

### 1단계 flush가 복구에 필요하지 않을 수 있다는 근거

아래는 소스를 읽고 내린 추론이며, ANALYSIS에서 확인할 대상이다.

- 로그는 LSA 순서대로 디스크에 쓰인다. 그래서 2단계 postpone 실행 기록이 디스크에 있으면, 그보다 앞선 `LOG_COMMIT_WITH_POSTPONE`도 디스크에 있다.
- 데이터 페이지는 WAL 규칙에 따라 자기 로그가 디스크에 쓰이기 전에는 디스크에 쓰이지 않는다. 그래서 `LOG_COMMIT_WITH_POSTPONE`이 디스크에 없으면 postpone이 바꾼 페이지도 디스크에 없다.
- `LOG_COMMIT_WITH_POSTPONE`이 디스크에 닿기 전에 서버가 죽으면 그 트랜잭션은 복구에서 롤백된다. 클라이언트는 3단계 flush 뒤에야 커밋 응답을 받으므로, 응답받은 커밋이 사라지지는 않는다.
- sysop의 `LOG_SYSOP_START_POSTPONE`은 flush 없이 기록하고 postpone을 실행한다(`log_append_sysop_start_postpone`, develop `9f9f9d715` 기준 `log_manager.c:4533`). 복구는 이 경우를 이미 처리한다.
- 2단계에서 로그를 다시 읽을 때는 `logpb_fetch_page`가 prior 목록을 로그 버퍼로 옮긴다(`log_page_buffer.c`). 그래서 flush가 없어도 읽을 수 있다.

### 측정

CBRD-27781 작업 중 같은 장비에서 세 빌드를 비교했다. 세 빌드 모두 release 빌드이고 `group_commit_interval_in_msecs`, `log_async_commit`은 기본값이다.

| 빌드 | 설명 |
|---|---|
| base | `feature/oos-merge` `95ff126a8` (CBRD-27781 PR의 merge base) |
| new | CBRD-27781 PR #8434 head `94ed2ea46`. OOS 컬럼 UPDATE가 postpone을 남긴다. |
| fix | new에서 `log_append_commit_postpone`의 `logpb_flush_pages` 한 줄만 뺀 빌드 |

**부하**: OOS로 저장될 만큼 큰 `BIT VARYING` 컬럼을 가진 3000행 테이블에서 한 `csql -C` 세션이 아래 문장을 3000번 실행한다. 새 값은 미리 만든 테이블 `s`에서 읽으므로, 값 계산은 측정 구간에 들어가지 않는다.

```sql
UPDATE t SET v = (SELECT s.v FROM s WHERE s.id = 1) WHERE id = 1; COMMIT;
-- id = 2 ... 3000 반복
```

**로그 동기화 횟수**: 측정 구간 동안 `strace -f -c -e trace=fdatasync -p <cub_server pid>`로 셌다.

| 빌드 | 실행 | `fdatasync` 호출 | 커밋당 |
|---|---|---|---|
| base | 2회 | 3011, 3011 | 1 |
| new | 2회 | 6006, 6006 | 2 |
| fix | 1회 | 3006 | 1 |

**지연**: 다른 사용자의 부하가 있는 80코어 공용 서버에서 쟀다(load average 14~150). 실행 순서를 매번 바꾸어 같은 잡음을 나누어 받게 했다.

| 측정 | base | new | fix |
|---|---|---|---|
| 1차: base·new 12쌍, 중앙값 (범위) | 18.83초 (16.31~20.37) | 31.09초 (28.40~33.69) | - |
| 2차: 세 빌드 6회씩, 중앙값 (범위) | 11.06초 (8.47~17.15) | 24.26초 (12.61~43.48) | 11.48초 (8.57~15.24) |

- 1차 측정에서 new는 12쌍 모두 base보다 느렸다.
- 2차 측정에서 fix는 6회 모두 new보다 빨랐다. fix와 base의 짝별 차이 중앙값은 −0.30초로, 부하 잡음보다 작다.
- 1차와 2차의 절대값 차이는 측정 시점의 서버 부하 차이로 보인다. 같은 회차 안의 비교만 의미가 있다.
- 3000행을 한 트랜잭션에서 UPDATE하는 경우에는 base와 new의 차이가 ±2% 이내였다. 커밋이 한 번이라 추가 flush도 한 번뿐이기 때문이다.

### 관련 이슈

- CBRD-20097: sysop postpone 커밋의 같은 flush를 10.1에서 제거했다. 이번 이슈와 같은 판단의 선례다.
- CBRD-26885: COMMIT 응답 시간을 줄이려고 postpone 실행을 커밋 경로에서 떼어내는 설계를 검토한다. 이 이슈는 1단계 flush를 "내구성 경계"로 본다. 그래서 두 이슈의 방향을 함께 정해야 한다.
- CBRD-20019: `LOG_COMMIT_WITH_POSTPONE`만 디스크에 있는 상태에서 서버가 죽으면, 복구는 그 트랜잭션을 커밋하지만 복제 로그가 없어 슬레이브에 반영되지 않는다. 1단계 flush가 없으면 이 상태가 생기는 경우가 줄어들 것으로 추론한다.
- CBRD-28034: COMMIT_WITH_POSTPONE 처리 중 HA 복제 적용 순서가 뒤집히는 문제다. 1단계 flush를 없애면 해당 구간이 짧아지지만, 이 문제의 해결책은 아니다.
- CBRD-27781: 이번 측정의 계기다. ADR-0008 결정 7은 OOS UPDATE의 지연이 나빠지지 않을 것을 병합 조건으로 두고 있어, 이 이슈의 결과가 CBRD-27781의 병합 여부에 영향을 준다.

### ANALYSIS에서 확인할 사항

- 1단계 flush가 막고 있는 장애 시나리오가 있는지 확인한다. 특히 HA 복제, `restoredb -d`의 시점 복원, 체크포인트, vacuum과의 상호작용을 본다.
- CBRD-26885의 설계 방향과 충돌하지 않는 해결 방향을 고른다.
- develop에서 postpone을 남기는 작업이 실제 부하에서 얼마나 자주 생기는지, 그리고 효과가 얼마나 되는지 측정한다.

## Acceptance Criteria

- postpone을 남기는 트랜잭션의 커밋이 로그 동기화를 한 번만 기다린다. 또는 두 번째 동기화가 필요한 이유가 근거와 함께 기록된다.
- postpone 실행 중 서버가 죽어도 재시작 복구가 커밋된 트랜잭션의 postpone을 끝까지 실행하고, 커밋 응답을 받지 못한 트랜잭션은 롤백한다.
- 위 측정 부하에서 커밋당 지연이 postpone이 없는 경우와 같은 수준이 된다.
