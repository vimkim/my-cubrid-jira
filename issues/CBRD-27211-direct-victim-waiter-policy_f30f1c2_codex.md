# [PGBUF] direct victim 대기 큐의 고정값 `4`를 검증한다

## Issue Triage

**이슈 수행 목적**: `direct victim`(디스크 페이지를 담는 메모리 슬롯인 buffer frame을 재사용해 대기 스레드에 직접 넘기는 방식)의 대기자 선택 규칙이 성능에 미치는 영향을 확인해, 결과에 따라 고정값 `4`를 유지하거나 더 나은 규칙으로 바꾼다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `pgbuf_get_thread_waiting_for_direct_victim()`은 네 번째 호출마다 low priority queue를 먼저 확인한다. 나머지 호출은 high priority queue를 먼저 확인한다. 먼저 시도한 consume이 실패하면 다른 queue도 확인한다. 고정값 `4`만 분리해 검증한 근거는 확인되지 않는다. |
| **TO-BE (목표 상태 / 기대 동작)** | 현재 규칙에 문제가 없으면 그대로 유지한다. CPU 비용이나 대기시간 문제가 확인되면 high priority를 보호하면서 low priority도 오래 기다리지 않는 규칙을 정한다. |
| **영향** | 성능 저하 가능성 — buffer frame이 부족한 상황에서 고정된 순서가 workload와 맞지 않으면 일반 작업이나 vacuum 같은 중요 작업의 대기시간이 늘어날 수 있다. |

**이슈 수행 방안**: 사용자 인용: "hard-coded number 4 ... reasonable choice ... adaptive." 현행 `4`를 기준으로 다른 고정값과 간단한 적응형 후보를 비교한다. 최종 규칙은 `TBD - ANALYSIS 단계에서 결정`한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 주 조사 대상은 `src/storage/page_buffer.c`의 direct victim 대기자 선택 경로다. 디스크 형식, SQL, 공개 API는 바뀌지 않는다.
- **기준 소스**: CUBRID commit `f30f1c26003e5aa8e93182648e06cad76fc77064`.

## Description

페이지 버퍼에서 재사용할 frame을 찾지 못하면 새 페이지를 읽을 수 없다. 이때 일반 victim 탐색에도 실패한 스레드는 재사용 가능한 frame이 생길 때까지 대기한다.

대기 queue는 두 개다.

| Queue | 들어가는 스레드 | 먼저 처리하는 이유 |
|-------|-----------------|---------------------|
| high priority | vacuum worker, 다른 스레드가 기다리는 페이지를 보유한 스레드, volume/file/heap header나 B-tree root 같은 중요 페이지를 보유한 스레드, direct victim 재시도 스레드 | 이 작업이 막히면 다른 작업까지 함께 늦어질 수 있다. |
| low priority | 그 밖의 일반 스레드 | 일반 작업도 굶지 않도록 일정하게 처리해야 한다. |

low queue enqueue가 실패하면 일반 스레드도 high queue로 이동한다. 따라서 queue 길이만 보고 실제 high priority 작업 수를 판단하면 안 된다.

현재 규칙은 2017년 CBRD-20074 page quota 변경에서 추가됐다. 당시 page buffer 전체 성능 시험은 남아 있지만, 숫자 `4`만 따로 비교한 결과는 확인되지 않는다.

## Specification Changes

현재 단계에서는 N/A다. 이 이슈는 측정 결과와 유지·변경 결정을 남기는 조사 작업이다.

## Implementation

### 현재 선택 순서

```
pgbuf_get_thread_waiting_for_direct_victim()
  └ 호출 횟수 count 증가
       ├ 네 번째 호출     : low -> high -> low
       └ 나머지 세 호출   : high 먼저 -> 실패하면 low
```

여기서 `4`는 low queue를 네 번에 한 번만 확인한다는 뜻이 아니다. 두 queue를 모두 확인할 수 있으며, 네 번째 호출에서만 확인 순서가 바뀐다.

`count`는 여러 스레드가 함께 갱신하는 atomic 변수다. 일부 경로는 대기 queue가 비어 있어도 이 값을 증가시키므로, 선택 순서뿐 아니라 atomic 연산 자체가 병목인지도 확인한다.

### 확인할 지표

| 질문 | 확인할 값 |
|------|-----------|
| 선택 함수 자체가 비싼가? | selector와 atomic 증가 구간의 CPU 비중 |
| 어느 queue가 오래 기다리는가? | high/low priority별 평균·p99·최대 대기시간 |
| 대기자가 실제로 쌓이는가? | high/low queue의 평균·최대 길이 |
| 전체 성능이 달라지는가? | TPS, query wall time, page read/write |

기존 `assign_direct_bcb`, `alloc_bcb_cond_wait_high_prio`, `alloc_bcb_cond_wait_low_prio` 통계를 우선 사용한다. 부족한 값만 실험용 counter로 추가하고, counter를 켠 결과와 끈 결과를 구분한다.

### 비교할 후보

| 후보 | 의미 |
|------|------|
| 현행 `4` | 기준값이다. 유의미한 문제가 없으면 유지한다. |
| 고정값 `2`, `8` | low-first 빈도를 늘리거나 줄였을 때 방향을 확인한다. |
| 적응형 규칙 | 두 queue에 대기자가 함께 있을 때만 queue 상태에 따라 순서를 조정한다. |

`circular_queue::size()`는 동시 실행 중 바뀌는 근사값이다. 따라서 적응형 규칙을 쓰더라도 size는 참고값으로만 사용하고, 어느 한 queue만 처리 가능한 경우에는 즉시 그 queue를 처리해야 한다.

### 검증할 상황

1. 일반 worker만 대기하는 경우
2. vacuum 등 high priority만 대기하는 경우
3. high와 low가 함께 대기하는 경우
4. CBRD-27188, CBRD-27191에서 사용한 TPC-H 회귀 workload

같은 build, data, 설정에서 각 후보를 순서쌍으로 반복 실행한다. 1%는 전체 처리량에서 의미 있는 최소 차이로 보고, 변동성이 더 큰 p99 대기시간은 5%를 기준으로 본다. 같은 조건의 paired 반복 결과에서 실행 간 변동 범위를 벗어난 차이만 개선 또는 회귀로 판정한다.

| 결과 | 결정 |
|------|------|
| selector CPU 비중이 1% 미만이고 다른 후보의 TPS·대기시간 개선도 기준 미만 | 현행 `4` 유지 |
| 다른 고정값이 TPS 1% 또는 p99 5% 이상 개선하고 반대 priority를 악화시키지 않음 | 더 나은 고정값 검토 |
| queue 구성에 따라 유리한 고정값이 달라짐 | 적응형 규칙 검토 |

## Acceptance Criteria

- [ ] 현재 `4`에서 selector CPU와 high/low priority 대기시간을 측정한다.
- [ ] 일반-only, high-only, 혼합, TPC-H 회귀 상황에서 `4`, `2`, `8`을 같은 조건으로 비교한다.
- [ ] 고정값의 결과가 workload마다 다르면 적응형 후보를 한 개 이상 비교한다.
- [ ] TPS 1%, p99 대기시간 5% 기준으로 현행 유지 또는 변경 결론을 내린다.
- [ ] 선택한 후보가 반대 priority의 p99 대기시간과 전체 TPS를 기준 이상 악화시키지 않는지 확인한다.
- [ ] 정책을 바꾸면 empty queue, timeout, interrupt, direct victim 재시도 회귀 테스트를 통과한다.

## Definition of done

- [ ] 측정 환경, 반복 횟수, 결과를 남긴다.
- [ ] 고정값 `4`의 유지 또는 변경 근거를 문서화한다.
- [ ] 변경이 필요하면 최종 선택 규칙과 성능 기준을 구현 전에 확정한다.
- [ ] 변경한 경우 CUBRID 기능·성능 QA를 통과한다.

## Open Questions

### 적응형 규칙의 입력

queue 길이만 사용할지, 최근 대기시간도 함께 볼지는 `TBD - ANALYSIS 단계에서 결정`한다.

### 설정값 노출 여부

운영자가 조정할 system parameter가 필요한지는 `TBD - ANALYSIS 단계에서 결정`한다. 먼저 코드 내부 정책으로 충분한지 확인한다.

## References

- [기준 `pgbuf_get_thread_waiting_for_direct_victim()` 소스](https://github.com/CUBRID/CUBRID/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/src/storage/page_buffer.c#L15490-L15519)
- [lock-free circular queue의 `consume()`과 `size()`](https://github.com/CUBRID/CUBRID/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/src/base/lockfree_circular_queue.hpp#L318-L406)
- [CBRD-20074 — Page quota per client/transaction](http://jira.cubrid.org/browse/CBRD-20074)
- [CBRD-27188 — private LRU quota 상한 개선](http://jira.cubrid.org/browse/CBRD-27188)
- [CBRD-27191 — HIT 경로 LRU 재배치 비용 축소](http://jira.cubrid.org/browse/CBRD-27191)
