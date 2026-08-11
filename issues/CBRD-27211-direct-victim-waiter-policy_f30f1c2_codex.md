# [PGBUF] direct victim 대기 큐의 고정 우선순위 배급 정책을 검증한다

## Issue Triage

**이슈 수행 목적**: `direct victim`(확보한 buffer frame을 대기 스레드에 직접 배급하는 경로)의 대기자 선택 비용과 priority별 대기시간을 측정해, 고정값 `4`를 유지할지 queue 상태에 반응하는 적응형 정책으로 바꿀지 결정한다. 선택한 정책은 high priority의 빠른 진행과 low priority의 기아 방지를 함께 보장해야 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `pgbuf_get_thread_waiting_for_direct_victim()`은 매 네 번째 호출에만 low queue의 consume을 먼저 시도하고, 나머지는 high부터 시도한다. consume 실패와 stale waiter 때문에 실제 BCB 배급 비율은 3:1로 보장되지 않으며, `4`의 정량적 선정 근거도 소스와 원 이슈에서 확인되지 않는다. |
| **TO-BE (목표 상태 / 기대 동작)** | buffer pressure 시나리오별 선택 함수 비용, 처리량, high/low priority 대기시간을 근거로 정책을 정한다. 현행 정책이 충분하면 유지하고, 불균형이 확인되면 high priority 지연 상한과 low priority 기아 방지 조건을 명시한 적응형 정책을 적용한다. |
| **영향** | 성능 저하 가능성 — low backlog가 커져도 low-first 시도는 네 호출 중 한 번으로 고정되고, high 의존 작업이 밀려도 같은 주기를 쓴다. workload와 무관한 우선 시도 순서가 buffer frame 할당 대기시간과 전체 처리량을 악화시키는지는 아직 측정되지 않았다. |

**이슈 수행 방안**: 사용자 인용: "checks low priority queue every 4 times. I'll check if this is a perf bottleneck. I'll check if hard-coded number 4 is a reasonable choice, or any improvements based on low and high priority queue size or scenario. adaptive." 현행 정책, 다른 고정 비율, 적응형 prototype을 같은 workload에서 비교한다. 구현 스펙은 `TBD - ANALYSIS 단계에서 결정`한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 주 조사 대상은 `src/storage/page_buffer.c`의 direct victim 대기·배급 경로와 `src/base/lockfree_circular_queue.hpp`다. 정책을 바꾸더라도 디스크 형식, SQL, 공개 API에는 영향이 없으며, 측정에 필요한 page buffer 성능 통계가 추가될 수 있다.
- **기준 소스**: CUBRID commit `f30f1c26003e5aa8e93182648e06cad76fc77064`.

## Description

새 페이지를 읽을 BCB(Buffer Control Block — buffer frame의 상태를 관리하는 구조체)를 찾지 못한 스레드는 `pgbuf_allocate_bcb()`에서 high 또는 low priority queue에 들어가 direct victim 배급을 기다린다.

high priority에는 vacuum worker, 다른 스레드가 기다리는 페이지를 보유한 스레드, volume/file/heap header나 B-tree root 같은 중요 페이지를 보유한 스레드가 들어간다. 이미 배급받은 BCB가 다시 fix되어 재시도하는 스레드도 high priority로 승격된다. 그 밖의 일반 요청은 low priority에 들어가므로, high queue를 먼저 처리하는 목적은 vacuum과 `latch`(페이지 동시 접근을 조정하는 내부 잠금) 의존 관계가 일반 요청 뒤에 막히지 않게 하는 데 있다.

BCB를 확보한 여러 경로는 `pgbuf_assign_direct_victim()`으로 모인다. 이 함수는 queue에서 꺼낸 스레드가 아직 `THREAD_ALLOC_BCB_SUSPENDED` 상태인지 확인하고, 이미 timeout 또는 interrupt로 대기를 끝낸 항목이면 버린 뒤 다음 대기자를 찾는다. 따라서 queue에서 항목을 선택한 횟수와 실제 BCB 배급 횟수는 같지 않을 수 있다.

현재 선택 정책은 2017년 commit `39e234caf`의 CBRD-20074 page quota 변경에서 도입됐다. 당시 이슈에는 page quota 전체의 YCSB 결과가 여러 차례 기록됐으며, 해당 commit은 victim 탐색 중 CPU 소모를 줄이기 위해 스레드를 대기시킨 뒤 direct victim을 배급하는 구조를 함께 추가했다.

## Specification Changes

현재 단계에서는 N/A다. 이 이슈는 측정 결과와 정책 결정을 산출하며, 제품 동작 변경은 확정된 후속 구현 스펙에서 다룬다.

## Implementation

### 현재 대기와 배급 흐름

`LRU`(Least Recently Used — 오래 참조되지 않은 페이지부터 victim 후보로 관리하는 목록)는 buffer frame을 재사용하는 주요 경로다.

```
pgbuf_allocate_bcb()
  ├ invalid BCB 탐색 실패
  ├ 일반 victim 탐색 실패
  ├ high queue: vacuum, 중요/경합 페이지 보유자, direct victim 재시도
  └ low queue: 그 밖의 일반 요청
       └ thread_suspend_timeout_wakeup_and_unlock_entry()

victim BCB 확보 경로
  └ pgbuf_assign_direct_victim()
       └ pgbuf_get_thread_waiting_for_direct_victim()
            ├ count를 전역 atomic increment
            ├ count % 4 == 0  -> low 먼저 consume
            ├ high consume
            └ low consume
             ★ 고정 순서와 전역 atomic 비용의 타당성을 검증할 지점
```

### 현행 정책의 실제 성질

| 호출 시점에 consume 가능한 head | consume 시도 순서와 결과 |
|----------------------------------|--------------------------|
| high와 low 모두 가능, `count % 4 != 0` | high를 먼저 consume하며 성공하면 반환 |
| high와 low 모두 가능, `count % 4 == 0` | low를 먼저 consume하며 성공하면 반환 |
| high만 가능 | 네 번째 호출에는 low 실패 후 high, 나머지는 high에서 성공 |
| low만 가능 | 네 번째 호출에는 low, 나머지는 high 실패 후 low에서 성공 |
| 둘 다 불가능 | 모든 시도가 실패한다. 그래도 `count`는 증가 |

cursor상 non-empty여도 head slot이 blocked 상태면 `consume()`은 실패한다. 위 표의 성공은 해당 queue의 head가 게시 완료되어 consume 가능한 경우만 뜻한다.

dequeue 시도 순서가 곧 실제 배급 비율이나 대기시간 비율을 뜻하지는 않는다. timeout 등으로 유효하지 않은 대기자를 꺼내면 같은 BCB를 배급하기 위해 함수를 다시 호출하며 `count`도 다시 증가한다. queue가 빈 호출도 다음 순서를 바꾸므로 workload의 producer 비율과 donor 호출 시점에 따라 관측 비율이 달라진다.

`count`는 모든 donor가 갱신하는 하나의 64-bit atomic 변수다. post-flush, vacuum unfix, `pgbuf_lru_add_new_bcb_to_bottom()`은 대기자 유무를 먼저 확인하지 않고 `pgbuf_assign_direct_victim()`을 호출하므로, queue가 비어 있어도 이 atomic increment가 실행될 수 있다. 반면 victim 후보 수집과 LRU zone 3 이동 경로는 `pgbuf_is_any_thread_waiting_for_direct_victim()`을 먼저 확인한다. 이 cache line이 동시 donor 사이에서 이동하는 비용은 병목 후보지만, 소스 모양만으로 결론 내리지 않고 경로별 호출 빈도와 CPU 표본을 함께 확인해야 한다.

`circular_queue::size()`는 producer cursor와 consumer cursor를 차례로 atomic load해 차이를 구한다. 한 queue 안에서도 두 cursor를 같은 시점에 읽지 않으며, producer가 cursor를 전진시킨 뒤 data를 게시하기 전의 blocked slot과 timeout 후 아직 consume되지 않은 stale waiter도 깊이에 포함될 수 있다. 생성자 요청 크기는 high가 `thread_num_total_threads()`, low가 그 두 배이며, 실제 `m_capacity`는 각각 다음 2의 거듭제곱으로 올림된다. 소스 주석에 기록된 약 93ms의 consumer preemption 뒤 low queue produce가 실패한 사례를 완화하려고 low 요청 크기를 늘렸으며, produce에 실패한 low 요청은 high queue로 들어간다. 두 queue의 size는 같은 의미나 같은 시점의 부하가 아니므로 scheduling hint로만 사용할 수 있다.

### 측정 가능 항목과 빈칸

| 구분 | 현재 확보 가능한 지표 | 추가로 필요한 관측 |
|------|------------------------|---------------------|
| 선택 함수 | `assign_direct_bcb`의 호출 수·누적 시간·평균 시간 | high/low consume 시도·성공 수, empty 결과, 유효하지 않은 waiter skip 수 |
| queue 대기 | `alloc_bcb_cond_wait_high_prio`, `alloc_bcb_cond_wait_low_prio`의 count와 시간 | priority별 p50/p95/p99/max 대기시간, timeout 수 |
| queue 깊이 | `Num_alloc_bcb_wait_threads_high_priority`, `Num_alloc_bcb_wait_threads_low_priority` 순간값 | 시간 구간별 평균·최대 깊이와 backlog 지속 시간 |
| 배급 경로 | flush, vacuum, LRU adjust, panic 등 donor별 direct assignment 횟수 | 선택 정책별 실제 high/low BCB 배급 수 |
| 전체 효과 | TPS, query wall/CPU, page read/write, buffer hit ratio | 반복 실행 분산과 정책 변경 전후 effect size |

계측 build는 전역 active-waiter counter 대신 priority별 wait interval을 기록한다. queue produce 성공 뒤 suspend 직전에 monotonic timestamp로 시작 event를 남기고, selector가 `THREAD_ALLOC_BCB_SUSPENDED`를 확인한 시점이나 waiter가 timeout·interrupt로 빠져나온 시점에 종료 event를 남긴다. 종료는 thread entry lock과 test-only per-thread state로 직렬화해 interval마다 한 번만 기록한다. 최초 분류 priority, 실제 진입 queue, low→high overflow 승격 이유, valid/stale consume도 같은 record에 넣는다. 이 interval은 논리적으로 유효한 대기 수요를 나타낼 뿐, blocked head까지 고려한 순간 consume 가능성을 뜻하지는 않는다.

event는 스레드별로 미리 할당한 buffer에 기록하고 실험 뒤 offline으로 합쳐, priority별 wait 분포와 high/low interval의 겹친 시간을 계산한다. 전역 atomic counter나 주기적 sampling을 추가하지 않으므로 selector의 공유 cache line 경쟁을 새로 만들지 않는다. 동일 baseline을 tracing on/off로 비교해 paired TPS difference의 95% 신뢰구간 전체가 `[-1%, +1%]` 안에 있고, 기존 `alloc_bcb_cond_wait_high_prio`와 `alloc_bcb_cond_wait_low_prio`의 count·평균 wait difference가 각각 `[-5%, +5%]` 안에 있는지 확인한다. 이 조건을 못 맞추면 sampling 또는 sharded histogram으로 계측량을 줄인다.

측정용 counter 자체가 hot path 비용을 키우지 않도록 detailed page-buffer perf tracking이 활성화된 경우에만 수집하거나 실험용 build에 한정한다. percentile 계산을 위해 매 요청을 기록해야 한다면 전체 event 저장보다 고정 크기 histogram을 우선 검토한다.

### 검증 시나리오

| 시나리오 | 만드는 조건 | 확인할 위험 |
|----------|-------------|-------------|
| low-only pressure | 최초 분류 suspend의 99% 이상이 low가 되도록 일반 worker를 실행 | 전역 atomic과 불필요한 high consume 확인 비용 |
| high-only pressure | 최초 분류 suspend의 99% 이상이 high가 되도록 vacuum 또는 중요 페이지 보유자 대기를 유도 | low-first 시도 비용과 high progress |
| 균형 혼합 | 최초 분류 high와 low wait interval이 각각 40~60%이고 두 priority interval이 겹친 시간이 측정 구간의 20% 이상 | 고정 우선 순서가 대기시간과 처리량에 미치는 영향 |
| low backlog | 최초 분류 low interval이 80% 이상이고 두 priority interval이 겹친 시간이 20% 이상 | low queue 기아와 backlog 회복 시간 |
| high backlog | 최초 분류 high interval이 80% 이상이고 두 priority interval이 겹친 시간이 20% 이상 | low-first 고정 주기 때문에 high dependency 해소가 늦어지는지 확인 |
| queue churn | 짧은 timeout·interrupt 또는 direct victim 무효화 재시도를 유도 | dequeue 시도 비율과 실제 배급 비율의 괴리 |
| 실사용 회귀 | CBRD-27188, CBRD-27191에서 사용한 TPC-H 조건과 page buffer pressure workload | 미세 benchmark 이득이 query 성능 회귀로 바뀌는지 확인 |

99% 조건은 한 priority를 격리하고, 40~60%는 균형 부하를 만들며, 80%는 한쪽 backlog를 재현하기 위한 구간이다. high/low wait interval 겹침 20%는 두 종류의 수요가 같은 시간대에 존재한 표본을 확보하기 위한 하한이다. 이 조성 조건을 충족하지 못한 실행은 정책 비교에서 제외한다.

각 시나리오는 `data_buffer_size=256M`에서 table과 index의 합산 working set을 1GiB 이상으로 만들어 pool 대비 네 배 이상의 지속적인 victim pressure를 건다. 동일한 source, 설정, data로 30초 warm-up 뒤 60초를 측정하며 worker 8, 32, 64에서 각각 10회 반복한다. 세 worker 수는 낮음·중간·높은 동시성을 비교하기 위한 것이고, 10회 반복은 실행 간 분산과 신뢰구간을 구하기 위한 최소 표본이다. baseline과 후보를 같은 순서쌍으로 번갈아 실행해 시간대·열·background I/O 영향을 줄이고, paired difference의 95% 신뢰구간을 계산한다.

후보 실행 전에 비열등성 margin을 TPS `-1%`, high priority p99 대기시간 `+5%`, page read `+1%`로 고정한다. TPS와 page read의 1%는 작은 selector 변경이 허용할 최대 전체 회귀 폭이고, 변동성이 큰 tail latency에는 5%를 적용한다. baseline 10회의 신뢰구간이 이 margin보다 넓으면 환경을 안정화하고 반복 수를 늘린다.

selector의 CPU 비용은 상세 counter를 넣지 않은 build에서 Linux `perf`로 먼저 확인한다. inlining된 `ATOMIC_INC_64()` 소스 위치까지 보려면 debug symbol을 유지한 동일 최적화 build를 사용한다.

```bash
server_pid=$(pgrep -n cub_server)
perf stat -e cycles,instructions,cache-misses -p "$server_pid" -- sleep 60
perf record -g -p "$server_pid" -- sleep 60
perf report --stdio --no-children --percent-type global-period --sort=overhead,srcline
perf annotate --stdio --print-line
```

`perf report`의 전체 user-space sample을 분모로 두고, `page_buffer.c`의 selector 범위와 inlining된 `porting.h:ATOMIC_INC_64()`에 귀속된 `overhead`를 합산한다. `srcline`이 해석되지 않는 build는 판정 표본에서 제외한다.

priority별 enqueue·consume·유효 배급 수와 wait histogram은 별도 계측 build에서 수집한다. 계측 build의 TPS를 selector CPU 개선 근거로 쓰지 않고, 비계측 build의 처리량·CPU 결과와 분리한다.

### 정책 후보와 검토 순서

| 순위 | 후보 | 권장 이유 / 고려사항 |
|------|------|---------------------|
| 1 | 현행 고정 `4` 유지 | 선택 함수의 CPU 비중이 작고 두 priority의 tail latency가 허용 범위라면 가장 단순하다. 유지 결론에도 측정 근거를 남긴다. |
| 2 | 제한형 적응형 hybrid | 평소 high-first를 유지하되 low backlog 또는 대기시간이 커지면 low 선택 기회를 늘린다. size의 순간 변동에 반응하지 않도록 hysteresis와 queue 상태에 의존하지 않는 최소 선택 주기가 함께 필요하다. |
| 3 | 고정 비율 재조정 | `2`, `4`, `8` 등 소수 후보를 sweep해 workload에 맞는 비율을 찾는다. 구현은 단순하지만 환경이 바뀌면 같은 문제가 반복된다. |
| 4 | queue 깊이 비례 배급 | 현재 `size()`만으로 구현할 수 있으나 근사 snapshot의 흔들림과 low burst가 high priority 의미를 약화시킬 위험이 있다. |
| 5 | 가장 오래 기다린 queue 우선 | tail latency와 기아를 직접 제어할 수 있지만 enqueue timestamp와 추가 상태가 필요하며 high priority의 의존 관계 해소 목적을 흐릴 수 있다. |

적응형 후보는 다음 조건을 만족해야 한다.

1. 어느 한 queue에만 consume 가능한 head가 있으면 같은 호출에서 그 queue까지 시도하는 work-conserving 동작을 유지한다.
2. 순간 size나 연속 배급 수만으로 대기시간 상한을 주장하지 않는다. queue 상태와 무관한 최소 선택 주기로 각 priority의 dequeue 기회를 보장하고, 실제 wait tail은 측정값으로 검증한다.
3. queue size는 blocked slot과 stale waiter를 포함할 수 있는 hint로 취급하고, consume 실패 시 다른 queue를 시도한다.
4. high priority에 섞이는 vacuum, latch 의존 보유자, 재시도 스레드, low queue overflow 승격을 각각 계수해 결과를 해석한다.
5. 새 system parameter는 측정으로 운영 조정 필요성이 확인된 경우에만 검토한다.

## Acceptance Criteria

- [ ] targeted selector 시나리오는 `data_buffer_size=256M`, working set 1GiB 이상, 30초 warm-up, 60초 측정, worker 8/32/64, 각 10회 조건으로 실행하고 기준 build와 하드웨어를 기록한다.
- [ ] 각 실행의 최초 분류 priority별 wait interval, 실제 진입 queue, overflow 승격, valid/stale consume, high/low interval 겹침, selector 호출 수를 기록한다. 위 표의 조성 조건과 통계 비교에 필요한 selector 100,000회 이상을 충족한 실행만 비교한다.
- [ ] low-only, high-only, 균형 혼합, low backlog, high backlog, queue churn에서 selector CPU, priority별 consume·유효 배급 수, queue 깊이, wait p50/p95/p99/max, timeout, TPS를 수집한다.
- [ ] 현행 `4`, 고정 비율 `2`와 `8`, 최소 한 개의 제한형 적응형 prototype을 동일 조건에서 비교한다.
- [ ] CBRD-27188과 CBRD-27191에서 사용한 TPC-H 조건을 회귀군에 포함하고 query 결과, wall/CPU, page read/write 변화를 기록한다.
- [ ] 비계측 build의 `perf`에서 `ATOMIC_INC_64()`와 selector 소스 위치의 on-CPU sample이 두 개 이상 시나리오에서 1% 이상이면 CPU 병목 후보로 판정한다. 모든 시나리오에서 1% 미만이고 후보별 paired TPS difference의 95% 신뢰구간 전체가 `[-1%, +1%]` 안에 있으며 priority별 p99 개선도 5%에 못 미치면 CPU 병목이 아닌 것으로 결론 낸다.
- [ ] 적응형 정책은 backlog 시나리오 하나 이상의 p99를 5% 이상 또는 TPS를 1% 이상 개선하고 개선 margin 밖에 95% 신뢰구간 전체가 놓여야 한다. 동시에 paired difference의 95% 신뢰구간이 TPS는 `-1%` 이상, high p99는 `+5%` 이하, page read는 `+1%` 이하에 완전히 들어와야 한다.
- [ ] 의도적으로 timeout·interrupt를 발생시키는 queue churn 이외의 시나리오에서는 timeout이 0이어야 한다. churn은 다음 oracle을 각각 검증한다: 미배급 timeout·interrupt는 queue를 drain한 뒤 주입 수와 stale skip 수가 같아야 한다. 배급 후 interrupt는 valid consume 뒤 victim slot과 direct-victim flag가 정리되고 stale skip이 없어야 한다. 배급 BCB invalidation은 `pgbuf_get_direct_victim()`의 NULL 반환과 high priority 재등록이 주입 수만큼 발생해야 한다.
- [ ] 적응형 정책을 선택하면 high priority 보호 기준, low priority 최소 선택 주기, 입력값, 임계값, hysteresis, fallback 순서를 구현 전에 확정한다.
- [ ] 정책 변경 시 동시 producer/consumer, empty queue, stale waiter, timeout/interrupt, direct victim 무효화 재시도 회귀 테스트가 통과한다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족한다.
- [ ] 측정 결과와 raw data 위치, 재현 절차를 남긴다.
- [ ] 현행 유지 또는 구현할 정책을 결정하고, 구현이 분리되면 후속 이슈에 확정 스펙과 성능 기준을 연결한다.
- [ ] 정책을 변경한 경우 CUBRID 기능·성능 QA를 통과한다.

## Open Questions

### 적응형 정책의 입력

queue depth만 사용할지, 대기시간 또는 최근 배급 비율까지 포함할지는 `TBD - ANALYSIS 단계에서 결정`한다. blocked slot, stale waiter, low overflow 승격 때문에 depth만으로 실제 대기 수요를 판단하기 어렵다는 점을 실험에서 함께 검증한다.

### 고정값 제거 범위

고정 `4`만 바꿀지, 매 호출의 전역 atomic increment까지 없앨지는 별도 측정값으로 판단한다. queue 정책의 tail latency 개선과 selector 자체의 CPU 감소를 하나의 효과로 합쳐 해석하지 않는다.

## References

- [기준 `pgbuf_get_thread_waiting_for_direct_victim()` 소스](https://github.com/CUBRID/CUBRID/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/src/storage/page_buffer.c#L15490-L15519)
- [lock-free circular queue의 `consume()`과 `size()`](https://github.com/CUBRID/CUBRID/blob/f30f1c26003e5aa8e93182648e06cad76fc77064/src/base/lockfree_circular_queue.hpp#L318-L406)
- [CBRD-20074 — Page quota per client/transaction](http://jira.cubrid.org/browse/CBRD-20074)
- [CUBRID LRU·direct victim 분석](https://github.com/vimkim/my-cubrid-docs/blob/0c05646325e56f60117895fd89babb574f811a18/pgbuf-analysis/research/cubrid-lru-victim.md)
- [CBRD-27188 — 세션당 private LRU quota 상한 개선](http://jira.cubrid.org/browse/CBRD-27188)
- [CBRD-27191 — HIT 경로 LRU 재배치 비용 축소](http://jira.cubrid.org/browse/CBRD-27191)
