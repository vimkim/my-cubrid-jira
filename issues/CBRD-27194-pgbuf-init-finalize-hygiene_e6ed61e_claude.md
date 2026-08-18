# [PGBUF] 초기화/종료 경로의 위생 결함을 일괄 수정한다

## Issue Triage

**이슈 수행 목적**: page buffer 초기화·종료 경로에 남은 위생 결함 3건을 없애, 부팅이 실패하는 순간에도 정의된 동작만 남게 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: 세 지점이 각자 자기 자료구조와 어긋나 있다.

| 위치 | 어긋난 점 |
|---|---|
| `page_buffer.c:1626` | `memset` 의 크기 인자가 대상 타입 `PGBUF_DIRECT_VICTIM` (24바이트) 이 아니라 이름이 비슷한 `PGBUF_VICTIM_CANDIDATE_LIST` (16바이트) 라, 마지막 필드 `waiter_threads_low_priority` 가 0 초기화에서 빠진다 |
| `page_buffer.c:5851` + `:1980` | 한 번의 초기화 실패에서 `Aout_mutex` 를 두 번 `pthread_mutex_destroy` 한다 — 이미 파괴한 mutex 를 다시 파괴하는 정의되지 않은 동작이다 |
| `page_buffer.c:13949` | quota 비활성 시 원소 개수가 0 이어서 `malloc (0)` 이 되고, 그 반환값이 부팅 성공 여부를 결정한다 |

- **TO-BE (목표 상태 / 기대 동작)**: memset 은 대상 타입의 크기를 쓰고, `Aout_mutex` 파괴는 finalize 한 곳만 수행하며, 원소 개수가 0 이면 할당을 건너뛴다.
- **영향**: 기술 부채 — 세 건 모두 정상 부팅에서는 드러나지 않고 실패 경로에서만 발현한다. 예컨대 `data_aout_ratio` 를 켠 서버가 AOUT hash 생성 중 메모리 부족을 만나면, 남겨야 할 진단은 `ER_OUT_OF_VIRTUAL_MEMORY` 하나인데 그 위에 mutex 이중 파괴가 겹쳐 원인 추적을 흐린다.

**이슈 수행 방안**:

| 대상 | 수정 |
|---|---|
| `:1626` memset | 크기 인자를 `sizeof (PGBUF_DIRECT_VICTIM)` 으로 바꾼다 |
| `:5851` | 초기화 실패 경로의 `pthread_mutex_destroy` 를 제거해 파괴 소유권을 `pgbuf_finalize` (`:1980`) 하나로 몬다. finalize 가 조건 없이 destroy 하는 현재 형태와 일관된다 |
| `:13949` | `PGBUF_PRIVATE_LRU_COUNT` 가 0 이면 할당을 건너뛰고 포인터를 NULL 로 둔다. 이후 사용처(`:13964-13967` 의 private 인덱스 루프)는 private LRU 가 없으면 돌지 않으므로 추가 가드는 필요하지 않다 |
| 부수 정리 | `:13954-13955` 의 `er_set` 이 `private_lru_session_cnt` 실패를 알리면서 크기로 `PGBUF_TOTAL_LRU_COUNT` 를 넘긴다. 같은 블록이라 함께 `PGBUF_PRIVATE_LRU_COUNT` 로 고친다 (동작 무영향) |

초기화 중간 실패 경로 전반의 자원 소유권 점검을 이 이슈 범위에 포함한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c` 한 파일이며 세 지점 모두 부팅·종료 시점 코드다. 정상 경로의 동작과 성능은 바뀌지 않고, 디스크 형식·설정·통계·외부 interface 도 그대로다. memset 지점은 `#if defined (SERVER_MODE)` 안에 있어 서버 빌드 전용이고, `malloc (0)` 지점은 standalone (SA_MODE) 빌드에서 quota 가 항상 비활성(`:13920`)이라 매 실행 해당된다. QA 관점의 관측 지점은 정상 부팅이 아니라 부팅 실패 주입이다.

------------------------------------------------------------------------

## Description

부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유한 결함은 그 본문의 D2 와 N6 이다. 기존 본문(스크린샷 스텁)을 이 내용으로 교체하며, 원래 D2 만 다루던 범위를 같은 계열 결함 N6 까지로 넓힌다.

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 의 부팅 경로는 `pgbuf_initialize` (`:1602`) 하나에서 시작해, 실패하면 자기 자신이 `pgbuf_finalize` (`:1881`) 를 불러 정리한 뒤 오류를 올린다(`:1867-1870`). 즉 초기화 실패 정리는 finalize 가 전담하는 구조다. 아래 세 지점이 그 구조와 어긋난다.

### 1. memset 이 대상 구조체를 다 덮지 못한다

`direct_victims` 는 victim (재사용할 수 있는 buffer frame) 을 기다리는 스레드에게 BCB (Buffer Control Block — frame 에 올라온 page 의 제어 블록) 를 직접 넘겨주는 장치이고, 포인터 3개로 이루어진다.

```
struct pgbuf_direct_victim                                    :745-752
  PGBUF_BCB **bcb_victims;                     [ 0..7]   <- memset 대상
  circular_queue<THREAD_ENTRY *> *waiter_threads_high_priority;
                                               [ 8..15]  <- memset 대상
  circular_queue<THREAD_ENTRY *> *waiter_threads_low_priority;
                                               [16..23]  ★ 덮이지 않음
```

`:1626` 이 크기 인자로 준 `PGBUF_VICTIM_CANDIDATE_LIST` 는 victim 후보 목록의 원소 타입(`PGBUF_BCB *` + `VPID`)으로 24바이트가 아니라 16바이트다. 이름이 비슷해 생긴 혼동으로 보인다.

지금 실제 피해가 없는 이유는 두 겹이다 — `pgbuf_Pool` 이 static 전역이라 첫 초기화에서는 세 필드가 모두 0 이고, 재초기화 경로(`logtb_define_trantable_log_latch` 가 기존 테이블을 발견하면 `logtb_undefine_trantable` -> `pgbuf_finalize` 를 먼저 수행한다, `src/transaction/log_tran_table.c:423-425`, `:591`) 에서도 finalize 가 `:2026`, `:2031` 에서 두 큐 포인터를 NULL 로 되돌린다. 그러나 초기화 코드가 "구조체 전체를 0 으로 둔다"고 선언하면서 실제로는 3분의 2만 덮는 상태라, 필드를 하나 추가하거나 순서를 바꾸는 순간 finalize 의 `delete` 대상(`:2028-2032`)이 쓰레기 포인터가 된다. 한 단어 수정으로 이 위험을 없애는 편이 낫다.

### 2. Aout_mutex 파괴 소유권이 둘로 갈린다

AOUT (2Q 교체 정책에서 main queue 에서 밀려난 page 식별자의 이력을 보관하는 queue) 초기화는 `pgbuf_initialize_aout_list` (`:5758`) 가 담당한다.

```
pgbuf_initialize                                                 :1602
  └ pgbuf_initialize_aout_list                                   :1726
       pthread_mutex_init (&list->Aout_mutex)                     :5775
       if (aout_ratio <= 0) return NO_ERROR   <- 기본값 0.0 이면 여기서 끝  :5777-5782
       malloc bufarray            실패 -> return (destroy 안 함)   :5787-5792
       malloc aout_buf_ht         실패 -> goto error_return        :5814-5819
       mht_create                 실패 -> goto error_return        :5825-5830
     error_return:
       pthread_mutex_destroy (&list->Aout_mutex)   ★ 1차 파괴      :5851
       return ER_FAILED
  goto error                                                     :1728
error:
  pgbuf_finalize                                                 :1869
    pthread_mutex_destroy (&Aout_mutex)          ★ 2차 파괴       :1980
```

같은 함수 안에서도 규칙이 갈린다 — `bufarray` 할당 실패는 destroy 없이 반환하고(`:5791`), `error_return` 만 destroy 한다. finalize 는 조건 없이 destroy 하므로, 초기화 실패 경로에서 destroy 를 빼는 쪽이 규칙을 하나로 만든다. 발현 조건은 `data_aout_ratio` (기본 0.0 이라 AOUT 자체가 기본 비활성) 를 켠 상태에서 hash 배열 할당이나 `mht_create` 가 실패하는 경우이며, 그래서 지금까지 드러나지 않았다.

### 3. 크기 0 할당의 반환값에 의존한다

`pgbuf_initialize_page_quota` (`:13931`) 는 배열 두 개를 할당하고 각각 NULL 이면 부팅을 실패시킨다.

| 할당 | 원소 개수 | 개수가 0 이 될 수 있는가 |
|---|---|---|
| `lru_victim_flush_priority_per_lru` (`:13939`) | `PGBUF_TOTAL_LRU_COUNT` = shared + private | 아니다. shared LRU 개수는 항상 1 이상이다 |
| `private_lru_session_cnt` (`:13949`) | `PGBUF_PRIVATE_LRU_COUNT` = `quota.num_private_LRU_list` | 그렇다. `num_private_chains=0` 이면 0 이고(`:13905-13908`), SA_MODE 는 항상 0 이다(`:13920`) |

glibc 는 `malloc (0)` 에 대해 free 가능한 유일 포인터를 돌려주므로 현재 플랫폼에서는 통과한다. 반환값이 NULL 인 구현에서는 아무 문제 없는 설정이 메모리 부족으로 오인돼 서버가 뜨지 않는다. 개수가 0 이면 할당을 건너뛰는 것이 의미상으로도 맞다 — 이어지는 초기화 루프(`:13960-13968`)는 private LRU 인덱스에만 접근하므로 private 이 없으면 이 배열을 만지지 않는다.

## Test Build

`CUBRID develop e6ed61e87` (소스 빌드). Fedora 44 / GCC 16.1.1, `cmake --preset debug` 로 만든 debug 빌드에서 확인했다.

## Repro

세 결함 모두 정상 부팅에서는 증상이 없어, 크기 불일치는 디버그 정보로 직접 확인하고 나머지 두 건은 도달 경로를 소스로 확인한다. 명령은 CUBRID 소스 최상위에서 실행한다.

```bash
# 1) memset 크기 불일치: 두 타입의 실제 크기를 오브젝트 파일의 디버그 정보에서 읽는다
cmake --preset debug
cmake --build build_preset_debug --target cub_server
gdb -nx -q -batch \
  -ex 'print sizeof (struct pgbuf_direct_victim)' \
  -ex 'print sizeof (struct pgbuf_victim_candidate_list)' \
  build_preset_debug/cubrid/CMakeFiles/cubrid.dir/__/src/storage/page_buffer.c.o

# memset 이 어느 타입 크기를 쓰는지 확인
sed -n '1625,1627p' src/storage/page_buffer.c
```

```bash
# 2) Aout_mutex 이중 destroy 경로 확인
sed -n '5775,5776p'   src/storage/page_buffer.c   # 초기화에서 mutex_init
sed -n '5835,5853p'   src/storage/page_buffer.c   # 실패 경로의 1차 destroy
sed -n '1726,1729p'   src/storage/page_buffer.c   # 실패 시 goto error
sed -n '1867,1870p'   src/storage/page_buffer.c   # error 라벨이 pgbuf_finalize 호출
sed -n '1980p'        src/storage/page_buffer.c   # finalize 의 2차 destroy

# 오류 주입으로 실제 도달을 확인하려면: cubrid.conf 의 [common] 에 data_aout_ratio=0.1 을 넣고,
# :5814 의 malloc 결과를 강제로 NULL 로 만든 임시 빌드에서 서버를 기동한 뒤,
# 두 destroy 지점(:5851, :1980) 앞에 로그를 넣어 같은 mutex 주소가 두 번 출력되는지 본다
```

```bash
# 3) malloc(0) 의존 확인
sed -n '13949,13957p' src/storage/page_buffer.c   # private_lru_session_cnt 할당과 NULL 판정
sed -n '13905,13908p' src/storage/page_buffer.c   # num_private_chains=0 이면 개수 0
sed -n '13918,13921p' src/storage/page_buffer.c   # SA_MODE 는 항상 0
```

## Expected Result

- 1 단계: `memset` 이 대상 타입 `PGBUF_DIRECT_VICTIM` 의 크기(24바이트)를 쓰므로 구조체 세 필드가 모두 0 으로 초기화된다.
- 2 단계: 하나의 mutex 는 최대 한 번만 파괴된다. AOUT 초기화가 실패해도 남는 진단은 `ER_OUT_OF_VIRTUAL_MEMORY` 뿐이다.
- 3 단계: 원소 개수가 0 이면 할당을 시도하지 않으므로, allocator 의 크기 0 처리 방식과 무관하게 부팅이 성공한다.

## Actual Result

1 단계 출력은 다음과 같아 8바이트가 초기화에서 빠지는 것이 확인된다.

```
$1 = 24
$2 = 16
```

2 단계의 다섯 발췌를 이으면 `pgbuf_initialize_aout_list` 의 `error_return` -> `pgbuf_initialize` 의 `error` -> `pgbuf_finalize` 순으로 같은 `Aout_mutex` 가 두 번 파괴되는 경로가 그대로 드러난다.

3 단계에서 `num_private_chains=0` 또는 standalone 실행이면 `PGBUF_PRIVATE_LRU_COUNT` 가 0 이므로 `malloc (0)` 이 호출되고, 그 반환값이 부팅 성공 여부를 결정한다.

## Additional Information

- 세 건은 위치가 다르지만 모두 초기화·종료 위생 문제이고 각각 한두 줄 수정이라 하나의 PR 로 묶는다. 되돌릴 필요가 생겨도 정상 경로 동작 변화가 없어 revert 단위가 단순하다.
- AOUT 이 기본 비활성인 근본 원인(`data_aout_ratio` 기본값 0.0)은 기존 CBRD-20741 과 연결돼 있어 이 이슈에서 다루지 않는다.
- 부모 EPIC: CBRD-27193 (page buffer 안정성 개선). 이 이슈는 그 표의 A4 항목이다.

### 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:1602-1871` | `pgbuf_initialize` — 실패 시 `pgbuf_finalize` 호출 구조 |
| `page_buffer.c:745-752` | `PGBUF_DIRECT_VICTIM` 정의 (포인터 3개) |
| `page_buffer.c:841-845` | `PGBUF_VICTIM_CANDIDATE_LIST` 정의 (memset 이 잘못 참조한 타입) |
| `page_buffer.c:2013-2038` | finalize 의 `direct_victims` 정리 |
| `page_buffer.c:5758-5855` | `pgbuf_initialize_aout_list` — mutex init 과 실패 경로 |
| `page_buffer.c:13931-13984` | `pgbuf_initialize_page_quota` — 두 배열 할당 |
| `src/transaction/log_tran_table.c:423-425`, `:494`, `:591` | 재초기화 시 finalize 선행 경로 |
