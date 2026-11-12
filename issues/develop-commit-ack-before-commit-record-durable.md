# [Log] COMMIT 성공을 받은 트랜잭션이 직후 서버 강제 종료 뒤 재시작 복구에서 롤백된다

**한 줄 요약**: Sidecar 개발 중 서버 강제 종료 스트레스 시험에서 찾은 develop 결함으로, `logpb_flush_pages` 가 커밋 로그 레코드가 디스크에 쓰이기 전에 커밋 대기를 끝내는 경우가 있어, 클라이언트가 COMMIT 성공을 받은 트랜잭션이 서버 강제 종료 뒤 재시작 복구에서 롤백되는 문제를 다룬다.

## Issue Triage

**이슈 수행 목적**: 클라이언트가 COMMIT 성공을 받은 트랜잭션은 그 직후 서버가 어떤 식으로 죽어도 재시작 뒤에 항상 커밋된 상태로 남는다(내구성, durability).

**이슈 수행 이유**: 동기 커밋(기본값 `async_commit=no`)에서 커밋하는 스레드는 `logpb_flush_pages` 에서 자기 커밋 로그 레코드가 디스크에 쓰일 때까지 기다린 뒤 응답한다. 이 대기는 `nxio_lsa`("아직 디스크에 쓰이지 않은 가장 낮은 LSA")가 커밋 레코드의 시작 LSA보다 **작은 동안만** 계속된다. 그런데 직전에 끝난 로그 flush가 `nxio_lsa` 를 정확히 커밋 레코드의 시작 LSA로 만들어 둔 경우가 있다. 이때 커밋 레코드는 아직 메모리에만 있는데도 대기 조건이 거짓이 되어, 서버는 디스크에 없는 커밋을 성공으로 응답한다. 직후 서버가 죽으면 재시작 복구는 커밋 레코드가 없는 그 트랜잭션을 loser로 보고 되돌린다. develop에서 서버 강제 종료 재현으로 이 결과를 확인했고, 비교 조건 하나를 고친 빌드에서는 같은 재현에서 손실이 없었다.

**영향**: 커밋 응답을 받은 뒤 그 결과를 믿고 다음 일을 하는 모든 응용(주문 확정, 계좌 이체, 다른 시스템으로의 전달 등)이, 서버 프로세스가 비정상 종료(kill -9, OOM killer, 크래시)되거나 호스트가 갑자기 꺼지면 이미 확정된 줄 아는 변경을 잃는다. 오류나 경고는 남지 않으므로 사용자는 손실을 알 수 없다. develop debug 빌드 재현에서는 서버를 20번 강제 종료할 때마다 1~3건의 손실이 났다(측정). 실제 운영 부하에서의 빈도, release 빌드에서의 빈도, HA 복제(applylogdb)에 주는 영향은 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 발견 경위

Sidecar 개발 브랜치의 24시간 서버 강제 종료 스트레스 시험에서, 클라이언트가 COMMIT 성공을 받은 트랜잭션의 변경이 재시작 뒤 사라졌다. 로그 덤프(`cubrid diagdb -d 8`)에서 그 트랜잭션은 UPDATE 로그 레코드는 디스크에 있었지만 `LOG_COMMIT` 레코드가 없었고, 재시작 복구가 보상 레코드로 되돌렸다. 같은 현상을 Sidecar 코드가 없는 develop에서도 재현해 develop 결함으로 판단했다(아래 Repro).

### 커밋 응답 경로

1. 커밋하는 트랜잭션은 `LOG_COMMIT` 레코드를 prior list에 넣고 그 시작 LSA를 받는다(`prior_lsa_next_record`). prior list는 `LOG_CS` 없이 로그 레코드를 모아 두는 메모리 목록이다.
2. `log_change_tran_as_completed` 가 `logpb_flush_pages (thread_p, lsa)` 를 부르며, `lsa` 는 1의 커밋 레코드 시작 LSA다([log_manager.c:4811](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_manager.c#L4811)).
3. `logpb_flush_pages` 는 log flush 데몬을 깨우고 `while (LSA_LT (&nxio_lsa, flush_lsa))` 동안 기다린다([log_page_buffer.c:4163](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_page_buffer.c#L4163), 루프 안 재확인 `LSA_GE` 는 [:4171](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_page_buffer.c#L4171)).
4. 대기가 끝나면 서버는 클라이언트에 커밋 성공을 응답한다.

### 대기가 일찍 끝나는 순서

로그 flush(`logpb_flush_pages_direct`)는 `LOG_CS` 안에서 prior list 전체를 로그 버퍼로 옮긴 뒤(`logpb_prior_lsa_append_all_list`) 디스크에 쓰고, `nxio_lsa` 를 그때의 `append_lsa`, 즉 **다음 레코드가 들어갈 위치**로 둔다([log_page_buffer.c:3894](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_page_buffer.c#L3894)).

1. 다른 트랜잭션의 커밋이나 log flush 데몬이 flush를 시작해 prior list를 비운다. 이때 `append_lsa` 를 X라 한다.
2. flush가 디스크에 쓰는 동안 트랜잭션 T가 `LOG_COMMIT` 을 prior list에 넣는다. 비운 뒤 다른 레코드보다 먼저 들어갔다면 이 레코드의 시작 LSA는 X다.
3. flush가 끝나고 `nxio_lsa = X` 가 된다. T의 커밋 레코드는 prior list에만 있다.
4. T가 `logpb_flush_pages (X)` 를 부른다. `LSA_LT (X, X)` 가 거짓이라 기다리지 않고 바로 돌아가며, 클라이언트는 커밋 성공을 받는다.
5. 다음 flush 전에 서버가 죽으면 디스크 로그에는 T의 변경 레코드만 있고 `LOG_COMMIT` 이 없다. 재시작 복구는 T를 되돌린다.

같은 파일의 WAL 판정은 이 경계를 반대로 본다. `logpb_need_wal` 은 `LSA_LE (&nxio_lsa, lsa)` 일 때 "아직 디스크에 없다"고 판정한다([log_page_buffer.c:11950](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_page_buffer.c#L11950)). 즉 LSA가 정확히 `nxio_lsa` 인 레코드를 WAL은 디스크에 없다고 보고, 커밋 대기는 디스크에 있다고 본다. 위 순서는 소스를 읽어 세운 추론이며, 재현의 손실 모양(매번 한 행이 마지막으로 응답받은 값보다 정확히 하나 작음)과 로그 덤프(변경 레코드는 있고 `LOG_COMMIT` 은 없음)와 맞는다.

`logpb_flush_pages` 의 다른 호출자도 같은 비교를 거친다. abort 레코드(서버 기동 뒤 체크포인트 조건에서만 flush), commit-with-postpone 레코드, HA 서버 상태 레코드, 2PC prepare와 decision 레코드(`log_2pc.c`)가 있다. 이들 경로의 영향은 확인하지 않았다.

## Test Build

- develop `81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953`, `CUBRID 11.5.0 (11.5.0.2902-81fa569) (64bit debug build for Linux)`, CMake preset `debug_gcc`.
- develop `e64a04a79a5842827a124b3f8313516d0da2594c` debug 빌드(Sidecar 시험에서 처음 대조한 merge-base).
- 커밋 관련 설정은 기본값(`async_commit=no`, group commit 비활성)이다. 재현 DB에는 vacuum을 자주 돌리는 아래 설정을 더했다. 이 설정이 재현에 필요한지는 따로 확인하지 않았다. Linux x86_64, 로컬 NVMe 디스크.

```
[@durdb]
vacuum_log_block_pages=4
vacuum_master_interval_in_msecs=1
max_clients=64
log_max_archives=4
```

## Repro

8개 세션이 각자 자기 행을 `UPDATE c SET n = <다음 값>` 하고, 그 응답을 받은 뒤 COMMIT을 보내는 일을 반복한다. COMMIT이 성공으로 돌아오면 그 값을 "응답받은 값"으로 기록한다. 3~12초 뒤 `cub_server` 에 SIGKILL을 보내고, 재시작 뒤 각 행의 `n` 이 응답받은 값 이상인지 확인한다. 이 순환을 20번 반복한다.

```sh
# CUBRID 환경(CUBRID, PATH, CUBRID_DATABASES, CUBRID_CONF_FILE)을 적용한 셸에서
mkdir -p "$CUBRID_DATABASES/durdb" && cd "$CUBRID_DATABASES/durdb"
cubrid createdb --db-volume-size=256M --log-volume-size=128M durdb en_US
# 위 [@durdb] 절을 cubrid.conf 에 추가한다
cubrid server start durdb
python3 commit_durability_repro.py durdb --cycles 20
```

`commit_durability_repro.py` 는 아래와 같다. `cubrid`, `csql`, `stdbuf` 만 쓴다. 손실이 있으면 종료 코드 1을 돌려준다.

```python
#!/usr/bin/env python3
"""Does an acknowledged COMMIT survive kill -9 of cub_server?

    python3 commit_durability_repro.py DBNAME [--cycles 20] [--writers 8]

Needs a CUBRID environment (CUBRID, PATH, CUBRID_DATABASES) and an existing database DBNAME whose server is running.
Each writer owns one row of table c and loops UPDATE c SET n = n + 1, then COMMIT, in its own csql session, waiting
for each statement before it sends the next. A writer records n as acknowledged once the COMMIT returned. After 3 to 12 s the script sends SIGKILL to cub_server, restarts it and
checks that each row holds at least its last acknowledged n.
"""

import argparse
import os
import random
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

BIN = Path(os.environ["CUBRID"]) / "bin"


def server_pid(db):
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            exe = os.readlink(proc / "exe")
            args = (proc / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if exe == str(BIN / "cub_server") and db.encode() in args:
            return int(proc.name)
    return None


def csql(db, sql):
    r = subprocess.run(["csql", "-C", "-u", "dba", "--no-auto-commit", "-t", "-N", "-c", sql, db],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stdout + r.stderr)
    return r.stdout


def read_rows(db):
    rows = {}
    for line in csql(db, "select id, n from c order by id").splitlines():
        p = line.split()
        if len(p) == 2 and p[0].isdigit():
            rows[int(p[0])] = int(p[1])
    return rows


def wait_ready(db):
    deadline = time.time() + 10
    while server_pid(db) is None and time.time() < deadline:
        time.sleep(0.5)
    if server_pid(db) is None:
        subprocess.run(["cubrid", "server", "start", db], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.STDOUT, start_new_session=True, check=True)
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            csql(db, "select 1")
            return
        except Exception:
            time.sleep(1)
    raise RuntimeError("server did not come back")


def writer(db, i, start, acked, stop, logdir):
    out = Path(logdir) / f"w{i}.out"
    p = subprocess.Popen(["stdbuf", "-oL", "csql", "-C", "-u", "dba", "--no-auto-commit", "-t", "-N", db],
                         stdin=subprocess.PIPE, stdout=out.open("wb"), stderr=subprocess.STDOUT)
    pos, n, k = 0, start, 0
    reader = out.open("rb")

    def run(sql):
        nonlocal pos, k
        k += 1
        mark = f"mk_{i}_{k}"
        p.stdin.write(f"{sql}\nselect '{mark}';\n".encode())
        p.stdin.flush()
        while True:
            reader.seek(pos)
            text = reader.read().decode(errors="replace")
            at = text.find(mark)
            if "ERROR" in (text if at < 0 else text[:at]) or p.poll() is not None:
                return False
            if at >= 0:
                pos += len(text[:at + len(mark)].encode())
                return True
            time.sleep(0.001)

    try:
        while not stop.is_set():
            n += 1
            if not run(f"update c set n = {n} where id = {i};") or not run("commit;"):
                return
            acked[i] = n
            p.stdin.write(b"commit;\n")
            p.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        reader.close()
        if p.poll() is None:
            p.kill()
            p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--cycles", type=int, default=20)
    ap.add_argument("--writers", type=int, default=8)
    args = ap.parse_args()
    db, W = args.db, args.writers
    rows = ", ".join(f"({i}, 0)" for i in range(W))
    csql(db, f"drop table if exists c; create table c (id int primary key, n int); insert into c values {rows}; commit;")
    logdir = tempfile.mkdtemp(prefix="commit_repro_")
    lost_total = 0
    for cycle in range(1, args.cycles + 1):
        base = read_rows(db)
        acked = dict(base)
        stop = threading.Event()
        ths = [threading.Thread(target=writer, args=(db, i, base[i], acked, stop, logdir), daemon=True)
               for i in range(W)]
        for t in ths:
            t.start()
        time.sleep(random.uniform(3, 12))
        pid = server_pid(db)
        os.kill(pid, signal.SIGKILL)
        stop.set()
        for t in ths:
            t.join(60)
        while server_pid(db) == pid:
            time.sleep(0.1)
        wait_ready(db)
        got = read_rows(db)
        lost = [(i, got.get(i), acked[i]) for i in range(W) if got.get(i) is None or got[i] < acked[i]]
        commits = sum(acked[i] - base[i] for i in range(W))
        print(f"cycle {cycle}: {commits} acknowledged commits, lost (row, after restart, acknowledged): {lost}",
              flush=True)
        lost_total += len(lost)
    print(f"{args.cycles} kills, {lost_total} lost acknowledged commits", flush=True)
    return 1 if lost_total else 0


if __name__ == "__main__":
    sys.exit(main())
```

## Expected Result

모든 순환에서 모든 행의 `n` 이 그 행이 마지막으로 응답받은 값 이상이다. 출력 마지막 줄이 `20 kills, 0 lost acknowledged commits` 다.

## Actual Result

| 빌드 | 시험 | 강제 종료 | 손실된 응답받은 커밋 |
|---|---|---|---|
| develop `81fa5696cd` debug | 위 스크립트 | 20 | 1 |
| develop `81fa5696cd` debug | 시험 A | 20 | 3 |
| develop `81fa5696cd` debug + 아래 수정 후보 | 시험 A | 20 | 0 |
| develop `e64a04a79a` debug | 시험 A | 20 | 5 |
| develop `e64a04a79a` debug + 아래 수정 후보 | 시험 A | 20 | 0 |

위 스크립트의 손실 한 건은 `cycle 3: 3719 acknowledged commits, lost (row, after restart, acknowledged): [(3, 1749, 1750)]` 이다. 시험 A는 같은 순서(8 세션, UPDATE 응답 뒤 COMMIT, 같은 SIGKILL 간격, 같은 DB 설정)를 다른 스크립트로 돌린 것이다. 차이는 표에 값이 NULL인 `BIT VARYING` 열이 하나 더 있고 DB 볼륨이 512M/256M이라는 점이다. 순환마다 응답받은 커밋 수가 더 많았다. 손실은 매번 한 행에서, 재시작 뒤 값이 마지막으로 응답받은 값보다 정확히 1 작은 모양이다. 즉 마지막으로 성공을 받은 커밋 하나가 통째로 사라졌다.

UPDATE, COMMIT, 확인용 SELECT를 한 번에 보내 서버에서 UPDATE와 COMMIT이 붙어 실행되게 한 변형은 develop `81fa5696cd` 에서 20번씩 두 번(기본 설정, 위 DB 설정) 강제 종료해도 손실이 없었다. 위 순서대로라면 T의 커밋 레코드가 flush가 prior list를 비운 직후의 첫 레코드여야 하므로, UPDATE와 COMMIT 사이에 클라이언트 왕복이 있어 그 사이에 flush가 끼어들 때 잘 드러나는 것으로 추정한다.

## Additional Information

### 수정 후보(ANALYSIS 검토 대상)

아래는 재현에서 손실을 없앤 변경이며, 해결 방안을 정한 것은 아니다. 대기 조건을 `nxio_lsa <= flush_lsa` 동안으로 바꿔, 커밋 레코드의 시작 LSA를 넘어서야(레코드가 디스크에 쓰여야) 대기를 끝낸다. `logpb_need_wal` 과 같은 경계다.

```diff
--- a/src/transaction/log_page_buffer.c
+++ b/src/transaction/log_page_buffer.c
@@ logpb_flush_pages (THREAD_ENTRY * thread_p, LOG_LSA * flush_lsa)
-      while (LSA_LT (&nxio_lsa, flush_lsa))
+      while (LSA_LE (&nxio_lsa, flush_lsa))
 	{
@@
 	  rv = pthread_mutex_lock (&group_commit_info->gc_mutex);
 	  nxio_lsa = log_Gl.append.get_nxio_lsa ();
-	  if (LSA_GE (&nxio_lsa, flush_lsa))
+	  if (LSA_GT (&nxio_lsa, flush_lsa))
 	    {
 	      pthread_mutex_unlock (&group_commit_info->gc_mutex);
 	      break;
```

이 변경이 안전하다는 근거와 남은 질문은 다음과 같다.

- 모든 호출자는 방금 prior list에 넣은 레코드의 시작 LSA를 넘긴다. 그래서 그 LSA에는 항상 레코드가 있고, 다음 flush가 그 레코드를 쓰면 `nxio_lsa` 가 그 뒤로 가서 대기가 끝난다(소스 읽기, 실행으로 모든 호출자를 확인하지는 않음).
- 레코드가 로그 페이지 끝에서 잘려 일부만 쓰인 경우 flush는 `nxio_lsa` 를 그 레코드의 시작(`append.prev_lsa`)에 둔다([log_page_buffer.c:3887](https://github.com/CUBRID/cubrid/blob/81fa5696cdd2fb5557abd58dcfe21ecc9e4ea953/src/transaction/log_page_buffer.c#L3887)). 새 조건은 이때도 기다린다. 지금 조건은 그 레코드를 기다리는 호출자를 기다리지 않게 하는데, 이 경로가 실제로 커밋을 잃게 하는지는 확인하지 않았다.
- 커밋 대기 시간이 늘 수 있다. 지금은 일찍 돌아가던 커밋이 flush 한 번을 더 기다리게 된다. 처리량과 응답 시간 영향은 측정하지 않았다.

### 관련 이슈

- CBRD-28046: postpone이 있는 트랜잭션의 커밋이 `logpb_flush_pages` 로 두 번 기다리는 성능 문제. 같은 대기 함수를 다루지만 문제는 다르다(불필요한 flush 대 너무 이른 대기 종료).
- CBRD-26885: COMMIT 응답 경로에서 내구성과 무관한 후처리를 떼어 내는 설계 검토. 그 검토는 "내구성은 커밋 로그가 디스크에 쓰인 시점에 확정된다"를 전제로 하며, 이 결함은 그 전제가 지금은 항상 지켜지지 않음을 보여 준다.

### ANALYSIS 확인 사항

- release 빌드와 운영 설정(group commit, `async_commit`)에서의 발생 빈도.
- HA 환경에서 마스터가 이 순서로 죽었을 때 슬레이브에 반영된 커밋과 마스터 복구 결과가 어긋나는지.
- 수정 후보가 커밋 처리량과 응답 시간에 주는 영향.
