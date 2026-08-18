# [PGBUF] lock-free fix 경로의 dealloc 보호 카운터 비대칭을 수정한다

## Issue Triage

**이슈 수행 목적**: `OLD_PAGE_PREVENT_DEALLOC` fix 한 건이 dealloc 보호 카운터에 남기는 순증감을 어느 경로로 들어오든 항상 0 으로 만든다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `pgbuf_fix` 의 lock-free 빠른 경로가 dealloc 보호 카운터 등록(`page_buffer.c:2425-2428`)을 건너뛴 채 해제(`:2513-2517`)만 실행한다. 같은 성질의 짝 깨짐이 오류 경로 2 곳에 더 있어, 진입 상황 5 가지 중 3 가지에서 순증감이 0 이 아니다. 계측 빌드 실측으로 확인됐다 — 등록 없는 해제 40 회, 살아 있는 보호 감소 7 회, 종료 후 net -1 page 잔존 (상세는 Actual Result). |
| **TO-BE (목표 상태 / 기대 동작)** | `OLD_PAGE_PREVENT_DEALLOC` 요청 한 건이 성공하든 실패하든, 어느 경로로 들어오든 `count_fix_and_avoid_dealloc` 하위 16 비트에 남기는 순증감이 0 이다. |
| **영향** | 고객 장애 가능성 — 보호가 지워지면 vacuum 이 보호 중인 empty heap page 를 회수하고(`vacuum.c:1850`, `heap_file.c:3383`), 그 page 를 다시 fix 하던 스레드가 `pgbuf_ordered_fix` 의 `page was deallocated an we told it not to!` 경로(`:12816-12819`, debug 빌드는 `assert (false)`)로 떨어진다. 반대로 증가가 남으면 그 page 는 vacuum 회수 대상에서 영구히 빠진다. 결함 유입 커밋은 정식 유지보수 릴리스(v11.4.5, 2026-04-24)와 `release/11.4_hotfix` 에는 미포함이고 develop 빌드 태그 `v11.4.5.1898` 에만 들어 있다 — 해당 빌드의 외부 배포 여부만 확인되면, 다음 릴리스 전 수정으로 고객 노출 없이 끝난다. |

**이슈 수행 방안**: `TBD - 합의 미확인`. 후보 비교와 권장안은 아래 Additional Information 의 수정 방향 후보 표에 정리했다. 어느 쪽을 골라도 판정 기준은 위 TO-BE 한 줄이며, 회계 표의 5 가지 진입 상황이 모두 0 이 되어야 한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c` 의 `pgbuf_fix` (`:2207-2636`), `pgbuf_lockfree_fix_ro` (`:7671-7734`), `pgbuf_ordered_fix` (`:12206-13001`) 세 함수. 디스크 형식, 설정, 공개 함수 시그니처, 호출부는 그대로다 — `OLD_PAGE_PREVENT_DEALLOC` 사용처 10 곳은 전부 `pgbuf_ordered_fix` 를 거치므로 fix 계약 자체는 변하지 않는다.
- **결함 출처**: lock-free 빠른 경로는 커밋 `58cef8e01` (CBRD-26425, PR #6704, 2026-01-14 병합) 이 도입했다. 목적은 CBRD-26242 (같은 page 동시 READ 시 `PGBUF_BCB_LOCK` mutex 병목, 64 core 4 배 개선 목표) 해소다. 도입 diff 는 `register/unregister_avoid_deallocation` 을 한 줄도 건드리지 않았다 — 등록 누락은 설계 판단이 아니라 실수다. 같은 `goto` 가 건너뛰는 다른 회계 두 건은 아래 Remarks 에. 같은 커밋의 회귀로는 CBRD-27084 (waiter_exists 미해제 무한 spin) 가 이미 있었다.
- **관련 필드**: `count_fix_and_avoid_dealloc` (`:535-540`) 은 상위 16 비트가 hot page 판정용 fix 횟수, 하위 16 비트가 dealloc 보호 수인 2 용도 필드이고(`:267-269`), 이 이슈는 하위 16 비트만 다룬다. latch 상태를 담는 64 비트 CAS 워드 `atomic_latch` (`:501-510`) 와는 별개 필드다. 이 이슈는 부모 EPIC CBRD-27193 의 결함 N1 을 소유한다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

---

## Description

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 에는 "이 page 를 지금 쓰고 있으니 해제하지 말라" 는 표시가 있다. fetch mode `OLD_PAGE_PREVENT_DEALLOC` 로 fix 하면 BCB (Buffer Control Block — frame 에 올라온 page 의 fix 수, latch 상태, dirty 여부를 보관하는 제어 블록) 의 `count_fix_and_avoid_dealloc` 하위 16 비트가 1 늘고, latch (page 단위 짧은 읽기/쓰기 잠금) 를 얻은 뒤 다시 1 줄어든다.

소비자는 vacuum (MVCC 에서 더 이상 보이지 않는 레코드 버전을 정리하는 백그라운드 작업) 쪽 두 곳이다. 이하 `vacuum.c` 는 `src/query/vacuum.c`, `heap_file.c` 는 `src/storage/heap_file.c` 다.

    vacuum_heap_page ()                                       vacuum.c:1581
      └ 레코드가 1 개 이하로 남은 heap page 를 회수 후보로 본다
           ├ pgbuf_has_prevent_dealloc (home_page) == false    vacuum.c:1850
           └ heap_remove_page_on_vacuum ()
                ├ 필요한 latch 를 모두 잡은 뒤 재확인            heap_file.c:3383
                └ 두 확인이 모두 false 면 heap 파일에서 page 를 떼어낸다
    ★ 보호 카운트가 0 으로 보이면 vacuum 은 회수해도 된다고 판단한다

이 마커가 지키는 구간은 두 개다. 첫째, `pgbuf_fix` 가 latch 를 얻기 전 대기하는 구간 — 스캐너가 등록(+1) 후 latch 대기에 들어가 있으면 vacuum 의 재확인(`heap_file.c:3383`)이 이 값을 보고 "somebody was doing a heap scan" 으로 판단해 정상적으로 물러난다. 마커 없이 대기자만 있으면 `heap_file.c:3395` 의 `pgbuf_has_any_waiters` → `assert (false)` ("Unexpected page waiters") 로 넘어간다 — vacuum 은 마커가 대기자보다 먼저 보인다는 가정 위에 서 있다. 둘째, `pgbuf_ordered_fix` (heap page 여러 장을 데드락 없이 잡도록 전역 순서에 따라 latch 를 재배열하는 fix 변형) 가 보유 page 를 전부 놓고 재정렬하는 구간이다.

마커는 소유자 기준으로도 두 종류다. 요청 page 용 등록(`:2427`, fetch mode 에 의존, 이하 요청 page 마커)과 보유 page 용 등록(`:12639`, fetch mode 와 무관하게 무조건, `:12883`/`:12994` 에서 해제)이며, **깨진 것은 요청 page 마커의 회계뿐이고 보유 page 쪽은 건전하다.**

### 요청 page 의 보호는 두 함수가 나눠 맡는다

이 fetch mode 를 외부에서 `pgbuf_fix` 로 직접 넘기는 호출부는 트리 전체에 하나도 없다. 전부 `pgbuf_ordered_fix` 로 들어온다. 그런데 그 안에서 요청 page 의 보호를 걸고 푸는 주체가 상황마다 달라진다.

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

> **요지**: 그 주석이 감수하겠다고 한 것은 "내가 걸어 둔 마커가 사라진 0 케이스" 뿐이다. 이 이슈가 문제로 삼는 것은 카운터가 1 이상인 상태에서 **다른 주체(vacuum 을 막으려고 보호를 걸어 둔 스레드)의 카운트를 감소시키는** 경우이고, 이때는 0 방어가 발동하지 않으므로 주석의 감수 선언 밖이다. 아래 Actual Result 의 실측에서 이 도난이 7 회 관측됐다.

### 노출 경로

`OLD_PAGE_PREVENT_DEALLOC` 사용처는 10 곳이며 전부 `pgbuf_ordered_fix` 로 수렴한다.

| 호출부 | 경유 | latch |
|---|---|---|
| `heap_file.c:7572`, `7726` (`heap_next_internal`) | `heap_scan_pb_latch_and_fetch` 의 watcher (pgbuf_ordered_fix 가 재배열로 pgptr 가 바뀌어도 호출자가 따라갈 수 있게 쥐여 주는 page 추적 핸들) 분기 (`heap_file.c:957-968`) | READ |
| `heap_file.c:9375`, `14366`, `14780`, `18923`, `19022` | 같은 분기 | READ |
| `heap_file.c:17478` | 같은 분기 | WRITE |
| `heap_file.c:8979`, `locator_sr.c:12788` | `pgbuf_ordered_fix` 직접 호출 | READ / WRITE |

`heap_next_internal` 은 인덱스를 타지 않는 순차 heap scan 이라 상시 실행된다. 10 곳 모두 page 안의 next/prev 링크(`heap_vpid_next`)로 다음 page 를 찾는 체인 순회 구조라, page 를 잃으면 다음 목적지 포인터도 함께 잃는다 — 9 곳이 하드 에러로 끝나고 1 곳(`heap_dump`)은 출력이 조용히 잘린다. WRITE latch 호출부는 lock-free 진입 조건을 만족하지 않아 첫 번째 행과 무관하고, 나머지 네 상황에는 그대로 해당한다.

## Test Build

`CUBRID develop e6ed61e87 (소스 빌드)`, Linux x86_64 debug 빌드. 아래 Repro 를 이 빌드에서 실행해 Actual Result 의 수치를 실측했다.

## Repro

### 1. 등록/해제 짝이 깨지는지 계측

등록·해제 함수 자체에 로그를 넣어 vpid 별 순증감을 세고, `pgbuf_fix` 의 해제 지점에는 lock-free 경로를 거쳤는지 함께 남긴다. 삽입 지점을 앵커 문자열로 찾으므로 들여쓰기 차이에 영향받지 않는다. 진단 전용이라 병합하지 않는다.

```bash
cd <cubrid-source-root>
python3 - <<'PY'
path = "src/storage/page_buffer.c"
src = open(path).read()

def insert_before(anchor, text):
    assert src.count(anchor) == 1, anchor
    return src.replace(anchor, text + anchor, 1)

def insert_after(anchor, text):
    assert src.count(anchor) == 1, anchor
    return src.replace(anchor, anchor + text, 1)

src = insert_before("bool retry = false;", "bool lockfree_fast_path = false;\n  ")

src = insert_after("pgptr = pgbuf_lockfree_fix_ro (thread_p, vpid, fetch_mode);",
                   "\n      lockfree_fast_path = (pgptr != NULL);")

src = insert_before("/* latch is obtained, no need for avoidance of dealloc */",
                    "_er_log_debug (ARG_FILE_LINE, \"CBRD-27263 unreg-fix lockfree=%d vpid=%d|%d avoid=%d\\n\",\n"
                    "                     (int) lockfree_fast_path, VPID_AS_ARGS (&bufptr->vpid),\n"
                    "                     bufptr->count_fix_and_avoid_dealloc & 0x0000FFFF);\n      ")

src = insert_before("(void) ATOMIC_INC_32 (&bcb->count_fix_and_avoid_dealloc, 1);",
                    "_er_log_debug (ARG_FILE_LINE, \"CBRD-27263 register vpid=%d|%d avoid=%d\\n\",\n"
                    "                 VPID_AS_ARGS (&bcb->vpid), bcb->count_fix_and_avoid_dealloc & 0x0000FFFF);\n  ")

src = insert_after("int count_crt;",
                   "\n  _er_log_debug (ARG_FILE_LINE, \"CBRD-27263 unregister vpid=%d|%d avoid=%d\\n\",\n"
                   "                 VPID_AS_ARGS (&bcb->vpid), bcb->count_fix_and_avoid_dealloc & 0x0000FFFF);")

open(path, "w").write(src)
print("instrumented")
PY
./build.sh -m debug

# 빌드 산출물로 환경을 잡는다 (이후 단계 전부가 이 환경을 전제한다)
export CUBRID=$(pwd)/build_x86_64_debug/_install/CUBRID
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:$LD_LIBRARY_PATH
export CUBRID_DATABASES=$CUBRID/databases
```

`register` 와 `unregister` 로그는 보유 page 용 등록·해제(`:12639` 계열)까지 함께 잡지만, 그 쌍은 균형이 맞으므로 vpid 별 합계에는 영향을 주지 않는다. `unregister` 의 `avoid` 값은 감소 직전 값이라 0 이면 0 방어에 막힌 호출이고, `unreg-fix lockfree=1` 에 `avoid` 가 1 이상이면 살아 있는 남의 보호를 실제로 깎은 것이다.

### 2. 부하 시나리오 — 순차 scan + UPDATE 혼합

scan 세션이 `heap_next_internal` → `pgbuf_ordered_fix(OLD_PAGE_PREVENT_DEALLOC, READ)` 를 상시 태우고, UPDATE 세션의 WRITE latch 가 조건부 latch 충돌(회계 표 3 행의 등록 잔존 구간)을 만들어 도난 대상(살아 있는 +1)과 도둑(lock-free 해제)이 같은 page 에서 겹치게 한다.

```bash
cubrid createdb --db-volume-size=200M --log-volume-size=100M testdb en_US.utf8

# 버퍼 풀을 작게 잡아 victim 교체 압력을 만들고, 0 방어의 진단 로그가 보이도록 debug 로그를 켠다
printf 'data_buffer_size=64M\ner_log_debug=yes\n' >> $CUBRID/conf/cubrid.conf

cubrid server start testdb

csql -u dba testdb -c "CREATE TABLE t (a INT PRIMARY KEY, b VARCHAR(200));"
csql -u dba testdb -c "
  INSERT INTO t
  SELECT ROWNUM, REPEAT('x', 200)
  FROM db_class a, db_class b, db_class c LIMIT 100000;"

# 순차 scan 10 세션 (인덱스를 타지 않도록 b 로 필터) + 구간 UPDATE 4 세션
for i in $(seq 1 10); do
  ( for j in $(seq 1 40); do
      csql -u dba testdb -c "SELECT COUNT(*) FROM t WHERE b LIKE 'x%';" > /dev/null
    done ) &
done
for u in $(seq 1 4); do
  ( for j in $(seq 1 40); do
      lo=$(( (u * 7919 + j * 997) % 95000 )); hi=$((lo + 3000))
      csql -u dba testdb -c "UPDATE t SET b = REPEAT('z', 200) WHERE a BETWEEN $lo AND $hi;" > /dev/null
    done ) &
done
wait
```

### 3. vpid 별 순증감 집계

```bash
LOG=$(ls -t $CUBRID/log/server/testdb_*.err | head -1)

# register 는 +1, unregister 는 감소 직전 값이 1 이상일 때만 -1 로 센다
sed -nE 's/.*CBRD-27263 (register|unregister) vpid=([0-9]+\|[0-9]+) avoid=([0-9]+).*/\1 \2 \3/p' "$LOG" \
  | awk '{ if ($1 == "register") n[$2]++; else if ($3 > 0) n[$2]--; }
         END { for (v in n) if (n[v] != 0) printf "vpid %s net %+d\n", v, n[v] }'

grep -c 'CBRD-27263 unreg-fix lockfree=1' "$LOG"                     # 회계 표 1 행 실행 횟수
grep -cE 'CBRD-27263 unreg-fix lockfree=1 vpid=[0-9|]+ avoid=[1-9]' "$LOG"  # 그중 실제 도난 (감소 직전 관측값 기준)
grep -E 'CBRD-27263 unreg-fix lockfree=1 vpid=[0-9|]+ avoid=[1-9]' "$LOG" \
  | sed -E 's/.*vpid=([0-9|]+).*/\1/' | sort | uniq -c               # 도난이 발생한 vpid 목록
grep -c 'CBRD-27263 unregister .* avoid=0' "$LOG"                    # 0 방어에 막힌 해제
```

2 단계의 부하 강도는 조절해도 결함 경로 자체는 관측된다 — updater 를 빼고 테이블을 수천 행으로 줄인 변형에서도 `unreg-fix lockfree=1` 은 수십 회 단위로 쌓인다. updater 는 도난(살아 있는 +1 과의 겹침)을 보기 위한 장치다.

### 4. 보호가 지워졌을 때의 결과 확인 (확률적)

```bash
csql -u dba testdb -c "
  CREATE TABLE u (a INT PRIMARY KEY, b VARCHAR(200));
  INSERT INTO u SELECT ROWNUM, REPEAT('y', 200) FROM db_class a, db_class b, db_class c LIMIT 100000;"

# 세션 1..6: 순차 scan 반복 / 세션 7: 만행 단위 배치 삭제로 empty heap page 유도
for i in $(seq 1 6); do
  ( for j in $(seq 1 60); do
      csql -u dba testdb -c "SELECT COUNT(*) FROM u WHERE b LIKE 'y%';" > /dev/null 2>&1 || break
    done ) &
done
k=0
while [ "$k" -lt 100000 ]; do
  csql -u dba testdb -c "DELETE FROM u WHERE a BETWEEN $k AND $((k + 9999));" > /dev/null
  k=$((k + 10000))
done
wait

grep -n 'we told it not to\|Candidate heap page\|Assertion' $CUBRID/log/server/testdb_*.err
cubrid server status
```

## Expected Result

- 3 단계 집계에서 순증감이 0 이 아닌 vpid 가 하나도 나오지 않는다. 회계 표의 5 가지 진입 상황 전부에서 등록과 해제가 짝을 이룬다.
- `unreg-fix lockfree=1` 이 0 건이거나, 그 경로에서도 회계가 맞아 순증감이 0 이다. 특히 `avoid` 1 이상 상태의 lock-free 해제(도난)가 0 건이다.
- 4 단계에서 `page was deallocated an we told it not to!` 로그와 그에 딸린 debug 빌드 assert 가 발생하지 않는다.

## Actual Result

위 Repro 를 e6ed61e87 debug 빌드에서 실행한 실측이다.

| 측정 항목 | 값 | 의미 |
|---|---|---|
| `unreg-fix lockfree=1` | 40 회 | 회계 표 1 행(등록 없는 해제)이 평범한 부하에서 상시 실행된다 |
| 그중 `avoid >= 1` (도난, 감소 직전 관측값 기준) | 7 회 (vpid 0\|769, 0\|4673) | 카운트 1 이상 상태의 감소 — 0 방어 감수 선언 밖의 사건 |
| 실행 종료 후 순증감 != 0 | vpid 0\|769 net -1 | 도난당한 피해자의 해제가 0 방어에 막혀(avoid=0 해제 39 회) 회계가 영구히 어긋났다 |

updater 없이 소형 테이블(5,625 행)로 줄인 3 단계 말미의 변형 실행에서도 등록 없는 해제가 23 회 나왔다. 4 단계의 최종 assert 는 "도난 순간 × vacuum 의 empty page 회수 × 체인 재 fix" 3중 경합이라 이번 실행에서는 재현되지 않았으나, 도난이 실측된 이상 발생은 확률의 문제다.

- 카운터가 0 인 채로 해제가 호출되면 0 방어가 매번 `er_log_debug` 를 남기므로, `er_log_debug` 를 켠 환경에서는 heap scan 핫 경로에서 디버그 로그가 반복 출력된다.

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
| `page_buffer.c:7671-7734`, `:7689-7693` | `pgbuf_lockfree_fix_ro` 전체와 성립 조건 |
| `page_buffer.c:16205-16209`, `:16217-16253` | 등록/해제 구현, `:16226-16250` 이 0 방어, `:16232-16244` 가 위험 감수 주석 |
| `page_buffer.c:501-510`, `:535-540`, `:267-269` | `atomic_latch` 워드 구성과 `count_fix_and_avoid_dealloc` 2 용도 필드 정의 |
| `page_buffer.c:12639`, `:12883`, `:12994` | 보유 page 용 대칭 등록/해제 (요청 page 분과 별개) |
| `page_buffer.c:14670-14683` | `pgbuf_has_prevent_dealloc` — 보호 여부 조회 API |
| `vacuum.c:1850`, `heap_file.c:3383` | 보호 카운트를 소비해 empty heap page 회수 여부를 결정하는 두 지점 |
| `heap_file.c:3395` | `pgbuf_has_any_waiters` → `assert (false)` — 마커가 대기자보다 먼저 보인다는 vacuum 의 가정 |

### 수정 방향 후보

전제 두 가지: (i) `OLD_PAGE_PREVENT_DEALLOC` 자체는 제거할 수 없다 — 사용처 10 곳 전부가 체인 순회라 page 소실을 복구할 방법이 없고, 회수 억제라는 성능 무관 정합성 기능이다. (ii) 고칠 대상은 요청 page 마커의 회계뿐이다 (보유 page 마커는 건전).

| 순위 | 후보 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | **분담 유지 + 깨진 세 조합 보정 (최소 수정)**: lock-free 경로 여부를 지역 플래그로 구분해 `:2513-2517` 해제를 건너뛰고, 행 4 의 `:2427` 미실행 상태를 ordered fix 로 전달하며, 행 5 의 `exit` 에 `has_dealloc_prevent_flag` 정리를 추가한다. `pgbuf_fix` 의 오류 출구를 "조건부 latch 거절일 때만 +1 을 남긴다" 로 정규화하고, 두 함수에 걸친 handshake 계약을 양쪽에 주석으로 명문화한다 | lock-free CAS 는 fix 와 READ latch 를 원자적으로 동시에 얻으므로(`:7694-7697`) 이 경로에는 마커가 지킬 "latch 전 구간" 자체가 없다 — 카운터 불간섭이 의미론적으로 정확하다. 현재 1 행이 버그로 매번 실행하는 카운터 CAS 루프가 사라져 빠른 경로가 오늘보다 오히려 빨라진다. 일반 경로 등록이 그대로라 latch 대기 중 vacuum 후퇴 계약(`heap_file.c:3383`)도 보존된다. 대가는 handshake 부채 잔존 — 계약 주석이 최소 조건이다 |
| 2 | **요청 page 마커를 `pgbuf_ordered_fix` 전담으로 (소유권 재배치)**: `pgbuf_fix` 는 이 fetch mode 에서 카운터를 건드리지 않게 하고, ordered fix 가 1차 시도 전에 직접 등록하며 성공·실패·`exit` 모든 출구에서 해제한다 | 진입 상황 5 가지가 한 함수 안에서 끝나 회계가 눈으로 확인된다. 대신 등록 시점이 문제다: 1차 시도 **전** 등록은 모든 PREVENT_DEALLOC 순회 hop 에 hash 조회 1 회 + 카운터 원자 연산을 얹고(lock-free 히트가 접촉하는 경합 캐시라인이 1 개에서 2 개로 — CBRD-26242 가 없앤 패턴의 부분 부활) page 미상주 시 등록할 BCB 가 없는 경우의 조건부 회계가 필요하다. 반면 재정렬 진입 시점으로 늦추면 비용은 0 이지만 latch 대기 중 마커가 사라져 `heap_file.c:3383` 후퇴 계약이 깨진다(`:3395` assert). 채택하려면 전자 형태 + CBRD-26242 워크로드 재측정이 조건이다 |
| 3 | **lock-free 빠른 경로 revert**: `:1123-1128`, `:2311-2330`, `:2498`, `:3140-3144`, `:7671-7776` 삭제 (~137 줄, 전부 `page_buffer.c` 내부) | 기계적으로 단순하고 위험이 가장 낮다. `atomic_latch` 는 빠른 경로 전유물이 아니라 42 개 함수가 쓰는 BCB latch 워드 자체이므로 유지된다 — slow path 도 CAS 기반이라 CBRD-26425 개선분의 상당 부분은 남는다. 대신 hot 공유 READ page 의 무 mutex fix 를 잃어 CBRD-26242 병목을 다시 열고, 행 4·5 는 별도 보정이 여전히 필요하다. 수정 리뷰 일정이 촉박할 때의 안전판 |
| - | (기각) `OLD_PAGE_PREVENT_DEALLOC 제거` | 전제 (i) 위반. 체인 순회 호출자에게 "page 소실 후 재동기화" 어휘 자체가 없다 — `pgbuf_ordered_fix` 의 보유 page 재 fix 는 `OLD_PAGE` 하드코딩(`:12783`)이라 fetch mode 로도 우회 불가 |
| - | (기각) 카운터를 `atomic_latch` CAS 워드에 통합 | 이 결함에는 원자성 문제가 없다 — 카운터 증감은 처음부터 원자적이었고, 실측된 비대칭 40 회는 경합 파손이 아니라 +1 코드를 실행하지 않은 결과다. 워드를 합쳐도 등록을 건너뛰는 `goto` 는 남는다. 대가는 `fcnt` 32→16 비트 축소와 latch 기계 전면 재검증 |

### 확인해 둔 사항

- lock-free 경로가 성공하는 순간 READ latch 가 이미 손에 있으므로, 그 fix 건에 대해서는 latch 자체가 vacuum 을 막는다 (vacuum 의 page 제거는 대상 page WRITE latch 선행). 즉 1 행에서 등록을 생략한 것 자체는 무해하고, 해제만 실행하는 것이 결함이다.
- `pgbuf_ordered_fix` 의 재정렬 경로로 진입하려면 1차 시도가 조건부 latch 로 실패해야 한다(`:12377-12386` 이 무조건 latch 실패를 걸러낸다). 이 경우 `:2427` 의 등록이 남아 `:12702`/`:12850` 의 해제와 짝이 맞으므로, 이 두 해제 지점을 무조건 비대칭으로 보면 안 된다.
- 보유 page 용 등록(`:12639`)은 `ordered_holders_info[i].prevent_dealloc` 로 추적되며 `:12883`, `:12994` 에서 해제되므로 요청 page 분과 섞이지 않는다.

## Remarks

- 부모 EPIC: CBRD-27193 (이 이슈는 결함 N1). 결함 유입: CBRD-26425 (커밋 `58cef8e01`, PR #6704). 성능 배경: CBRD-26242. 같은 커밋의 선행 회귀: CBRD-27084.
- 같은 `goto fast_path` 가 함께 건너뛰는 나머지 회계 두 건 — `pgbuf_bcb_register_fix` (`:2395`, hot page 판정 과소 집계) 와 `had_holder` (`:2438`, debug 전용 fixed-at 추적 리셋) — 은 이 이슈와 근본 원인이 같다. 본 수정 PR 에 포함하거나 EPIC 아래 별도 티켓으로 분리한다.
