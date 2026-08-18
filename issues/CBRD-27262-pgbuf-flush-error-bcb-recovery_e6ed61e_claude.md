# [PGBUF] flush 준비 후 TDE/DWB 오류 시 BCB 상태를 복구한다

## Issue Triage

**이슈 수행 목적**: page flush 준비 단계에서 오류로 물러날 때도 BCB 상태를 flush 시도 이전으로 되돌려, 특정 page 가 영구히 "flush 중" 으로 남지 않게 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `dwb_set_data_on_next_slot` 실패를 한 번 주입하면 그 page 의 BCB 는 `PGBUF_BCB_FLUSHING_TO_DISK_FLAG` 가 켜지고 `PGBUF_BCB_DIRTY_FLAG` 는 꺼진 상태로 영구히 남는다 (`page_buffer.c:10767`). TDE 암호화 실패 경로(`:10755`)도 같다. |
| **TO-BE (목표 상태 / 기대 동작)** | 두 조기 반환이 정규 write 실패 경로(`:10848-10863`)와 같은 정리 — dirty 복원, flushing 해제, `oldest_unflush_lsa` 복원, flush 대기자 기상 — 를 거쳐 다음 flush 시도가 정상적으로 이뤄진다. |
| **영향** | 고객 장애 — 그 page 를 다시 수정하면 checkpoint 가 깨워줄 주체 없는 대기에 들어간다. checkpoint 는 서버 종료 절차(`log_manager.c:1857`)에도 있어 `cubrid server stop` 이 끝나지 않는다. |

**이슈 수행 방안**: 부모 EPIC CBRD-27193 의 A1 항목에 정해진 방향대로, `pgbuf_bcb_flush_with_wal` 의 두 조기 반환을 정규 write 실패 정리 경로로 합친다. 곁가지로 `pgbuf_claim_bcb_for_fix` 의 `dwb_read_page` 실패 경로에 인접 실패 경로와 동일한 정리(`pgbuf_put_bcb_into_invalid_list` + `pgbuf_unlock_page`)를 넣는다. `PGBUF_LATCH_FLUSH` 대기에 타임아웃을 부여하는 문제는 이 이슈 범위 밖이며 `TBD - 합의 미확인` 이다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c` 의 `pgbuf_bcb_flush_with_wal` (`:10673-10900`) 과 `pgbuf_claim_bcb_for_fix` (`:8456-8461`) 두 함수에 국한된다. 디스크 형식, 설정 파라미터, 공개 함수 시그니처는 그대로다. DWB 는 `double_write_buffer_size` 기본값 2 MiB 로 켜져 있어 기본 설정에서 노출되고, TDE 경로는 암호화 사용 DB 에서만 노출된다. 오류 자체가 드문 방어 경로라 자연 재현 빈도는 낮으므로 검증은 오류 주입으로 한다. 이 이슈는 부모 EPIC CBRD-27193 의 결함 D1(조기 반환 미복구)과 N2(`dwb_read_page` 실패 정리 누락)를 소유한다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

---

## Description

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈) 는 page 하나를 디스크로 내릴 때 `pgbuf_bcb_flush_with_wal` 을 유일한 관문으로 쓴다. 이 함수는 진입 직후 `pgbuf_bcb_mark_is_flushing` (`:10741`) 으로 BCB (Buffer Control Block — frame 에 올라온 page 의 fix 수, latch 상태, dirty 여부를 보관하는 제어 블록) 의 플래그를 {flushing 켜기, dirty 끄기} 로 바꾼다. dirty 를 미리 내리는 이유는, 이 시점 이후에 다른 스레드가 page 를 수정하면 그 변경이 "이번 write 에 포함되지 않은 새 변경" 으로 다시 dirty 로 잡히도록 하기 위해서다.

문제는 그 전이 이후에 정리 없이 빠져나가는 경로가 둘 남아 있다는 점이다. TDE (Transparent Data Encryption — data page 암호화) 암호화 실패와 DWB (Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 먼저 기록해 torn write 를 막는 장치) 슬롯 확보 실패가 그 둘이다.

    pgbuf_bcb_flush_with_wal ()                                      :10673
      │
      ├ pgbuf_bcb_mark_is_flushing ()                                :10741
      │    ├ FLUSHING_TO_DISK 켜기
      │    └ DIRTY 끄기
      │
      ├ tde_encrypt_data_page () 실패 -> return error                :10755  ★
      ├ dwb_set_data_on_next_slot () 실패 -> return error            :10767  ★
      │
      ├ oldest_unflush_lsa 를 지역 변수로 옮기고 NULL 로              :10776-10779
      ├ logpb_flush_log_for_wal ()  <- WAL 규칙 준수 지점             :10788
      │
      └ write 실패 (fileio_write / dwb_add_page)                     :10848
           ├ pgbuf_bcb_mark_was_not_flushed (was_dirty)              :10852
           ├ oldest_unflush_lsa 복원                                  :10853
           └ pgbuf_wake_flush_waiters ()                             :10858

    ★ 표시한 두 조기 반환은 맨 아래 세 줄의 복구를 거치지 않는다.

WAL (Write-Ahead Logging — data page 보다 log 를 먼저 디스크에 기록하는 규칙) 을 지키기 위한 `oldest_unflush_lsa` (그 page 에서 아직 디스크에 반영되지 않은 가장 오래된 log 위치) 이동은 `:10776` 부터라 조기 반환 시점에는 값이 그대로 남는다. 즉 잃어버리는 것은 LSA 가 아니라 dirty/flushing 플래그 쌍과 대기자 기상이다.

| 시점 | DIRTY | FLUSHING_TO_DISK | oldest_unflush_lsa | victim 후보 |
|---|---|---|---|---|
| flush 진입 전 | 1 | 0 | 값 있음 | 아니다 (dirty 라서) |
| `mark_is_flushing` 직후 (`:10741`) | 0 | 1 | 값 유지 | 아니다 (flushing 이라서) |
| 정규 write 실패 복구 후 (`:10852-10853`) | 1 | 0 | 복원 | 아니다, 그러나 flush 재시도 가능 |
| 조기 반환 후 (`:10755` / `:10767`) | 0 | 1 | 값 유지 | 영구히 아니다 |

이 상태가 스스로 낫지 않는 이유는 flushing 플래그를 내리는 주체가 `pgbuf_bcb_mark_was_flushed` (`:16044`) 와 `pgbuf_bcb_mark_was_not_flushed` (`:16058`) 뿐이고, 두 함수 모두 flush 를 시작한 스레드만 부르기 때문이다. 그 스레드는 이미 오류를 들고 돌아갔다. 조기 반환 시 `*is_bcb_locked` 가 true 로 유지되므로 BCB mutex 는 호출자(`:4040-4043`, `:12109-12112`)가 풀어 준다. 즉 mutex 누수는 없고, 남는 것은 플래그 상태다.

증상은 두 단계로 나타난다.

첫째, 그 BCB 는 victim (교체 대상으로 골라 비우고 다른 page 에 재사용하는 BCB) 후보에서 영구히 제외된다. `PGBUF_BCB_INVALID_VICTIM_CANDIDATE_MASK` (`:258-262`) 에 flushing 플래그가 들어 있어 `pgbuf_bcb_avoid_victim` (`:16181-16184`) 이 계속 true 를 돌려준다. frame 하나가 영구히 묶이는 정도라 이 단계만으로는 눈에 잘 띄지 않는다.

둘째, 그 page 가 다시 수정되면 동기 flush 요청자가 무한 대기에 들어간다. `pgbuf_bcb_safe_flush_internal` 은 dirty 가 아니면 즉시 반환하므로(`:8779-8783`) 재수정 전에는 아무도 걸리지 않는다. 재수정으로 dirty 가 다시 켜지면 dirty 이면서 flushing 인 조합이 되고, 이 함수는 flushing 을 보고 즉시 flush 를 포기한 뒤 `synchronous == true` 호출자를 `pgbuf_block_bcb (..., PGBUF_LATCH_FLUSH, ...)` (`:8834-8843`) 로 재운다. 이 대기에는 타임아웃이 없다 — READ/WRITE latch (page 단위 짧은 읽기/쓰기 잠금) 대기는 `pgbuf_timed_sleep` (`:7103`) 으로 시간 제한을 받는데 `PGBUF_LATCH_FLUSH` 만 무기한 suspend 이고(`:7048-7053`), 소스에도 `/* is it safe to use infinite wait instead of timed sleep? */` 라는 미해결 주석이 `:7050` 에 남아 있다. 깨워 줄 주체인 `pgbuf_wake_flush_waiters` 는 flush 를 끝낸(또는 실패 복구한) 스레드만 부르므로 영원히 오지 않는다.

`synchronous == true` 로 들어오는 호출자는 checkpoint (복구 시작점을 앞당기기 위해 dirty page 를 디스크로 내리는 주기 작업) 를 포함해 다섯 곳이다.

| 호출 지점 | 함수 | 계기 |
|---|---|---|
| `:4497` | `pgbuf_flush_seq_list` | checkpoint (`log_page_buffer.c:7011` 의 `pgbuf_flush_checkpoint`) |
| `:3562` | `pgbuf_flush_with_wal` | 공개 API 를 통한 page 단위 강제 flush |
| `:3644` | `pgbuf_flush_all_helper` | 볼륨 전체 flush (`pgbuf_flush_all` 계열) |
| `:3380` | `pgbuf_invalidate` | page 무효화 |
| `:3470` | `pgbuf_invalidate_all` | 볼륨 단위 무효화 |

checkpoint 는 주기 데몬(`checkpoint_interval` 기본 360 초)뿐 아니라 서버 종료 절차(`log_manager.c:1857` 의 `log_final`)에도 있어, 한 번 새어 나간 BCB 는 정상 종료를 막는다.

### 곁가지 결함 — `dwb_read_page` 실패 경로의 정리 누락 (N2)

`pgbuf_claim_bcb_for_fix` 는 새 frame 에 page 를 읽어 올릴 때 먼저 DWB 에서 최신 사본을 찾는다. 그 호출이 실패하면 정리 없이 그대로 반환한다.

| 실패 경로 | 라인 | BCB mutex | invalid list 반환 | VPID 잠금 해제 |
|---|---|---|---|---|
| `dwb_read_page` 실패 | `:8456-8461` | 든 채로 반환 | 없음 | 없음 |
| `fileio_read` 실패 | `:8466-8491` | 정리 함수가 해제 | `pgbuf_put_bcb_into_invalid_list` | `pgbuf_unlock_page` |
| TDE 복호화 실패 | `:8495-8506` | 정리 함수가 해제 | `pgbuf_put_bcb_into_invalid_list` | `pgbuf_unlock_page` |

`assert (false)` 가 붙어 있어 debug 빌드는 즉시 죽지만, release 빌드에서는 그 BCB mutex 가 영구 잠금되고 같은 VPID 를 기다리는 스레드도 깨어나지 못한다. 방어 코드라 실제 발생 여부와 별개로 정리 누락 자체가 결함이라 이 이슈에서 함께 고친다.

## Test Build

`CUBRID develop e6ed61e87 (소스 빌드)`, Linux x86_64 debug 빌드. DWB 기본값(`double_write_buffer_size = 2M`) 사용.

## Repro

DWB 슬롯 확보 실패는 정상 운영에서 관측하기 어려우므로 오류를 한 번만 주입한다. 아래 삽입 코드는 진단 전용이라 절대 병합하지 않는다.

**1. 오류 주입** — `dwb_set_data_on_next_slot` 호출 직전에 한 번만 실패를 만드는 임시 코드를 넣는다. 삽입 지점을 앵커 문자열로 찾으므로 들여쓰기 차이에 영향받지 않는다.

```bash
cd <cubrid-source-root>
python3 - <<'PY'
path = "src/storage/page_buffer.c"
src = open(path).read()
anchor = "error = dwb_set_data_on_next_slot (thread_p, iopage, false, false, &dwb_slot);"
assert src.count(anchor) == 1
inject = (
    "/* TEMP: CBRD-27262 fault injection. never merge. */\n"
    "      {\n"
    "        static bool injected = false;\n"
    "        if (!injected && bufptr->vpid.volid == 0 && bufptr->vpid.pageid > 1000\n"
    "            && bufptr->iopage_buffer->iopage.prv.ptype == PAGE_HEAP)\n"
    "          {\n"
    "            injected = true;\n"
    "            _er_log_debug (ARG_FILE_LINE, \"CBRD-27262 inject vpid=%d|%d\\n\",\n"
    "                           VPID_AS_ARGS (&bufptr->vpid));\n"
    "            return ER_FAILED;\n"
    "          }\n"
    "      }\n"
    "      "
)
open(path, "w").write(src.replace(anchor, inject + anchor, 1))
print("injected")
PY
./build.sh -m debug
```

**2. DB 생성과 파라미터 설정**

```bash
cubrid createdb --db-volume-size=200M --log-volume-size=100M testdb en_US.utf8
cat >> $CUBRID/conf/cubrid.conf <<'EOF'
data_buffer_size=32M
checkpoint_interval=30s
er_log_debug=yes
log_pgbuf_victim_flush=yes
detailed_checkpoint_logging=yes
EOF
cubrid server start testdb
```

**3. flush 데몬이 사용자 테이블 heap page 를 내리도록 부하 주기** (주입 조건을 heap page 로 좁혀 놓았으므로 카탈로그 page 가 아니라 `t` 의 page 가 걸린다)

```bash
csql -S -u dba testdb -c "CREATE TABLE t (a INT PRIMARY KEY, b VARCHAR(1000));"
csql -S -u dba testdb -c "
  INSERT INTO t
  SELECT ROWNUM, REPEAT('x', 1000)
  FROM db_class a, db_class b, db_class c LIMIT 200000;"
```

주입이 걸렸는지는 서버 오류 로그에서 확인한다.

```bash
grep -n 'CBRD-27262 inject' $CUBRID/log/server/testdb_*.err
```

**4. 새어 나간 BCB 확인** (dirty 는 꺼졌는데 flushing 이 켜진 BCB)

```bash
cat > /tmp/leaked-bcb.gdb <<'EOF'
set pagination off
set $i = 0
while $i < pgbuf_Pool.num_buffers
  set $f = pgbuf_Pool.BCB_table[$i].flags
  if (($f & 0x40000000) != 0) && (($f & 0x80000000) == 0)
    printf "leaked bcb %d vpid %d|%d flags 0x%x\n", $i, \
      pgbuf_Pool.BCB_table[$i].vpid.volid, pgbuf_Pool.BCB_table[$i].vpid.pageid, $f
  end
  set $i = $i + 1
end
EOF
gdb -p $(pgrep -f 'cub_server testdb') -batch -x /tmp/leaked-bcb.gdb
```

**5. 같은 page 재수정 후 checkpoint 진입 -> 정지 확인**

전체 갱신으로 `t` 의 모든 heap page 를 다시 dirty 로 만들면 4 단계에서 찾은 BCB 도 dirty 이면서 flushing 인 조합이 된다. 그 상태에서 30 초 주기 checkpoint 를 기다린 뒤 종료를 시도한다.

```bash
csql -S -u dba testdb -c "UPDATE t SET b = 'y' WHERE a BETWEEN 1 AND 200000;"
sleep 60
grep -n 'pgbuf_flush_checkpoint END' $CUBRID/log/server/testdb_*.err   # 완료 로그가 없으면 정지 상태

cubrid server stop testdb &          # 종료 checkpoint 에서 멈추는지 확인
sleep 30
gdb -p $(pgrep -f 'cub_server testdb') -batch -ex 'thread apply all bt' 2>&1 \
  | grep -B 10 'pgbuf_block_bcb'
```

## Expected Result

- 주입된 오류로 flush 가 실패해도 해당 BCB 는 dirty 로 돌아오고 flushing 이 내려가, 다음 flush 주기에 다시 write 를 시도한다. 4 단계 gdb 순회에서 dirty 가 꺼진 채 flushing 만 켜진 BCB 가 나오지 않는다.
- checkpoint 가 그 page 를 정상적으로 내리고 완료된다. `cubrid server stop testdb` 이 정상 종료한다.
- `dwb_read_page` 가 실패하는 경우에도 BCB mutex 와 VPID 잠금이 풀려, 같은 page 를 기다리던 스레드가 오류를 받고 진행한다.

## Actual Result

- 4 단계 순회에서 `flags` 에 `0x40000000` 만 켜진 BCB 가 남는다. 이 BCB 는 이후 어떤 경로로도 flushing 이 내려가지 않고 victim 후보에서도 제외된다.
- 5 단계에서 checkpoint 스레드가 `pgbuf_block_bcb` 안의 무기한 suspend 에 걸려 더 나아가지 못하고, `cubrid server stop testdb` 이 종료 checkpoint 에서 같은 대기에 걸려 끝나지 않는다.
- release 빌드에서 `dwb_read_page` 가 실패하면 그 BCB mutex 가 영구 잠금되고 같은 VPID 대기자가 깨어나지 못한다 (debug 빌드는 `:8459` 의 `assert (false)` 로 즉시 중단).

## Additional Information

### 참고 코드

| 위치 | 내용 |
|---|---|
| `page_buffer.c:10741` | `pgbuf_bcb_mark_is_flushing` 호출 — {flushing 켜기, dirty 끄기} 전이 시작점 |
| `page_buffer.c:10755`, `:10767` | 복구 없이 반환하는 두 조기 실패 경로 |
| `page_buffer.c:10848-10863` | 정규 write 실패 복구 — 이 이슈가 재사용해야 하는 정리 코드 |
| `page_buffer.c:258-262` | `PGBUF_BCB_INVALID_VICTIM_CANDIDATE_MASK` 에 flushing 플래그 포함 |
| `page_buffer.c:8779-8783` | dirty 가 아니면 flush 없이 반환 — 재수정 전까지 증상이 숨는 이유 |
| `page_buffer.c:7048-7053` | `PGBUF_LATCH_FLUSH` 무기한 대기, `:7050` 에 미해결 주석 |
| `page_buffer.c:8456-8461` | `dwb_read_page` 실패 시 정리 누락 (N2) |
| `log_page_buffer.c:7011` | checkpoint 가 `pgbuf_flush_checkpoint` 를 호출하는 지점 |
| `log_manager.c:1857` | 서버 종료 절차의 checkpoint |

### 구현 시 참고

- 두 조기 반환에서 필요한 정리는 `mark_was_not_flushed (was_dirty)` + `oldest_unflush_lsa` 복원 + 대기자 기상 세 가지인데, 조기 반환 지점에서는 `oldest_unflush_lsa` 를 아직 옮기지 않았으므로 복원은 불필요하다. 정리 블록을 공유하려면 이 차이를 흡수해야 한다.
- 조기 반환 지점에서는 BCB mutex 를 이미 들고 있으므로 정규 경로처럼 `PGBUF_BCB_LOCK` 을 다시 잡으면 안 된다.
- `dwb_set_data_on_next_slot` 실패 후 `dwb_slot` 이 남아 있을 수 있는지, 남으면 해제 책임이 어디인지는 `double_write_buffer.cpp` 쪽에서 확인이 필요하다.

### 범위 밖

- `PGBUF_LATCH_FLUSH` 대기에 타임아웃을 부여하는 변경은 대기 실패 시의 상위 처리까지 함께 정해야 하므로 분리한다. 상태 복구가 들어가면 이 hang 의 실제 유발 조건은 사라진다.
- 부모 EPIC: CBRD-27193.
