# [PGBUF] direct victim 긴급 배정 경로가 실행되지 않는 오류를 처리한다

## Issue Triage

**이슈 수행 목적**: victim 공급이 끊긴 순간 대기 스레드를 구제하도록 설계된 direct victim 긴급 배정 경로 두 곳이 실제로 동작하게 하거나, 동작하지 않는 채로 남은 코드를 제거해 코드와 실제 동작을 일치시킨다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: 100ms 주기 `pgbuf-maintain` 데몬(`page_buffer.c:17113`)이 부르는 `pgbuf_direct_victims_maintenance` (`:9563`) 의 두 순회는 `index = prv_index` 로 시작한 뒤 조건에서 `index != prv_index` 를 요구해(`:9577`, `:9586`) 본문이 한 번도 실행되지 않고, 긴급 배정 함수의 나머지 호출부(`:9407`)는 리스트에서 이미 떼어낸 BCB 의 이웃 포인터를 넘겨 항상 NULL 로 진입한다. 그래서 긴급 배정 통계 `Num_victim_assign_direct_panic` 은 어떤 부하에서도 0 을 벗어날 수 없다.
- **TO-BE (목표 상태 / 기대 동작)**: 두 결말 중 하나로 정리한다 — 순회를 의도대로 고쳐 저활동 구간에서도 주기적으로 direct victim 이 배정되게 하거나, 경로 자체를 제거해 "백업 플랜이 있다"는 코드상의 약속을 없앤다. 선택은 `TBD - 합의 미확인`.
- **영향**: 설계 의도 훼손 — `pgbuf_allocate_bcb` 의 `:8162-8166` TODO 주석이 우려한 "아무도 대기 스레드에게 victim 을 공급하지 않는 경우"에 대한 방어가 실질적으로 없다. 그 상황에 걸린 스레드는 `page_latch_timeout_in_msecs` (기본 300,000ms = 5분) 를 다 기다린 뒤 `ER_CSS_PTHREAD_COND_TIMEDOUT` 로 실패하며, debug 빌드는 그전에 `:8292` 의 `assert (r != ER_CSS_PTHREAD_COND_TIMEDOUT)` 로 서버가 중단된다.

**이슈 수행 방안**: 목표 동작 선택은 미결이라 후보를 함께 올린다. 선택: `TBD - 합의 미확인`.

| 순위 | 후보 | 고려사항 |
|---|---|---|
| 1 | 순회 조건을 고쳐 백업 경로를 되살린다. 조건에서 `index != prv_index` 를 빼면 시작점부터 마지막 인덱스까지 훑고 다음 호출이 0 부터 이어받으며, `!(index == prv_index && restarted)` 로 바꾸면 호출마다 한 바퀴를 온전히 돈다. `:9407` 호출부는 리스트 이탈 전의 이웃 포인터를 넘기도록 함께 고친다 | 원래 의도한 안전망을 복원한다. 데몬이 실제로 일하게 되므로 100ms 마다 `lru_list->mutex` 를 잡는 구간(`:9614`)이 새로 생긴다 — 저활동 구간 한정이지만 회귀 측정이 필요하다 |
| 2 | 두 경로를 제거한다 (`pgbuf_direct_victims_maintenance`, `pgbuf_lfcq_assign_direct_victims`, `pgbuf_panic_assign_direct_victims_from_lru`, `:9402-9409` 의 hack 블록, `PSTAT_PB_VICTIM_ASSIGN_DIRECT_PANIC`) | 지금 동작과 코드가 일치하고 항상 0 인 통계 항목이 사라진다. `:8162-8166` TODO 가 지적한 취약점은 미해결로 남으므로 별도 대책이 필요하다 |

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 수정 대상은 `src/storage/page_buffer.c` 한 파일이고, 관련 코드는 전부 `#if defined (SERVER_MODE)` 구획(`:9486-9638`) 안에 있어 standalone (SA_MODE) 빌드와 클라이언트 라이브러리는 영향받지 않는다. 디스크 형식과 외부 interface 변경은 없다. 다만 `Num_victim_assign_direct_panic` (`src/base/perf_monitor.c:510`) 은 후보 1 에서는 0 이 아닌 값을 내기 시작하고 후보 2 에서는 항목 자체가 없어지므로, `cubrid statdump` 출력을 파싱하는 모니터링이 있으면 함께 확인해야 한다.

------------------------------------------------------------------------

## Description

부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유한 결함은 그 본문의 D3 와 N3 이다.

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 는 새 page 를 올릴 자리가 필요할 때 victim (재사용할 수 있는 frame) 을 찾는다. 자리를 못 찾은 스레드는 대기 큐에 들어가고, 다른 주체가 BCB (Buffer Control Block — frame 에 올라온 page 의 fix 수, latch, dirty 상태를 담은 제어 블록) 를 직접 넘겨주며 깨워준다. 이 방식이 direct victim 이고, 평상시 공급자는 flush 데몬이다 (`pgbuf_allocate_bcb` 가 대기 전에 `:8252` 에서 flush 데몬을 깨우고, flush 를 마친 page 는 `pgbuf_assign_flushed_pages` 가 대기 스레드에게 배정한다).

flush 데몬이 아무것도 내놓지 못하는 구간을 위한 두 번째 공급 경로가 `pgbuf_direct_victims_maintenance` 다. 함수 헤더 주석(`:9553-9561`)이 목적을 명시한다 — "the purpose of function is to make sure a victim is assigned even when system has low to no activity, which prevents bcb's from being assigned to a waiting thread. basically, this is the backup plan." 그 백업 플랜이 한 번도 실행되지 않는다.

### 두 경로가 죽은 방식

```
[100ms 주기] pgbuf_page_maintenance_daemon_init (looper 100ms)   :17113
  pgbuf_page_maintenance_execute                                 :16953
    ├ pgbuf_adjust_quotas                                        (정상 동작)
    └ pgbuf_direct_victims_maintenance                           :9563
         ├ private 순회 index = prv_index / 조건 index != prv_index
         │    ★ 첫 평가에서 거짓 -> 본문 0 회                     :9576-9581
         └ shared  순회 index = shr_index / 조건 index != shr_index
              ★ 동일                                             :9585-9590
         (본문) pgbuf_lfcq_assign_direct_victims                  :9580, :9589
                  └ pgbuf_panic_assign_direct_victims_from_lru    :9616, :9631
                       -> 호출 자체가 일어나지 않음

[victim 탐색 중] pgbuf_get_victim_from_lru_list
  pgbuf_remove_from_lru_list (bufptr, lru_list)                  :9400
    └ bufptr->prev_BCB = NULL                                   :10349
  pgbuf_panic_assign_direct_victims_from_lru (.., bufptr->prev_BCB)
    ★ bcb_start == NULL 이라 즉시 return 0                :9407 -> :9505
```

순회 쪽은 초기화와 조건이 서로 모순이다. `index` 를 `prv_index` 로 초기화한 뒤 `index != prv_index` 를 요구하므로 첫 평가에서 끝난다. 종료 조건은 이미 `restarted` (마지막 인덱스에서 0 으로 되돌아갈 때 참이 되는 표시) 가 담당하고 있어서, 원래 의도는 "재시작한 뒤에 시작점을 다시 만나면 멈춘다" 였을 것이다. 즉 조건이 `index != prv_index` 가 아니라 `!(index == prv_index && restarted)` 여야 앞뒤가 맞는다.

호출부 쪽은 인자 수명 문제다. `pgbuf_remove_from_lru_list` 는 BCB 를 LRU (Least Recently Used — 최근 사용 시점을 기준으로 교체 대상을 고르는 목록) 에서 떼어내면서 `prev_BCB` 와 `next_BCB` 를 NULL 로 지운다(`:10349-10350`). 그 다음 줄의 hack 블록(`:9402-9409`)이 방금 지워진 `bufptr->prev_BCB` 를 긴급 배정 함수의 시작점으로 넘기니, 함수는 `bcb_start == NULL` 가드에서 바로 0 을 반환한다. 이웃 포인터를 쓰려면 리스트 이탈 전에 저장해야 하는데, 같은 함수가 `:9397` 에서 이미 `bufptr->prev_BCB` 로 victim hint 를 갱신하고 있어 저장 지점 자체는 어렵지 않다.

두 결함이 겹치면서 `pgbuf_panic_assign_direct_victims_from_lru` 는 도달 가능한 모든 경로에서 0 을 반환하고, 그 안의 성능 통계 증가(`:9543`)도 실행되지 않는다. 함수에 붙은 `/* statistics shows not useful */` (`:9503`) 주석은 이런 상태에서 관측된 것이라 근거로 삼기 어렵다.

### 왜 오래 잠복했는가

평상시에는 flush 데몬이 victim 을 계속 만들어내므로 백업 경로가 없어도 대기 스레드가 깨어난다. 백업 경로의 부재가 드러나는 조건은 flush 데몬이 내보낼 page 를 찾지 못하거나 깨어나지 못한 상태에서 victim 요구가 들어오는 경우로, 재현이 어렵고 발생해도 5분 timeout 뒤의 실패로만 관측된다. `:8162-8166` TODO 는 "right now, after we added the victim rich hack, this may not happen" 라고 적고 있지만, 그 hack 의 판정값인 `pgbuf_Pool.monitor.victim_rich` 는 `:14446` 에서 계산될 뿐 소비처가 없다 (EPIC 의 N9, 죽은 코드 정리 이슈 범위). 결과적으로 TODO 가 근거로 든 완화 장치도 실체가 없다.

## Test Build

`CUBRID develop e6ed61e87` (소스 빌드). 확인 환경은 Fedora 44 / GCC 16.1.1 이지만, 아래 확인 절차는 소스 정독과 별도 C 프로그램 실행이라 OS·컴파일러에 의존하지 않는다.

## Repro

1~3 단계는 소스만으로 확정되는 정적 확인, 4 단계는 순회 조건만 떼어낸 실행 확인, 5 단계는 운영 중 서버에서 보이는 증상이다. 1~4 단계 명령은 CUBRID 소스 최상위에서 실행한다.

```bash
# 1) 순회 조건이 첫 평가에서 거짓임을 확인한다 (index 초기값 = prv_index)
sed -n '9572,9591p' src/storage/page_buffer.c

# 2) 순회 본문이 두 함수의 유일한 호출부임을 확인한다 (9580, 9589 뿐)
grep -n 'pgbuf_lfcq_assign_direct_victims\|PSTAT_PB_VICTIM_ASSIGN_DIRECT_PANIC' src/storage/page_buffer.c

# 3) 남은 호출부가 NULL 을 넘기는 것을 확인한다
sed -n '9398,9409p' src/storage/page_buffer.c    # remove_from_lru_list 직후 prev_BCB 전달
sed -n '10347,10351p' src/storage/page_buffer.c  # prev_BCB = NULL
sed -n '9505,9508p' src/storage/page_buffer.c    # bcb_start == NULL -> return 0
```

```bash
# 4) 순회 형태만 떼어내 본문 실행 횟수를 센다 (DB 불필요)
cat > /tmp/pgbuf_loop.c <<'EOF'
#include <stdio.h>
#define PGBUF_PRIVATE_LRU_COUNT 8	/* 임의의 양수 */
int
main (void)
{
  int nassigns = 5, body_executed = 0, index, restarted;
  static int prv_index = 0;

  for (index = prv_index, restarted = 0;
       nassigns > 0 && index != prv_index && !restarted;
       (index == PGBUF_PRIVATE_LRU_COUNT - 1) ? index = 0, restarted = 1 : index++)
    {
      body_executed++;
    }
  printf ("body executed %d times\n", body_executed);
  return 0;
}
EOF
gcc -Wall -o /tmp/pgbuf_loop /tmp/pgbuf_loop.c && /tmp/pgbuf_loop
```

```bash
# 5) 실행 중 서버에서 긴급 배정 통계를 확인한다 (부하 종류와 시간에 무관하다)
cubrid statdump -c -s victim_assign demodb
```

## Expected Result

- 4 단계: 순회는 시작점부터 한 바퀴를 돌아야 하므로 본문 실행 횟수가 1 이상이다.
- 5 단계: victim 고갈 구간이 있었다면 `Num_victim_assign_direct_panic` 이 0 보다 크다.
- victim 공급이 끊긴 구간에서도 100ms 안에 다음 유지보수 주기가 대기 스레드에게 BCB 를 배정하므로, `page_latch_timeout_in_msecs` 를 다 소진하는 대기가 생기지 않는다.

## Actual Result

- 4 단계 출력은 `body executed 0 times` 다. private/shared 순회 모두 같은 형태이므로 `pgbuf_direct_victims_maintenance` 는 100ms 마다 호출되면서도 아무 일도 하지 않는다.
- 5 단계의 `Num_victim_assign_direct_panic` 은 항상 0 이다. 증가 지점(`:9543`)에 도달하는 경로가 없다.
- victim 공급이 끊기면 대기 스레드는 `:8256` 의 timeout 대기를 그대로 소진한다. release 빌드는 `ER_CSS_PTHREAD_COND_TIMEDOUT`, debug 빌드는 `:8292` assert 실패로 끝난다.

## Additional Information

### 후보 조건별 순회 궤적

`PGBUF_PRIVATE_LRU_COUNT` 가 8, 시작점이 3 일 때 각 조건이 방문하는 인덱스와 다음 호출의 시작점이다 (위 4 단계 프로그램의 조건만 바꿔 확인).

| 조건 | 방문 인덱스 | 다음 시작점 |
|---|---|---|
| 현행 `index != prv_index && !restarted` | 없음 | 3 |
| `!restarted` (둘째 항 제거) | 3 4 5 6 7 | 0 |
| `!(index == prv_index && restarted)` | 3 4 5 6 7 0 1 2 | 3 |

둘째 항만 제거하는 쪽은 호출당 부분 순회에 그치지만 라운드로빈 위치가 계속 전진하고, 셋째 안은 호출마다 한 바퀴를 돌되 `nassigns` 가 남아 있으면 시작점이 고정된다. 어느 의미를 택할지는 목표 동작 결정과 함께 정한다.

### 관련 이슈

- 부모 EPIC: CBRD-27193 (page buffer 안정성 개선). 이 이슈는 그 표의 A3 항목이다.
- `monitor.victim_rich` 미소비와 `:9046-9053` 주석 불일치는 죽은 코드 정리 이슈(EPIC 의 B4)에서 다룬다. 여기서는 근거로만 인용한다.
- direct victim 대기 큐 크기 상수 검증은 CBRD-27211 에서 별도로 진행한다.

### 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:9563-9594` | `pgbuf_direct_victims_maintenance` — 두 순회 |
| `page_buffer.c:9605-9637` | `pgbuf_lfcq_assign_direct_victims` — hint 기반 정상 호출 경로 |
| `page_buffer.c:9496-9551` | `pgbuf_panic_assign_direct_victims_from_lru` — NULL 가드와 통계 |
| `page_buffer.c:9397-9409` | victim 탐색 중의 hack 호출부 |
| `page_buffer.c:10306-10358` | `pgbuf_remove_from_lru_list` — 이웃 포인터 초기화 |
| `page_buffer.c:8194-8302` | 대기 스레드 등록과 timeout 처리 |
| `page_buffer.c:17104-17117` | `pgbuf-maintain` 데몬 등록 (100ms) |
