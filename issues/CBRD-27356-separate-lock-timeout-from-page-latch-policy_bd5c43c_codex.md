# [PGBUF] transaction lock timeout과 page latch 정책 분리

## Issue Triage

**이슈 수행 목적**: 사용자 트랜잭션의 lock timeout과 page latch(메모리 page의 동시 접근을 보호하는 내부 잠금) 정책을 분리하여, 호출자가 지정한 latch 획득 방식이 트랜잭션의 lock 대기 설정에 따라 바뀌지 않도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | transaction의 zero-wait 상태가 호출자가 명시한 page-latch 획득 조건보다 우선할 수 있다. 실제 대기에는 별도 기본값 300,000ms를 사용하지만 대기 진입과 만료 후 처리는 transaction lock 정책과 분리되어 있지 않다. |
| **TO-BE (목표 상태 / 기대 동작)** | transaction lock timeout은 lock manager가 관리하고, page latch는 호출자가 명시한 blocking, nonblocking 또는 순서 조정 재시도 정책에 따라 동작한다. 내부 장기 대기 감시는 사용자 lock timeout과 독립적으로 관리한다. |
| **영향** | 설계 의도 훼손 — 상위 transaction 정책이 page-buffer 내부 동시성 제어의 의미를 바꾸므로, 같은 문제를 막기 위한 호출부별 예외가 늘어나고 내부 deadlock 회피 계약도 불명확해진다. |

**이슈 수행 방안**: CBRD-27198/PR #7630이 다루는 국소 증상과 별도로 공통 근본 문제를 이 이슈에서 해결한다. 호출자가 전달한 `PGBUF_LATCH_CONDITION`을 page-buffer 대기 진입의 기준으로 만들고, transaction의 `LOG_TDES::wait_msecs`를 암묵적으로 참조하지 않는다. 현재 300초 동작은 경고·치명적 latch 정지·buffer frame 확보 정지·기존 positive-policy cutoff의 네 역할로 분리한다. 분리 직후 치명적 latch 정지, buffer frame 확보 정지, positive-policy 호환 cutoff는 각각 300초를 유지하고 경고값은 계측으로 정한다. latch-order 검증과 계측 후 마지막 호환 cutoff를 제거하며, 1초는 일반 latch 실패 timeout으로 사용하지 않는다. 세부 API 이름과 호환 기간은 `TBD - ANALYSIS 단계에서 결정`한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 주요 후보는 `src/storage/page_buffer.c`, `src/storage/page_buffer.h`, `src/transaction/log_impl.h`, `src/transaction/lock_manager.c`, `src/storage/disk_manager.c`, `src/storage/bestspace.cpp`, `src/storage/btree.c`, `src/base/system_parameter.c`다. object lock의 공개 `lock_timeout` 동작과 디스크 형식은 유지 대상이며, page-buffer 내부 API와 오류 분류, 진단 통계는 변경될 수 있다.
- **기준 revision**: 관련 PR #7630의 HEAD `bd5c43cfc1a0fadc55bea0d3b9eea0a69c83ea65`를 기준으로 한다. 직접 소스 추적은 로컬 `d9ceb5317c4d5bf15d2bcd2e89c08c2db9de3530`에서 수행했으며, 이후 PR 변경은 주석 수정과 literal `0`을 `LK_ZERO_WAIT`로 바꾼 것뿐이라 분석 대상 동작은 같다.

---

## Description

`lock`은 트랜잭션 사이의 논리 객체 접근을 조정하며 충돌 시 statement 또는 transaction 수준의 오류로 복구할 수 있다. 반면 page latch는 buffer pool에 고정된 page 내용의 read/write 순서를 짧게 조정한다. BCB(Buffer Control Block — 메모리에 올라온 page의 fix 수와 latch 상태를 관리하는 제어 블록)는 이 상태를 담지만, BCB 자체의 제어 정보와 대기열은 별도의 mutex·atomic 연산으로 보호한다. latch 보유 중에는 부분 갱신이나 다른 latch 보유가 겹칠 수 있으므로, 사용자 lock 대기 상태로 latch의 진입과 실패 정책까지 결정하면 내부 불변식이 상위 설정에 따라 달라진다.

CUBRID의 공개 `lock_timeout`은 transaction lock 대기 시간을 설정한다. `LOG_TDES::wait_msecs`도 소스에서 "locks"를 위한 값으로 정의되어 있다. 그러나 page-buffer 경로는 이 값을 latch 대기 진입과 만료 결과에 함께 사용한다.

```
[대기 진입 결정]
lock_timeout -> LOG_TDES::wait_msecs -> pgbuf_find_current_wait_msecs()
  -> pgbuf_fix_internal()
       PGBUF_UNCONDITIONAL_LATCH
         -> PGBUF_CONDITIONAL_LATCH  ★ zero/force-zero이면 암묵적 변경
              -> busy이면 즉시 거절하며 queue/timed sleep에 들어가지 않음

[queue에 들어간 별도 대기 경로]
pgbuf_timed_sleep()
  -> zero/force-zero -> 0ms (이 경로에 도달한 경우)
  -> 그 외          -> page_latch_timeout_in_msecs(기본 300,000ms)
  -> 만료 후         -> transaction 상태별 오류·중단 처리
```

따라서 positive `lock_timeout` 값이 latch 대기 시간을 직접 정하는 것은 아니다. latch 대기 시간은 숨은 `page_latch_timeout_in_msecs`를 사용한다. 결합 지점은 숫자가 아니라 다음 두 정책이다.

1. `LK_ZERO_WAIT`와 `LK_FORCE_ZERO_WAIT`가 unconditional latch 요청을 conditional로 바꾼다.
2. 같은 300초가 지나도 inactive transaction은 대기를 다시 시작하고, active positive-policy transaction은 복구 가능한 `ER_LK_PAGE_TIMEOUT`을 받는다. active infinite-policy 경로는 `ER_PAGE_LATCH_TIMEDOUT`을 설정하고 debug assert를 거쳐 unilateral abort로 분류된다. 즉 현재 코드는 하나의 명확한 치명적 정지 감시가 아니라 서로 다른 제어 흐름을 한 값에 묶고 있다.

PR #7630은 `disk_get_volheader_internal()`과 `disk_stab_cursor_fix()`에서 thread-local override를 사용해 zero/force-zero 상태를 infinite wait처럼 보이게 한다. 이는 CBRD-27198에서 확인된 temp volume header 및 sector table 경합을 두 호출 경로에서 우회하지만, 다른 `pgbuf_fix()` 호출부에는 같은 결합이 남는다. 또한 `LK_ZERO_WAIT`는 사용자가 설정할 수 있는 no-wait 정책인 반면 `LK_FORCE_ZERO_WAIT`는 best-space와 B-tree 등이 latch 순환을 피하려고 임시로 설치하는 내부 정책이다. 현재 PR처럼 둘을 모두 무시할 때의 안전성, volume header를 잡은 채 sector table을 기다리면서 생기는 연쇄 대기 가능성, 필요한 regression test는 CBRD-27198 범위에서 별도로 확인해야 한다.

### 비교 DBMS의 정책 경계

| DBMS | 사용자 lock timeout | 내부 latch 대기 | 장기 정지 감시 |
|------|----------------------|-----------------|----------------|
| PostgreSQL | `lock_timeout`은 heavyweight object lock 획득에 적용 | `LWLock`(Lightweight Lock)과 buffer content lock은 이 값을 참조하지 않으며 conditional API와 ordering/retry를 사용 | stuck spinlock의 약 1분 PANIC은 watchdog(정상 진행이 멈췄다고 판단하는 내부 감시 장치)이며 transaction timeout이 아님 |
| MySQL/InnoDB | `innodb_lock_wait_timeout`은 record/table lock, `lock_wait_timeout`은 MDL(Metadata Lock)에 각각 적용 | page rw-lock과 mutex는 transaction lock timeout을 참조하지 않음 | semaphore wait 경고와 치명적 중단 기준은 내부 stall 진단이며 복구 가능한 lock timeout이 아님 |
| CUBRID | `lock_timeout`이 `LOG_TDES::wait_msecs`에 저장됨 | 대기 시간은 별도 300초지만 admission과 만료 처리가 `wait_msecs`를 참조 | 같은 300초 설정이 latch와 BCB victim progress 감시에 함께 사용됨 |

PostgreSQL의 `deadlock_timeout` 기본 1초와 InnoDB timeout daemon의 약 1초 주기는 deadlock 검사 시점 또는 polling 해상도다. 둘 다 page latch를 1초 뒤 실패시키는 정책이 아니다. CUBRID의 1초 `deadlock_detection_interval_in_secs` 역시 같은 범주이므로 latch acquisition deadline의 선례로 사용할 수 없다.

## Specification Changes

| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| `lock_timeout` | object lock 대기뿐 아니라 page latch 대기 진입과 만료 결과에도 간접 영향 | object lock 대기에만 적용 |
| page latch 대기 진입 | 명시한 `PGBUF_LATCH_CONDITION`이 transaction wait 상태에 따라 바뀔 수 있음 | caller가 전달한 latch 정책을 그대로 적용 |
| nonblocking 획득 | `LK_FORCE_ZERO_WAIT`를 transaction에 임시 설정하여 latch 동작을 유도하는 호출부가 존재 | page-buffer의 명시적인 try/ordered-retry 인터페이스 사용 |
| 내부 장기 대기 | 하나의 300초 설정이 latch 만료와 BCB victim progress(buffer frame 재사용 후보 확보 진행)를 함께 제어 | 경고, 치명적 latch 정지, BCB progress 정지, positive-policy 호환 cutoff를 서로 다른 역할로 관리 |
| 1초 정책 | page latch와 무관한 deadlock detection 기본값 | latch 실패 timeout으로 도입하지 않음 |

디스크 형식과 SQL 문법 변경은 없다. 공개 parameter 추가 여부, 기존 positive `lock_timeout`에서 발생하던 recoverable page-latch cutoff의 제거 시점, 기존 오류 코드 호환성은 `TBD - ANALYSIS 단계에서 결정`한다.

## Implementation

### 목표 interface 경계

page buffer가 latch 획득과 대기·오류 불변식을 함께 소유하도록 `pgbuf_fix`/`pgbuf_ordered_fix` 경계를 정리한다. 아래 이름은 의미를 설명하기 위한 예시이며 확정 API가 아니다.

| 동작 | 의미 | 실패 처리 |
|------|------|-----------|
| wait | caller가 latch order를 보장했으므로 획득할 때까지 대기 | interrupt 가능한 안전 지점과 fatal watchdog을 별도 정의 |
| try | queue에 들어가지 않고 즉시 시도 | timeout 오류를 만들지 않고 would-block 결과 반환 |
| ordered retry | 순서 위반 가능성이 있는 latch를 release/reorder/refix | page buffer가 정해진 순서로 재시도 |

`LOG_TDES::wait_msecs`는 lock manager 내부 정책으로 제한하고, page buffer는 이를 조회해 latch condition을 바꾸지 않는다. 사용자 작업 전체에 deadline이 필요하다면 상위 operation이 명시적인 deadline을 전달해야 하며 transaction 구현 상태를 page buffer가 암묵적으로 읽지 않는다.

### 단계별 전환

1. `pgbuf_fix_internal()`, `pgbuf_timed_sleep()`, `pgbuf_ordered_fix()`가 `wait_msecs`를 참조하는 지점과 `xlogtb_reset_wait_msecs(LK_FORCE_ZERO_WAIT)` 호출부를 전수 조사한다.
2. `PGBUF_LATCH_CONDITION`을 대기 진입의 단일 기준으로 만들고, blocking과 nonblocking 결과를 명확히 구분한다.
3. best-space, B-tree/heap 및 disk metadata 호출부를 wait, try, ordered retry 중 하나로 분류해 이전한다. volume header와 sector table을 함께 잡는 경로는 latch order와 연쇄 대기(convoy)를 별도 검증한다.
4. `page_latch_timeout_in_msecs`가 담당하던 역할을 warning/telemetry, fatal dead-latch watchdog, BCB victim progress watchdog, positive-policy recoverable compatibility cutoff로 나눈다. 기존 동작을 보존하기 위해 fatal watchdog, BCB progress watchdog, positive-policy compatibility cutoff는 처음에 각각 300초를 유지한다. warning threshold는 제어 흐름을 바꾸지 않으며 계측값으로 별도 결정한다.
5. 운영과 stress workload에서 대기 분포를 수집하고 latch-order 검증을 마친 뒤 positive-policy 호환 cutoff를 이 이슈에서 제거한다. fatal threshold와 BCB progress threshold의 후속 조정은 각각의 장애 감지·재시작 정책과 buffer 확보 분포를 근거로 결정하며, 300초를 고유하게 옳은 값으로 간주하지 않는다.

### 검증 범위

| 검증 | 확인할 결과 |
|------|-------------|
| 정책 조합 | `{LK_ZERO_WAIT, LK_FORCE_ZERO_WAIT, positive, infinite}`와 `{conditional, unconditional}` 조합별 queue 여부, 반환값, error stack이 명시한 latch 정책과 일치 |
| disk metadata 경합 | volume header 또는 sector table을 의도적으로 경합시켜 CBRD-27198 증상 없이 진행하고 partial reservation을 정확히 정리 |
| force-zero 회귀 | best-space와 B-tree/heap의 내부 nonblocking 경로가 예상치 못한 대기나 오류를 만들지 않음 |
| object lock 격리 | `lock_timeout=0`인 충돌 object lock은 계속 즉시 실패 |
| watchdog 분리 | latch warning, fatal latch, inactive rearm, BCB victim progress 결과를 독립적으로 발생·집계 |
| 오류 주입 | 각 wait 단계의 interrupt와 오류에서 latch ownership, waiter 제거, rollback이 보존됨 |

수집할 telemetry는 acquisition symbol, page type, latch mode별 wait histogram과 queue length, wait 시작 시 보유 중인 latch 목록, volume-header hold time, conditional failure/ordered retry 횟수, warning/fatal/BCB watchdog 횟수를 포함한다.

## Acceptance Criteria

- [ ] `pgbuf_fix_internal()`은 `LOG_TDES::wait_msecs`를 근거로 caller의 `PGBUF_LATCH_CONDITION`을 변경하지 않는다.
- [ ] 같은 명시적 latch 정책에 대해 `pgbuf_timed_sleep()`의 대기 시간과 만료 오류 분류가 `LOG_TDES::wait_msecs`의 zero, positive, infinite 값에 따라 달라지지 않는다.
- [ ] `pgbuf_ordered_fix()`의 retry/unwind 판단은 transaction wait 상태가 아니라 명시적인 try 또는 ordered-retry 정책에 따른다.
- [ ] public `LK_ZERO_WAIT`가 unconditional page-latch 요청을 conditional로 바꾸지 않으며, `lock_timeout=0`의 object lock은 계속 즉시 실패한다.
- [ ] engine-internal `LK_FORCE_ZERO_WAIT` 호출부는 명시적인 try 또는 ordered-retry 정책으로 이전되고, 이전과 동등하게 queue에 들어가지 않으며 불필요한 timeout error를 남기지 않는다.
- [ ] `{LK_ZERO_WAIT, LK_FORCE_ZERO_WAIT, positive, infinite}`와 `{conditional, unconditional}`의 정책 조합별 queue 여부, 반환값, error stack을 deterministic test로 확인한다.
- [ ] positive와 infinite `lock_timeout`의 object lock 동작이 기존과 같음을 회귀 테스트로 확인한다.
- [ ] disk volume header/sector table 경합과 best-space/B-tree force-zero 경로를 deterministic test로 검증한다.
- [ ] latch warning, fatal dead-latch watchdog, BCB victim progress watchdog의 설정과 통계가 서로 구분된다.
- [ ] 1초 값이 page latch의 recoverable acquisition deadline으로 사용되지 않는다.
- [ ] fatal dead-latch watchdog, BCB victim progress watchdog, positive-policy compatibility cutoff는 분리 시점에 각각 300초로 유지하고, warning threshold는 제어 흐름을 바꾸지 않는 별도 계측값으로 정의한다.
- [ ] latch-order 검증과 대기 telemetry 수집을 완료한 뒤 transaction policy에서 파생된 positive-policy page-latch cutoff를 제거한다.
- [ ] 오류 코드 호환성 전환 방안을 문서화한다.
- [ ] latch wait histogram과 보유/대기 관계를 이용해 threshold 조정 근거를 수집할 수 있다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족한다.
- [ ] CUBRID debug/release 빌드와 관련 unit, SQL, shell regression test를 통과한다.
- [ ] concurrency stress와 오류 주입 테스트에서 latch 누수, 무한 대기, 예상하지 않은 transaction abort가 없다.
- [ ] 공개 parameter 또는 오류 의미가 바뀌면 CUBRID manual과 release note를 함께 갱신한다.
- [ ] CBRD-27193 EPIC과 CBRD-27198의 관련 링크 및 후속 상태를 최신으로 유지한다.

## Open Questions

1. 명시적인 page-latch API를 기존 `PGBUF_LATCH_CONDITION` 확장으로 구현할지, wait/try/ordered-retry 함수를 분리할지: `TBD - ANALYSIS 단계에서 결정`.
2. active transaction의 기존 300초 recoverable cutoff를 어느 release까지 호환 동작으로 유지할지: `TBD - 합의 미확인`.
3. warning threshold의 초기값과 300초로 분리한 fatal/BCB threshold의 후속 조정값을 얼마로 정할지: production-like workload의 wait histogram과 운영 장애 감지 정책을 기준으로 결정한다.
4. volume header를 잡은 채 sector table을 기다리는 경로가 허용 가능한 ordering인지, release/retry로 바꿔야 하는지: latch-order audit 후 결정한다.
5. watchdog 설정을 공개 system parameter로 제공할지 내부 진단값으로 유지할지: `TBD - 합의 미확인`.

## References

- Parent EPIC: [CBRD-27193](http://jira.cubrid.org/browse/CBRD-27193)
- 관련 오류: [CBRD-27198](http://jira.cubrid.org/browse/CBRD-27198)
- 관련 PR: [CUBRID/cubrid#7630](https://github.com/CUBRID/cubrid/pull/7630)
- 근거 보고서: [Lock timeout versus latch timeout: CUBRID, PostgreSQL, and MySQL/InnoDB](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27198/research/lock-vs-latch-timeout-survey_d9ceb53_codex.md)
- CUBRID `LOG_TDES::wait_msecs`: [`src/transaction/log_impl.h`](https://github.com/CUBRID/cubrid/blob/d9ceb5317c4d5bf15d2bcd2e89c08c2db9de3530/src/transaction/log_impl.h#L474-L487)
- CUBRID latch admission: [`src/storage/page_buffer.c`](https://github.com/CUBRID/cubrid/blob/d9ceb5317c4d5bf15d2bcd2e89c08c2db9de3530/src/storage/page_buffer.c#L2160-L2236)
- CUBRID latch wait/expiry: [`src/storage/page_buffer.c`](https://github.com/CUBRID/cubrid/blob/d9ceb5317c4d5bf15d2bcd2e89c08c2db9de3530/src/storage/page_buffer.c#L7213-L7378)
- CUBRID hidden latch parameter: [`src/base/system_parameter.c`](https://github.com/CUBRID/cubrid/blob/d9ceb5317c4d5bf15d2bcd2e89c08c2db9de3530/src/base/system_parameter.c#L5340-L5351)

## Remarks

PR #7630에는 CBRD-27198의 증상 완화와 별개로, transaction lock timeout과 page latch 정책의 근본 분리를 CBRD-27356에서 추적한다는 내용을 연결한다. PR comment 게시 시점은 PR 담당자와의 협의에 따른다.
