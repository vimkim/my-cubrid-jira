# [OOS] 동시 OOS INSERT가 할당 직후의 빈 OOS 페이지를 서로 노리다 버퍼 프레임이 LRU 밖에 버려져, 버퍼가 고갈되고 INSERT가 300초씩 멈춘다 (shell_long bug_3627)

**한 줄 요약**: QA shell_long `bug_3627` 이 OOS 머지(`68a9c7766`, PR #7990) 이후 33~47분에서 15.5시간으로 늘어난 원인을 추적한 결과, OOS INSERT가 새로 할당한 페이지를 채우기 전에 빈 페이지로 bestspace에 알리고, 다른 INSERT가 그 페이지를 조건부 latch로 노리다 거절되면서 버퍼 프레임(BCB)이 LRU 목록 밖에 버려지는 것을 확인했다. 버려진 프레임이 쌓여 버퍼 풀이 고갈되고, 빈 버퍼나 latch를 300초씩 기다리다 트랜잭션이 철회된다. 이 이슈는 OOS 쪽 원인을 없애 동시 OOS INSERT가 버퍼를 고갈시키지 않게 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 여러 세션이 큰 값을 동시에 INSERT해도 OOS 페이지의 버퍼 프레임이 LRU 목록으로 돌아가고, INSERT가 OOS 이전 develop과 비슷한 시간에 예외 없이 끝난다.

**이슈 수행 이유**: OOS INSERT는 새 OOS 페이지를 할당하면, 그 페이지에 chunk를 쓰기 전에 그 페이지를 "빈 공간이 페이지 전체"인 후보로 공유 bestspace 캐시에 넣는다. 다른 INSERT는 이 후보를 보고 조건부 WRITE latch로 그 페이지를 잡으려 하지만, 할당한 스레드가 latch를 쥐고 있으므로 거절된다. page buffer는 거절된 조건부 요청에도 "대기자 있음"(`waiter_exists`) 표시를 남기고, 할당한 스레드가 페이지를 놓을 때 이 표시를 보고 그 프레임을 LRU 목록에 넣는 처리를 건너뛴다. 할당 직후의 프레임은 아직 어느 LRU 목록에도 없는 VOID 영역에 있으므로, 그대로 어느 목록에도 속하지 않는 프레임이 된다. 이런 프레임은 flush daemon이 찾지 못하고 다른 페이지에 다시 쓸 수도 없다. develop `bfb59bdd13` release 빌드에서 재현했고, page buffer 쪽 표시만 고친 실험 빌드에서는 같은 재현이 사라졌다.

**영향**: 큰 가변 길이 값을 여러 세션이 동시에 INSERT하는 사용자가 겪는다. 버려진 프레임이 버퍼 풀의 절반 이상을 차지하면, 새 페이지를 읽거나 할당할 버퍼를 얻지 못해 300초 뒤 `-1123`(`pthread_cond_timedwait() timed out`)으로 실패하고, 그 사이 latch를 기다리던 트랜잭션은 `-72`(unilaterally aborted)로 철회된다. QA bug_3627은 insert 단계가 15.5시간 걸렸고, 같은 고갈 상태에서 vacuum이 OOS 회수 중 `-1123` 을 받아 서버가 FATAL로 종료했다(CBRD-28377). 로컬 비교에서 insert 단계는 OOS 이전 develop이 375초에 예외 없이 끝났고, `bfb59bdd13` 은 1188초 걸리며 10개 세션 중 9개가 예외로 끝났다. 버려진 프레임은 누군가 그 페이지를 다시 fix하기 전에는 돌아오지 않으므로, 동시 INSERT가 계속되면 버퍼 풀이 계속 줄어 같은 서버의 다른 작업도 함께 멈춘다. 운영 환경에서의 발생 빈도는 알 수 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 원인 (develop `bfb59bdd13` 기준)

1. **OOS: 채우기 전의 새 페이지를 빈 페이지로 알린다.** `oos_find_best_page ()` 는 쓸 만한 페이지를 찾지 못하면 `oos_alloc_page_with_reclaim ()` 으로 새 페이지를 할당하고, WRITE latch를 쥔 채로 그 페이지의 현재 빈 공간(페이지 전체)을 `oos_stats_add_bestspace ()` 로 공유 캐시에 넣은 뒤 돌려준다([oos_file.cpp:3298-3309](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/oos_file.cpp#L3298-L3309)). 호출자는 곧바로 그 페이지에 chunk를 쓰므로 그 빈 공간은 남지 않는다. 그 사이 다른 INSERT의 `oos_stats_find_page_in_bestspace ()` 는 이 후보를 골라 조건부 WRITE latch로 fix를 시도한다(Phase C, [oos_file.cpp:683-686](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/oos_file.cpp#L683-L686)). 페이지는 할당한 스레드가 쥐고 있으므로 이 시도는 거절된다.
2. **page buffer: 거절된 조건부 요청이 `waiter_exists` 를 남긴다.** `pgbuf_latch_bcb_upon_fix ()` 는 latch를 쥐지 않은 요청이면 조건부 요청이라도 CAS로 `waiter_exists = true` 를 먼저 기록하고([page_buffer.c:7117-7120](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7117-L7120)), 그다음 조건부 요청을 거절한다([7234-7264](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7234-L7264)). 거절할 때 이 표시를 지우지 않는다. CBRD-28163 수정(`3f48168311`)도 커밋 설명에서 이 출처를 그대로 두었다고 적었다.
3. **page buffer: 놓을 때 표시가 있으면 LRU 배치를 건너뛴다.** `pgbuf_unlatch_bcb_upon_unfix ()` 는 fix 수가 0이 될 때 `waiter_exists` 가 서 있으면 영역별 처리 전체를 건너뛰고 깨우기만 한다([page_buffer.c:7357](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7357), [7399-7528](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7399-L7528)). 실제 대기자가 있으면 그 대기자가 나중에 놓을 때 처리하지만, 거절된 조건부 요청은 기다리지 않으므로 아무도 처리하지 않는다. 프레임이 이미 LRU 목록에 있으면 영향이 작다(승격만 빠진다). 그러나 할당하거나 디스크에서 막 읽어 아직 VOID 영역([page_buffer.c:207-209](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L207-L209))에 있던 프레임은 어느 목록에도 들어가지 않는다.

2와 3은 CBRD-26425(`58cef8e01f`, 2026-01, 원자 latch 도입)부터 develop에 있는 page buffer 동작이다. OOS 이전 develop에서는 VOID 영역의 페이지를 다른 스레드가 조건부로 노리는 경로가 드물어 드러나지 않았고, OOS의 1번 동작이 이를 INSERT마다 일으킨다. page buffer 쪽 결함은 OOS와 무관하게 남으므로 [CBRD-28379](https://jira.cubrid.org/browse/CBRD-28379)에서 따로 다룬다.

### 확인한 근거

- **버려진 프레임**: bug_3627 재현 중 멈춘 `bfb59bdd13` 서버를 gdb로 보니 6400개 프레임 중 2966개(잠시 뒤 3049개)가 VOID 영역에 있었고 모두 `PAGE_OOS` 였다. 모두 latch 없음(fix 수 0)이고 LRU 연결(prev/next)이 없었으며, 1044개는 dirty였다. 같은 때 statdump는 `Num_data_page_victim_candidate = 1`, `Num_data_page_lru3 = 1` 이었고, QA 로그처럼 flush daemon이 `Flush victim candidates of page buffer finished (count: 0)` 를 반복했다.
- **스레드 상태**: 여러 INSERT 스레드가 OOS 헤더 페이지와 OOS 파일 헤더 페이지의 latch를 300초 기다리다 시간 초과로 끝났고, 한 스레드는 OOS 페이지 할당(`file_alloc`)이 빈 버퍼를 얻지 못해 실패한 뒤 롤백하고 있었다. 버퍼 고갈이 헤더 페이지의 latch 대기열로 번진 것이다.
- **거절된 조건부 요청의 출처**: 아래 작은 재현을 page buffer 실험 패치 빌드에서 돌리며, 조건부 요청이 거절되는 줄([page_buffer.c](https://github.com/CUBRID/cubrid/blob/bfb59bdd133518da140f9af6c48bef5568df67af/src/storage/page_buffer.c#L7234-L7264) 의 비대기 분기)에 gdb breakpoint를 걸어 호출 경로를 셌다. 400행 INSERT 동안 거절 5115회 중 5114회가 `oos_stats_find_page_in_bestspace ()` 의 Phase C(oos_file.cpp:685)였고, 5114회 모두 대상이 VOID 영역의 `PAGE_OOS` 프레임이었다.
- **실험 패치**: `pgbuf_latch_bcb_upon_fix ()` 에서 조건부 요청은 `waiter_exists` 를 기록하지 않게 한 두 줄 실험 빌드(develop `bfb59bdd13` 기준, 커밋하지 않음)에서 작은 재현의 VOID 프레임이 0개가 되었다. 수정 방안으로 정한 것은 아니다.

## Test Build

- develop `bfb59bdd13`, release 빌드(CMake preset `release_gcc`, RelWithDebInfo), Linux. 비교 기준은 OOS 이전 develop `a7f220d5d7` release 빌드다.
- 장비 부하가 높은 상태(load average 약 270, 80코어)에서 쟀으므로 절대 시간보다 두 빌드의 비교가 의미 있다.

## Repro

### 1. bug_3627 insert 단계

CBRD-26357에 첨부된 `repro_bug_3627_insert.sh` 와 같은 절차다(data_buffer_size=100m, DB 20m + DATA 100m×4 + INDEX 50m, `create table aoo (a integer primary key, b bit varying) reuse_oid`, T 테이블 40만 행 적재 후 `java blob_cubrid 4 1 50000 5000 100 10 200`: 10개 세션이 200KB 값을 5,000건씩, 100건마다 commit). 로컬 실행에서는 broker의 CAS 수를 10개 이상으로 두었다.

| 빌드 | insert 단계 | 세션 종료 시각 | JDBC 예외 |
|---|---|---|---|
| `a7f220d5d7`(OOS 이전) | 375초 | 358~364초, 10개 모두 정상 | 0 |
| `bfb59bdd13` | 1188초 | 481~1180초 | 9(`-1123` 2, `-72` 7) |
| `bfb59bdd13` + page buffer 실험 패치 | 180초 | 162~164초, 10개 모두 정상 | 0 |

`a7f220d5d7` 과 `bfb59bdd13` 은 T 테이블을 행마다 commit하며 적재했고, 실험 패치 빌드는 시간을 줄이려 한 트랜잭션으로 적재했다. 적재 방식이 달라 insert 단계 시간을 그대로 비교하지는 않는다. 비교할 것은 예외와 멈춤의 유무다.

### 2. 작은 재현 (수 초)

```bash
db=voidc
cat >> $CUBRID/conf/cubrid.conf <<EOF

[@$db]
data_buffer_size=16m
enable_string_compression=n
EOF
cubrid createdb $db en_US
cubrid server start $db
csql -u dba -c "create table t (a int primary key, b varchar)" $db
for j in $(seq 1 10); do
  for i in $(seq 1 40); do echo "insert into t values ($((j*10000+i)), repeat('y', 204800));"; done > c$j.sql
done
for j in $(seq 1 10); do csql -u dba -i c$j.sql $db > c$j.log 2>&1 & done; wait
grep -c "row affected" c*.log
```

VOID 영역의 프레임 수는 gdb로 `pgbuf_Pool.BCB_table[i].flags` 의 영역 비트(`PGBUF_VOID_ZONE`)를 세어 확인했다.

## Expected Result

- 400행이 모두 들어가고, VOID 영역에 남는 OOS 프레임이 없다.
- bug_3627 insert 단계가 OOS 이전 develop과 비슷한 시간에 예외 없이 끝난다.

## Actual Result

| 빌드 | 결과 | VOID 영역 프레임(1024개 중) |
|---|---|---|
| `bfb59bdd13` | 400행 중 103행에서 멈춤(195초 뒤 중단) | 938(모두 `PAGE_OOS`) |
| `bfb59bdd13` + page buffer 실험 패치 | 400행, 0.59초 | 0 |

단일 세션으로 200행을 넣으면 `bfb59bdd13` 에서도 VOID 프레임이 생기지 않는다. 동시 INSERT가 있어야 난다.

## Additional Information

- **ANALYSIS 확인 사항**
    1. OOS 쪽: 새 페이지를 chunk를 쓴 뒤의 빈 공간으로만 알리거나, latch를 놓은 뒤에 알리는지. 새 페이지 후보를 알리지 않을 때 단일 페이지 값의 페이지 공유가 줄어드는지.
    2. page buffer 쪽: 거절된 조건부 요청이 `waiter_exists` 를 남기지 않게 하거나, 표시가 있어도 VOID 영역 프레임은 LRU에 넣는지. OOS와 무관한 develop 결함이므로 CBRD-28379에서 다룬다. 그 이슈에서 heap bestspace 등 다른 조건부 fix 경로도 같은 누수를 낼 수 있는지 함께 본다(위 집계에서 heap bestspace의 거절 1회는 LRU 영역 프레임이었다).
    3. QA의 15.5시간은 버려진 프레임이 쌓이는 동안 latch·버퍼 대기가 300초 단위로 반복된 결과로 본다. 1번만 고친 빌드와 2번만 고친 빌드에서 bug_3627 전체 시간을 각각 확인한다.
- **관련**: CBRD-28379(page buffer 쪽 결함), CBRD-28377(같은 고갈 상태에서 vacuum의 OOS 회수 fail-stop), CBRD-28163(latch 대기 시간 초과 뒤 남는 `waiter_exists`, 조건부 요청 출처는 제외), CBRD-28226·CBRD-28244(병렬 정렬의 다른 경로에서 VOID 영역 누수, 해결됨), CBRD-28278(OOS INSERT의 latch 비용 묶음).
