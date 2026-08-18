# [PGBUF] lock-free fix 경로의 dealloc 보호 카운터 비대칭을 수정한다

## Issue Triage

**이슈 수행 목적**: `OLD_PAGE_PREVENT_DEALLOC` fix 한 건이 dealloc 보호 카운터에 남기는 순증감을 항상 0 으로 만든다. 등록과 해제가 `pgbuf_fix` 와 `pgbuf_ordered_fix` 두 함수에 나뉘어 있는 지금 구조를 한쪽이 책임지도록 정리한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `pgbuf_fix` 의 lock-free 빠른 경로가 dealloc 보호 카운터 등록(`page_buffer.c:2425-2428`)을 건너뛴 채 해제(`:2513-2517`)만 실행한다. 이 경로에는 `pgbuf_ordered_fix` 의 1차 시도(`:12292-12296`)가 원본 fetch mode 를 그대로 넘기면서 도달한다. 요청 page 보호의 등록·해제가 두 함수에 흩어져 있어 같은 성질의 짝 깨짐이 오류 경로 2 곳에 더 있고, 결국 진입 상황 5 가지 중 3 가지에서 순증감이 0 이 아니다. |
| **TO-BE (목표 상태 / 기대 동작)** | `OLD_PAGE_PREVENT_DEALLOC` 요청 한 건이 성공하든 실패하든, 어느 경로로 들어오든 `count_fix_and_avoid_dealloc` 하위 16 비트에 남기는 순증감이 0 이다. |
| **영향** | 고객 장애 가능성 — 감소가 남으면 vacuum 이 보호 중인 empty heap page 를 회수하고(`vacuum.c:1850`, `heap_file.c:3383`), 그 page 를 다시 fix 하던 스레드가 `pgbuf_ordered_fix` 의 `page was deallocated an we told it not to!` 경로(`:12816-12819`, debug 빌드는 `assert (false)`) 로 떨어진다. 반대로 증가가 남으면 그 page 는 vacuum 의 회수 대상에서 영구히 빠진다. |

**이슈 수행 방안**: 수정 방식은 아직 정해지지 않았다 — `TBD - 합의 미확인`. 후보 세 가지와 각각의 대가는 아래 Additional Information 의 비교 표에 정리했다. 어느 쪽을 골라도 판정 기준은 위 TO-BE 한 줄이며, 아래 회계 표의 5 가지 진입 상황이 모두 0 이 되어야 한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c` 의 `pgbuf_fix` (`:2207-2636`), `pgbuf_lockfree_fix_ro` (`:7671-7734`), `pgbuf_ordered_fix` (`:12206-13001`) 세 함수. 디스크 형식, 설정, 공개 함수 시그니처는 그대로다. 호출부 수정은 없다 — `OLD_PAGE_PREVENT_DEALLOC` 사용처 10 곳은 전부 `pgbuf_ordered_fix` 를 거치므로 fix 계약 자체는 변하지 않는다. `count_fix_and_avoid_dealloc` (`:535-540`) 은 상위 16 비트가 hot page 판정용 fix 횟수, 하위 16 비트가 dealloc 보호 수인 2 용도 필드이고(`:267-269`), 이 이슈는 하위 16 비트만 다룬다. 이 이슈는 부모 EPIC CBRD-27193 의 결함 N1 을 소유한다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

---

## Description

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 에는 "이 page 를 지금 쓰고 있으니 해제하지 말라" 는 표시가 있다. fetch mode `OLD_PAGE_PREVENT_DEALLOC` 로 fix 하면 BCB (Buffer Control Block — frame 에 올라온 page 의 fix 수, latch 상태, dirty 여부를 보관하는 제어 블록) 의 `count_fix_and_avoid_dealloc` 하위 16 비트가 1 늘고, latch (page 단위 짧은 읽기/쓰기 잠금) 를 얻은 뒤 다시 1 줄어든다. latch 를 잡기 전 구간, 즉 표시가 실제로 필요한 구간만 보호하는 설계다.

소비자는 vacuum (MVCC 에서 더 이상 보이지 않는 레코드 버전을 정리하는 백그라운드 작업) 쪽 두 곳이다.

    vacuum_heap_page ()                                       vacuum.c:1581
      └ 레코드가 1 개 이하로 남은 heap page 를 회수 후보로 본다
           ├ pgbuf_has_prevent_dealloc (home_page) == false    vacuum.c:1850
           └ heap_remove_page_on_vacuum ()
                ├ 필요한 latch 를 모두 잡은 뒤 재확인            heap_file.c:3383
                └ 두 확인이 모두 false 면 heap 파일에서 page 를 떼어낸다
    ★ 보호 카운트가 0 으로 보이면 vacuum 은 회수해도 된다고 판단한다

### 요청 page 의 보호는 두 함수가 나눠 맡는다

이 fetch mode 를 외부에서 `pgbuf_fix` 로 직접 넘기는 호출부는 트리 전체에 하나도 없다. 전부 `pgbuf_ordered_fix` (heap page 여러 장을 데드락 없이 잡도록 전역 순서에 따라 latch 를 재배열하는 fix 변형) 로 들어온다. 그런데 그 안에서 요청 page 의 보호를 걸고 푸는 주체가 상황마다 달라진다.

    pgbuf_ordered_fix (req_vpid, OLD_PAGE_PREVENT_DEALLOC, ...)          :12206
      │
      ├ latch 조건 결정: 보유 page 가 없거나 요청 page 만 보유면 무조건    :12280-12284
      │
      ├ 1차 시도: pgbuf_fix (req_vpid, fetch_mode 원본, latch 조건)       :12292-12296
      │    ├ lock-free 빠른 경로 성공 -> 등록 건너뛰고 해제만 (-1)        :2315-2328 ★
      │    ├ 일반 경로 성공 -> 등록(:2427) + 해제(:2516) = 0
      │    └ 조건부 latch 충돌로 실패 -> 등록(:2427) 만 남기고 NULL       :2440-2463
      │
      ├ fetch_mode 를 OLD_PAGE 로 재작성, has_dealloc_prevent_flag = true :12392-12396
      │    (여기부터 내부 pgbuf_fix 는 등록도 해제도 하지 않는다)
      │
      ├ 보유 page 들을 보호 등록(:12639) 후 unfix, 순서대로 재 fix
      │
      ├ 재 fix 성공 시 요청 page 해제 (-1)                    :12702 또는 :12850
      └ 재정렬 중 오류로 exit -> 요청 page 해제 없음 (+1 잔존)   :12829 -> :12946 ★

    ★ 는 짝이 깨지는 지점. exit 정리 루프(:12972-12998)는 :12639 로 등록한
      "보유 page" 분만 되돌리고, has_dealloc_prevent_flag 는 보지 않는다.

진입 상황별로 순증감을 세어 보면 5 가지 중 3 가지가 0 이 아니다.

| 진입 상황 | `:2427` 등록 | 해제 | 순증감 | 판정 |
|---|---|---|---|---|
| 1차 시도가 lock-free 빠른 경로로 성공 | 건너뜀 | `:2516` 실행 | -1 | 결함 — 남이 걸어 둔 보호를 감소 |
| 1차 시도가 일반 경로로 성공 | +1 | `:2516` | 0 | 정상 |
| 1차 시도가 조건부 latch 충돌로 실패 -> 재정렬 후 재 fix 성공 | +1 | `:12702` 또는 `:12850` | 0 | 정상, 단 두 함수에 걸친 암묵적 분담 |
| 1차 시도가 `:2427` 도달 전 실패(BCB 확보·read 오류) -> 조건부라 재정렬 진행 | 없음 | `:12702` 또는 `:12850` | -1 | 결함 — 드문 오류 경로 |
| 재정렬 도중 오류로 `exit` | +1 | 없음 | +1 | 결함 — 오류 exit 한정, 보호가 영구 잔존 |

세 번째 행이 이 코드의 유일한 안전판이다. 조건부 latch 실패로 반환할 때 `pgbuf_fix` 가 `:2427` 의 등록을 되돌리지 않고 남겨 두고(`:2440-2463`), `pgbuf_ordered_fix` 가 page 를 놓고 순서를 재정렬하는 동안 그 등록이 보호 역할을 하다가 재 fix 후 `:12702`/`:12850` 에서 풀린다. 의도된 handshake 로 보이지만 두 함수 어디에도 이 계약이 적혀 있지 않고, 그래서 나머지 세 조합이 조용히 깨져 있다.

첫 번째 행은 진입 조건이 겹치기 때문에 생긴다. `pgbuf_fix` 의 lock-free 진입 조건(`:2311-2313`)은 READ latch + `OLD_PAGE`/`OLD_PAGE_PREVENT_DEALLOC`/`OLD_PAGE_MAYBE_DEALLOCATED` + 무조건 latch 인데, `pgbuf_ordered_fix` 의 1차 시도가 원본 fetch mode 를 그대로 넘기므로(`:12292`, `:12295`) 세 조건이 동시에 성립한다. `pgbuf_lockfree_fix_ro` (`:7671-7734`) 전체에 등록 호출이 없고, 성공 시 `goto fast_path` 로 `:2425-2428` 을 건너뛴 뒤 `:2513-2517` 의 해제만 실행한다. 실제로 성립하려면 그 순간 page 가 READ latch 상태이고 fix 수가 1 이상이며 대기자가 없어야 하므로(`:7689-7693`), 같은 page 를 읽는 스레드가 이미 있거나 내가 그 page 를 이미 READ 로 들고 있는 경우다. 후자는 `:12280-12284` 의 "요청 page 만 보유" 조건과 정확히 겹친다.

네 번째와 다섯 번째 행은 오류 경로에서만 생긴다. 1차 시도가 `:2427` 에 닿기도 전에 실패했는데(예: `pgbuf_claim_bcb_for_fix` 의 read 오류) 그 오류가 `:12349` 의 `ER_PB_BAD_PAGEID`/`ER_INTERRUPTED` 필터에 걸리지 않으면, 등록이 없는 상태로 `:12392` 를 지나 해제만 실행된다. 반대로 재정렬 중 어느 page 의 재 fix 가 실패해 `:12829` 로 빠지면 요청 page 의 해제 지점에 닿지 못하는데, `exit` 정리 루프는 `ordered_holders_info[i].prevent_dealloc` 만 보고 `has_dealloc_prevent_flag` 는 보지 않으므로 `:2427` 의 +1 이 그대로 남는다. 그 page 는 이후 vacuum 의 회수 대상에서 영구히 빠진다.

### 0 방어가 막아 주지 못하는 부분

카운터가 0 이면 `pgbuf_bcb_unregister_avoid_deallocation` 의 0 방어(조건 `:16226`, else 블록 `:16230-16250`)가 감소를 막고 디버그 로그만 남기므로 값이 음수로 깨지지는 않는다. 그 안의 주석(`:16232-16244`)은 "`pgbuf_ordered_fix` 가 보유 page 를 전부 unfix 하는 동안 그 page 가 victim 이 될 수 있어 카운터 0 을 만날 수 있다" 며 그 경우를 예상된 것으로 적고, 회피 설계가 더 위험하다는 이유로 `we prefer the existing risks` 라고 위험 감수를 선언한다.

> **요지**: 그 주석이 감수하겠다고 한 것은 "내가 걸어 둔 마커가 사라진 0 케이스" 뿐이다. 이 이슈가 문제로 삼는 것은 카운터가 1 이상인 상태에서 **다른 주체(vacuum 을 막으려고 보호를 걸어 둔 스레드)의 카운트를 감소시키는** 경우이고, 이때는 0 방어가 발동하지 않으므로 주석의 감수 선언 밖이다.

### 노출 경로

`OLD_PAGE_PREVENT_DEALLOC` 사용처는 10 곳이며 전부 `pgbuf_ordered_fix` 로 수렴한다.

| 호출부 | 경유 | latch |
|---|---|---|
| `heap_file.c:7572`, `7726` (`heap_next_internal`) | `heap_scan_pb_latch_and_fetch` 의 watcher 분기 (`heap_file.c:961`) | READ |
| `heap_file.c:9375`, `14366`, `14780`, `18923`, `19022` | 같은 분기 | READ |
| `heap_file.c:17478` | 같은 분기 | WRITE |
| `heap_file.c:8979`, `locator_sr.c:12788` | `pgbuf_ordered_fix` 직접 호출 | READ / WRITE |

`heap_next_internal` 은 인덱스를 타지 않는 순차 heap scan 이라 상시 실행된다. `heap_scan_pb_latch_and_fetch` 는 watcher 가 NULL 일 때만 `pgbuf_fix` 를 직접 부르는데(`heap_file.c:973-975`), 위 호출부는 모두 watcher 를 넘기므로 그 분기로는 가지 않는다. WRITE latch 호출부는 lock-free 진입 조건을 만족하지 않아 첫 번째 행과 무관하고, 나머지 네 상황에는 그대로 해당한다.

## Test Build

`CUBRID develop e6ed61e87 (소스 빌드)`, Linux x86_64 debug 빌드.

## Repro

### 1. 등록/해제 짝이 깨지는지 계측

요청 page 의 등록 지점 1 곳과 해제 지점 3 곳에 로그를 넣어 vpid 별 순증감을 센다. 진단 전용 패치이므로 병합하지 않는다.

```bash
cd <cubrid-source-root>
cat > /tmp/probe-27263.patch <<'EOF'
--- a/src/storage/page_buffer.c
+++ b/src/storage/page_buffer.c
@@ -2226,6 +2226,7 @@
   bool buf_lock_acquired = false;
   bool is_latch_wait = false;
   bool retry = false;
+  bool lockfree_fast_path = false;	/* TEMP: CBRD-27263 instrumentation */
 #if !defined (NDEBUG)
   bool had_holder = false;
 #endif /* !NDEBUG */
@@ -2316,6 +2317,7 @@
       if (pgptr != NULL)
 	{
 	  CAST_PGPTR_TO_BFPTR (bufptr, pgptr);
+	  lockfree_fast_path = true;	/* TEMP: CBRD-27263 instrumentation */
 #if !defined (NDEBUG)
 	  pgbuf_add_fixed_at (pgbuf_find_thrd_holder (thread_p, bufptr), caller_file, caller_line, !had_holder);
 #endif
@@ -2424,6 +2426,9 @@
 
   if (fetch_mode == OLD_PAGE_PREVENT_DEALLOC)
     {
+      /* TEMP: CBRD-27263 instrumentation. never merge. */
+      _er_log_debug (ARG_FILE_LINE, "CBRD-27263 register vpid=%d|%d avoid=%d\n",
+                     VPID_AS_ARGS (&bufptr->vpid), bufptr->count_fix_and_avoid_dealloc & 0x0000FFFF);
       pgbuf_bcb_register_avoid_deallocation (bufptr);
     }
 
@@ -2513,6 +2518,10 @@
   if (fetch_mode == OLD_PAGE_PREVENT_DEALLOC)
     {
       /* latch is obtained, no need for avoidance of dealloc */
+      /* TEMP: CBRD-27263 instrumentation. never merge. */
+      _er_log_debug (ARG_FILE_LINE, "CBRD-27263 unreg-fix lockfree=%d vpid=%d|%d avoid=%d\n",
+                     (int) lockfree_fast_path, VPID_AS_ARGS (&bufptr->vpid),
+                     bufptr->count_fix_and_avoid_dealloc & 0x0000FFFF);
       pgbuf_bcb_unregister_avoid_deallocation (bufptr);
     }
 
@@ -12699,6 +12708,9 @@
 	  if (has_dealloc_prevent_flag == true)
 	    {
 	      CAST_PGPTR_TO_BFPTR (bufptr, pgptr);
+	      /* TEMP: CBRD-27263 instrumentation. never merge. */
+	      _er_log_debug (ARG_FILE_LINE, "CBRD-27263 unreg-ordered-nogroup vpid=%d|%d avoid=%d\n",
+                             VPID_AS_ARGS (&bufptr->vpid), bufptr->count_fix_and_avoid_dealloc & 0x0000FFFF);
 	      pgbuf_bcb_unregister_avoid_deallocation (bufptr);
 	      has_dealloc_prevent_flag = false;
 	    }
@@ -12847,6 +12859,9 @@
 	  if (has_dealloc_prevent_flag == true)
 	    {
 	      CAST_PGPTR_TO_BFPTR (bufptr, pgptr);
+	      /* TEMP: CBRD-27263 instrumentation. never merge. */
+	      _er_log_debug (ARG_FILE_LINE, "CBRD-27263 unreg-ordered-refix vpid=%d|%d avoid=%d\n",
+                             VPID_AS_ARGS (&bufptr->vpid), bufptr->count_fix_and_avoid_dealloc & 0x0000FFFF);
 	      pgbuf_bcb_unregister_avoid_deallocation (bufptr);
 	      has_dealloc_prevent_flag = false;
 	    }
EOF
git apply /tmp/probe-27263.patch
./build.sh -m debug
```

### 2. 순차 heap scan 부하

```bash
cubrid createdb --db-volume-size=200M --log-volume-size=100M testdb en_US.utf8
cat >> $CUBRID/conf/cubrid.conf <<'EOF'
data_buffer_size=64M
er_log_debug=yes
EOF
cubrid server start testdb

csql -S -u dba testdb -c "CREATE TABLE t (a INT PRIMARY KEY, b VARCHAR(200));"
csql -S -u dba testdb -c "
  INSERT INTO t
  SELECT ROWNUM, REPEAT('x', 200)
  FROM db_class a, db_class b LIMIT 100000;"

# 같은 테이블을 여러 세션이 동시에 순차 scan (인덱스를 타지 않도록 b 로 필터)
for i in 1 2 3 4 5 6 7 8; do
  ( for j in $(seq 1 30); do
      csql -S -u dba testdb -c "SELECT COUNT(*) FROM t WHERE b LIKE 'x%';" > /dev/null
    done ) &
done
wait
```

### 3. vpid 별 순증감 집계

```bash
grep 'CBRD-27263' $CUBRID/log/server/testdb_*.err \
  | sed -E 's/.*CBRD-27263 ([a-z-]+).*vpid=([0-9]+\|[0-9]+).*/\1 \2/' \
  | awk '{ if ($1 == "register") n[$2]++; else n[$2]--; }
         END { for (v in n) if (n[v] != 0) printf "vpid %s net %+d\n", v, n[v] }'

# 어느 해제 지점이 짝 없이 실행됐는지 분류
grep -c 'CBRD-27263 unreg-fix lockfree=1' $CUBRID/log/server/testdb_*.err
grep -c 'CBRD-27263 unreg-ordered' $CUBRID/log/server/testdb_*.err
```

`unreg-fix lockfree=1` 은 회계 표 첫 번째 행(등록 없는 해제)이 실제로 실행된 횟수다. `unreg-ordered-*` 는 세 번째 행(정상 handshake)과 네 번째 행(등록 없는 해제)이 섞여 있으므로, 같은 vpid 의 앞선 `register` 로그 유무로 갈라 본다.

### 4. 보호가 지워졌을 때의 결과 확인

```bash
csql -S -u dba testdb -c "
  CREATE TABLE u (a INT PRIMARY KEY, b VARCHAR(200));
  INSERT INTO u SELECT ROWNUM, REPEAT('y', 200) FROM db_class a, db_class b LIMIT 100000;"

# 세션 1: 순차 scan 반복
( for j in $(seq 1 200); do
    csql -S -u dba testdb -c "SELECT COUNT(*) FROM u WHERE b LIKE 'y%';" > /dev/null
  done ) &

# 세션 2: 대량 삭제로 empty heap page 를 만들어 vacuum 회수를 유도
csql -S -u dba testdb -c "DELETE FROM u WHERE a % 2 = 0;"
csql -S -u dba testdb -c "DELETE FROM u;"
wait

grep -n 'we told it not to\|Candidate heap page\|Assertion' $CUBRID/log/server/testdb_*.err
cubrid server status
```

## Expected Result

- 3 단계 집계에서 순증감이 0 이 아닌 vpid 가 하나도 나오지 않는다. 회계 표의 5 가지 진입 상황 전부에서 등록과 해제가 짝을 이룬다.
- `unreg-fix lockfree=1` 이 0 건이거나, 그 경로에서도 등록이 함께 수행돼 순증감이 0 이다.
- 4 단계에서 `page was deallocated an we told it not to!` 로그와 그에 딸린 debug 빌드 assert 가 발생하지 않는다.

## Actual Result

- 3 단계 집계에서 순증감이 0 이 아닌 vpid 가 나온다. 순차 heap scan 부하만으로 재현되며, 음수는 보호를 훔친 쪽(회계 표 1·4 행), 양수는 보호가 잔존한 쪽(5 행)이다.
- `unreg-fix lockfree=1` 로그가 쌓인다 — lock-free 빠른 경로가 등록 없이 해제만 실행한 횟수다.
- 카운터가 0 인 채로 해제가 호출되면 0 방어가 매번 `er_log_debug` 를 남기므로, `er_log_debug` 를 켠 환경에서는 heap scan 핫 경로에서 디버그 로그가 반복 출력된다.
- 보호가 지워진 empty heap page 가 vacuum 에 회수되면, 그 page 를 다시 fix 하려던 스레드가 `ER_PB_BAD_PAGEID` 를 받고 `:12816-12819` 경로로 떨어진다. debug 빌드에서는 `:12817` 의 `assert (false)` 로 서버가 중단된다.

## Additional Information

### 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:12280-12296` | `pgbuf_ordered_fix` 의 latch 조건 결정과 1차 `pgbuf_fix` 시도 (원본 fetch mode 전달) |
| `page_buffer.c:12392-12396` | `has_dealloc_prevent_flag` 설정과 fetch mode 를 `OLD_PAGE` 로 재작성 |
| `page_buffer.c:12699-12704`, `:12847-12852` | 요청 page 해제 두 지점 |
| `page_buffer.c:12946`, `:12972-12998` | `exit` 정리 — `:12639` 로 등록한 보유 page 분만 되돌린다 |
| `page_buffer.c:2311-2313`, `:2315-2328` | lock-free 진입 조건과 `goto fast_path` |
| `page_buffer.c:2425-2428`, `:2513-2517` | `pgbuf_fix` 의 등록/해제 지점 |
| `page_buffer.c:2440-2463` | 조건부 latch 실패 반환 — 등록을 되돌리지 않는다 |
| `page_buffer.c:6511-6545` | 조건부 latch 거부가 `ER_FAILED` 를 반환하는 지점 |
| `page_buffer.c:7671-7734`, `:7689-7693` | `pgbuf_lockfree_fix_ro` 전체와 성립 조건 |
| `page_buffer.c:16205-16209`, `:16217-16253` | 등록/해제 구현, `:16226-16250` 이 0 방어, `:16232-16244` 가 위험 감수 주석 |
| `page_buffer.c:535-540`, `:267-269` | `count_fix_and_avoid_dealloc` 의 2 용도 필드 정의와 하위 16 비트 마스크 |
| `page_buffer.c:12639`, `:12883`, `:12994` | 보유 page 용 대칭 등록/해제 (요청 page 분과 별개) |
| `page_buffer.c:14670-14683` | `pgbuf_has_prevent_dealloc` — 보호 여부 조회 API |
| `vacuum.c:1850`, `heap_file.c:3383` | 보호 카운트를 소비해 empty heap page 회수 여부를 결정하는 두 지점 |

### 수정 방향 후보

| 순위 | 후보 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | 요청 page 의 보호를 `pgbuf_ordered_fix` 가 전담한다. `pgbuf_fix` 는 이 fetch mode 에서 카운터를 건드리지 않게 하고(`:2425-2428`, `:2513-2517` 제거), ordered fix 가 1차 시도 전에 직접 등록하고 성공·실패·`exit` 모든 출구에서 해제한다 | 진입 상황 5 가지가 한 함수 안에서 끝나므로 회계가 눈으로 확인된다. 등록 시점에 BCB 포인터가 필요해 hash 조회가 한 번 늘어나는데, 이미 `exit` 정리(`:12977-12978`)가 같은 조회를 하고 있어 새로운 패턴은 아니다. |
| 2 | 분담을 유지한 채 깨진 세 조합만 메운다. lock-free 경로 여부를 지역 플래그로 구분해 `:2513-2517` 을 건너뛰고, `:2427` 미실행 상태를 ordered fix 로 전달하고, `exit` 에 `has_dealloc_prevent_flag` 정리를 추가한다 | 변경이 국소적이고 성능 영향이 없다. 대신 두 함수에 걸친 암묵적 계약이 그대로 남아, 다음 수정자가 같은 실수를 반복할 여지를 남긴다. 계약을 주석으로 못박는 것이 최소 조건이다. |
| 3 | lock-free 진입 조건(`:2311-2313`)에서 `OLD_PAGE_PREVENT_DEALLOC` 을 제외한다 | 첫 번째 행만 한 줄로 없앤다. 나머지 두 결함(4·5 행)은 남으므로 단독으로는 부족하고, `heap_next_internal` 의 1차 시도가 lock-free 이득을 잃는 대가도 따른다. |

### 확인해 둔 사항

- `pgbuf_ordered_fix` 의 재정렬 경로로 진입하려면 1차 시도가 조건부 latch 로 실패해야 한다(`:12377-12386` 이 무조건 latch 실패를 걸러낸다). 그 실패의 대부분은 latch 충돌이고, 이 경우 `:2427` 의 등록이 이미 남아 있어 `:12702`/`:12850` 의 해제와 짝이 맞는다. 따라서 이 두 해제 지점을 무조건 비대칭으로 보면 안 되며, 수정할 때 이 균형을 깨지 않아야 한다.
- 보유 page 용 등록(`:12639`)은 `ordered_holders_info[i].prevent_dealloc` 로 추적되며 `:12883`, `:12994` 에서 해제되므로 요청 page 분과 섞이지 않는다.
- 부모 EPIC: CBRD-27193.
