# [Regression] 거절된 조건부 페이지 latch 요청이 waiter_exists 를 남겨, 막 할당하거나 읽은 버퍼 프레임이 LRU 목록에 들어가지 못하고 버퍼 풀에서 사라진다

**한 줄 요약**: shell_long `bug_3627` 의 OOS INSERT 정체(CBRD-28378)를 추적하다 찾은 page buffer 결함이다. 조건부 latch 요청(`PGBUF_CONDITIONAL_LATCH`)이 거절될 때 "대기자 있음" 표시(`waiter_exists`)를 남기고, latch를 쥔 스레드는 페이지를 놓으며 이 표시를 보고 프레임을 LRU 목록에 넣는 처리를 건너뛴다. 막 할당하거나 디스크에서 읽어 아직 LRU 목록 밖(VOID 영역)에 있던 프레임은 그대로 어느 목록에도 속하지 않게 되어 flush도 재사용도 되지 않는다. 이 이슈는 거절된 조건부 요청이 버퍼 프레임을 잃게 하지 않도록 바로잡는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 조건부 latch 요청이 거절되어도 버퍼 프레임은 latch를 쥔 스레드가 놓을 때 LRU 목록으로 돌아간다. 버퍼 풀의 크기가 경합 때문에 줄지 않는다.

**이슈 수행 이유**: CBRD-26425(`58cef8e01f`, 원자 latch)는 "기다리는 스레드가 있는가"의 판정을 BCB 대기열을 훑는 `pgbuf_is_exist_blocked_reader_writer ()` 에서 latch 값의 `waiter_exists` 비트로 바꿨다. 그런데 `pgbuf_latch_bcb_upon_fix ()` 는 조건부 요청도 기다릴 요청처럼 먼저 이 비트를 세우고, 그 뒤 기다리지 않고 거절한다. 기다리는 스레드가 없는데 비트가 남는다. `pgbuf_unlatch_bcb_upon_unfix ()` 는 fix 수가 0이 될 때 이 비트가 서 있으면 영역별 처리(LRU 배치·승격)를 통째로 건너뛰므로, VOID 영역의 프레임은 LRU에 들어가지 못한다. CBRD-26425 전에는 대기열을 직접 훑었으므로 기다리지 않은 조건부 요청이 배치를 막지 않았다(코드 비교). CBRD-28163 수정(`3f48168311`)은 latch 대기 시간 초과 뒤에 남는 비트를 지웠고, 커밋 설명에서 조건부 요청이 남기는 비트는 그대로 두었다고 적었다.

**영향**: 경합이 있는 페이지를 조건부로 잡는 코드(빈 공간 탐색, vacuum, 회수 등)가 다른 스레드가 막 할당하거나 읽은 페이지를 노리면, 그 프레임이 버퍼 풀에서 빠진다. 빠진 프레임은 누군가 그 페이지를 다시 fix하기 전에는 돌아오지 않는다. 쌓이면 flush daemon이 내보낼 후보를 찾지 못하고, 빈 버퍼를 기다리는 스레드가 300초 뒤 `-1123` 으로 실패하며, latch 대기가 번져 `-72` 철회와 서버 FATAL(CBRD-28377)로 이어진다. OOS INSERT에서는 동시 INSERT 10개로 수 초 만에 버퍼 풀 1024개 프레임 중 938개가 빠졌다(CBRD-28378). OOS를 쓰지 않는 경로에서 얼마나 자주 나는지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 원인 (develop `bfb59bdd13` 기준)

- `pgbuf_latch_bcb_upon_fix ()` 는 latch를 쥐지 않은 요청이면 조건부 여부와 관계없이 CAS로 `waiter_exists = true` 를 기록한다([page_buffer.c:7117-7120](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7117-L7120)). READ를 쥔 holder의 조건부 WRITE 승격 실패도 같다([7099-7104](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7099-L7104)). 그 뒤 조건부 요청은 비트를 지우지 않고 `ER_FAILED` 로 돌아간다([7234-7264](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7234-L7264)).
- `pgbuf_unlatch_bcb_upon_unfix ()` 는 `blocked_reader_writer = waiter_exists` 로 읽고([7357](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7357)), fix 수가 0이 될 때 이 값이 참이면 VOID 영역 프레임을 LRU에 넣는 `pgbuf_unlatch_void_zone_bcb ()` 를 포함한 영역별 처리를 건너뛴다([7399-7528](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7399-L7528)).
- VOID 영역은 디스크에서 읽은 직후 LRU에 넣기 전, 또는 LRU에서 뺀 뒤 재사용하기 전의 임시 영역이다([page_buffer.c:207-209](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L207-L209)). 이 영역의 프레임은 LRU 목록에 없으므로 flush daemon의 victim 후보 수집(`pgbuf_flush_victim_candidates ()`)과 재사용 대상 탐색에서 보이지 않는다.

### 확인한 근거

CBRD-28378의 작은 재현(16MB 버퍼, 10개 세션이 200KB 값을 40건씩 INSERT)에서 확인했다.

| 빌드 | 결과 | VOID 영역 프레임(1024개 중) |
|---|---|---|
| develop `bfb59bdd13` release | 400행 중 103행에서 멈춤 | 938, 모두 latch 없음(fix 수 0)·LRU 연결 없음 |
| 같은 빌드 + 조건부 요청은 `waiter_exists` 를 세우지 않는 두 줄 실험 패치 | 400행, 0.59초 | 0 |

실험 패치 빌드에서 거절된 조건부 요청을 gdb로 세면 400행 동안 5115회였고, 그중 5114회는 OOS 빈 공간 탐색이 VOID 영역 프레임을 노린 것이었다. 실험 패치는 원인 확인용이며 수정 방안으로 정한 것은 아니다. shell_long `bug_3627` insert 단계도 실험 패치 빌드에서는 10개 세션이 예외 없이 끝났다(`bfb59bdd13` 은 9개 세션이 `-1123`·`-72` 로 끝남).

## Test Build

- develop `bfb59bdd13`, release 빌드(CMake preset `release_gcc`), Linux.

## Expected Result

- 조건부 latch 요청이 거절되어도, latch를 쥔 스레드가 페이지를 놓으면 그 프레임은 LRU 목록에 들어간다.

## Actual Result

- 거절된 조건부 요청이 남긴 `waiter_exists` 때문에 VOID 영역 프레임이 어느 LRU 목록에도 들어가지 않고 버퍼 풀에서 빠진다.

## Additional Information

- **ANALYSIS 확인 사항**
    1. 조건부 요청이 `waiter_exists` 를 세우지 않게 할지, 표시가 서 있어도 VOID 영역 프레임은 LRU에 넣을지, 또는 깨우기 처리 뒤 실제 대기자가 없으면 영역 처리를 할지. 앞의 것은 거절 때마다 남는 표시가 다른 READ 요청을 막는 문제(CBRD-28163에서 설명한 READ 차단)도 함께 없앤다.
    2. OOS 외의 조건부 fix 경로(heap 빈 공간 탐색, vacuum, B-tree 등)가 VOID 영역 프레임을 노리는 빈도. CBRD-28378의 집계에서는 heap 빈 공간 탐색의 거절 1회가 LRU 영역 프레임이었다.
    3. 이미 빠진 프레임을 statdump로 보이게 할지(현재 `Num_data_page_lru1/2/3` 합이 버퍼 수보다 작아지는 것으로만 드러난다).
- **관련**: CBRD-28163(latch 대기 시간 초과 뒤 남는 `waiter_exists`), CBRD-27084(flush 대기자 뒤의 `waiter_exists`), CBRD-28226·CBRD-28244(병렬 정렬의 다른 경로에서 VOID 영역 누수, 해결됨), CBRD-28378(OOS INSERT에서의 발현), CBRD-28377(같은 버퍼 고갈에서 vacuum fail-stop).
