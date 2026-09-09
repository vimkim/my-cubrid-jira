# [non-OOS] bug_bts_4633: `log_get_undo_record` 가 `append_lsa` 를 찢어진 값으로 읽어 assert 로 서버가 죽는 문제

## Issue Triage

**이슈 수행 목적**: 로그 append 위치(`log_Gl.hdr.append_lsa`) 를 읽는 쪽과 페이지를 넘기며 갱신하는 쪽이 경합해도 항상 일관된 8바이트 값이 오가도록 해서, bug_bts_4633 워크로드에서 `cub_server` 가 assert 로 죽지 않게 한다.

**이슈 수행 이유**:

| | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 40 스레드 JDBC 갱신·조회 워크로드(`shell/_06_issues/_11_1h/bug_bts_4633`) 를 optdebug (release 수준 최적화에 assert 를 살려 둔 빌드) 서버에 돌리면 드물게 undo 로그에서 이전 버전을 읽는 경로의 assert 가 터져 `cub_server` 가 core 를 남긴다. |
| **TO-BE (목표 상태 / 기대 동작)** | 이전 버전을 로그에서 읽는 조회가 append 페이지 전환 도중에도 정상 결과를 돌려주고 서버가 살아 있다. |
| **영향** | QA 실패 — GHA run 34186373809 shard 31 (PR #6864) 에서 `[NOK] core` 로 실패했다. 기존 결함이라 OOS 여부와 무관하게 optdebug CI 어디서든 재발한다. release 빌드는 이 assert 가 컴파일되지 않아 크래시 대신 찢어진 값이 조용히 다음 판단에 쓰인다. |

**이슈 수행 방안**:

- 이 실패는 OOS/CDC (change data capture — 로그에서 변경 내역을 뽑아내는 기능) 와 무관한 기존 결함으로 분류하고, CBRD-26939 와 PR #6864 의 판정에서 분리한다 (사용자 인용: "I think this is not related to oos cdc and cbrd-26939").
- `log_Gl.hdr.append_lsa` 를 8바이트 원자 값으로 발행·소비하는 방향을 제안한다. 후보 비교는 Remarks 에 둔다.
- 최종 수정 방식 (합의됨): `append_lsa` 를 8바이트 원자 값으로 발행·소비한다. `logpb_next_append_page` 가 새 위치를 지역 변수에 만들어 원자 store 하나로 발행하고, 락 없이 읽는 세 곳(`log_get_undo_record`, `heap_get_visible_version_from_log`, `logpb_fetch_page`)이 원자 load 하나로 지역 복사본을 만들어 비교한다. `assert` 는 유지한다 (Remarks 표의 1순위 후보).
- 회귀 아님: 원인 코드는 2016년(blame `63378ed15c`)부터 있던 기존 결함이라 제목의 `[Regression]` 태그를 뗀다.
- PR: <https://github.com/CUBRID/cubrid/pull/7904> (base `develop`, draft). 검증: 고친 optdebug 빌드에서 읽기/쓰기가 각각 8바이트 접근 하나로 바뀐 것을 디스어셈블로 확인했고, GDB 프로브로 옛 코드였다면 죽었을 페이지 전환을 잡아 고친 서버가 모두 견디는 것(core 0, assert 도달 0회)을 확인했다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**:

| 항목 | 내용 |
|---|---|
| 소스 | `src/transaction/log_manager.c` (`log_get_undo_record`, `log_get_append_lsa`), `src/transaction/log_page_buffer.c` (`logpb_next_append_page`, `logpb_fetch_page`), `src/storage/heap_file.c` (`heap_get_visible_version_from_log`) |
| 온디스크 / 프로토콜 | 변경 없음 |
| 빌드 조건 | 크래시는 optdebug 만. debug 는 구조체 복사가 8바이트 load 하나로 컴파일돼 찢어지지 않고, release 와 RelWithDebInfo 는 `-DNDEBUG` (`CMakeLists.txt:230-233`) 로 이 `assert` 가 사라진다 |
| 사용자 영향 | optdebug 서버는 프로세스가 내려가 모든 세션이 끊긴다. release 에 남는 위험은 크래시가 아니라 찢어진 값이 판단에 쓰이는 쪽이다 (Description 의 "같은 뿌리의 다른 노출") |

---

## Description

### 배경 용어

`LOG_LSA` (log sequence address — 로그 안의 위치) 는 8바이트 하나에 `pageid:48` 과 `offset:16` 비트필드를 담은 구조체다 (`log_lsa.hpp:36-40`). `log_Gl.hdr.append_lsa` 는 다음 로그 레코드가 로그 페이지 버퍼에 놓일 위치다. 새 로그 레코드는 먼저 prior list (로그 페이지 버퍼에 옮겨지기 전에 레코드를 모아 두는 연결 리스트) 에 들어가고, `logpb_prior_lsa_append_all_list` 가 `LOG_CS` (로그 전역 임계 구역) 를 잡고 이 리스트를 페이지 버퍼로 옮기면서 `append_lsa` 를 전진시킨다. 현재 append 페이지가 꽉 차면 `logpb_next_append_page` 가 `pageid` 를 1 올리고 `offset` 을 0 으로 되돌린다 (페이지 전환).

MVCC (다중 버전 동시성 제어) 조회가 스냅샷보다 새 버전을 만나면 `heap_get_visible_version_from_log` 가 레코드에 적힌 `prev_version_lsa` 를 따라 undo 로그에서 이전 버전을 꺼낸다. 이때 `log_get_undo_record` 는 "이 주소가 아직 prior list 에 있지 않다" 는 뜻으로 다음을 검사한다.

```c
oldest_prior_lsa = *log_get_append_lsa ();                /* log_manager.c:9855 */
assert (LSA_LT (&process_lsa, &oldest_prior_lsa));        /* log_manager.c:9856 */
```

### 근본 원인: 읽기가 두 번, 쓰기가 두 번

읽는 쪽은 락을 잡지 않는다. 최적화 컴파일러는 지역 복사본 `oldest_prior_lsa` 를 만들지 않고 비교에 필요한 필드를 메모리에서 따로 읽는다. CI 바이너리(GCC 8.5.0) 의 실제 코드다.

```
log_get_undo_record  (libcubrid.so.11.5, BuildID 2d15b112..., GCC 8.5.0)
 +40   call  log_get_append_lsa
 +52   mov   (%rax),%rcx            ★ LOAD 1: 8바이트 → pageid 만 사용
 +66   cmp   %rdx,%rsi ; jg  +144      append.pageid > process.pageid 이면 통과
 +71   xor   -0x4048(%rbp),%rcx ; test ; jne +106   pageid 가 다르면 assert
 +93   movzwl -0x4042(%rbp),%edx        process.offset
 +100  cmp   0x6(%rax),%dx           ★ LOAD 2: offset 을 메모리에서 다시 읽음 (LOAD 1 뒤 약 10 명령)
 +104  jl    +151                       process.offset < append.offset 이면 통과
 +106  ... call __assert_fail
```

로컬 GCC 11.5 optdebug 빌드도 모양이 같다 (`+45 mov (%rax),%rcx`, `+48 movzwl 0x6(%rax),%esi`).

쓰는 쪽 `logpb_next_append_page` (`log_page_buffer.c:2658-2659`) 는 두 문장을 두 store 로 낸다.

```
 mov  %rax,0x118(%rbx)      ★ STORE 1: pageid++ 를 8바이트 read-modify-write 로 → (P+1, 예전 offset)
 xor  %eax,%eax
 mov  %ax,0x11e(%rbx)       ★ STORE 2: offset = 0 을 2바이트 store 로            → (P+1, 0)
```

x86 은 store 순서를 지키므로, 읽는 스레드의 LOAD 1 이 STORE 1 앞에 오고 LOAD 2 가 STORE 2 뒤에 오면 비교값은 `(P, 새 페이지의 어린 offset)` 이 된다. 로그가 한 번도 가진 적 없는 주소다. `process_lsa` 가 페이지 P 위에 있으면 (직전에 갱신된 행의 이전 버전은 거의 항상 현재 append 페이지에 있다) `LSA_LT` 가 거짓이 되어 assert 가 터진다.

```
읽는 스레드 (log_get_undo_record)         쓰는 스레드 (logpb_next_append_page, LOG_CS 보유)
LOAD 1  word = (P, 16328)
                                          STORE 1  append_lsa = (P+1, 16328)
                                          STORE 2  append_lsa = (P+1, 0)
                                          ... 새 페이지에 레코드 추가 → (P+1, 48)
LOAD 2  offset = 48
비교값 = (P, 48)  vs  process_lsa = (P, 15112)  →  LSA_LT 거짓  →  assert
```

### 이 assert 만 터지는 이유

호출자 `heap_get_visible_version_from_log` (`heap_file.c:26369-26377`) 는 같은 주소를 먼저 검사하고, 필요하면 `LOG_CS` 아래에서 prior list 를 flush 한 뒤 `!LSA_LT (append, prev)` 를 assert 한다. `logpb_fetch_page` (`log_page_buffer.c:1740`) 도 `LOG_CS` 아래에서 다시 확인한다. `append_lsa` 는 단조 증가하고, 레코드에 적히는 `prev_version_lsa` 는 `tdes->tail_lsa`, 즉 `prior_lsa_next_record_internal` 이 `prior_lsa_mutex` 한 번 잡은 동안 주소를 배정하고 리스트에 연결한 값이다 (`log_append.cpp:1359-1522`, `:1619`). 그래서 값이 일관되게 읽히기만 하면 `log_get_undo_record` 시점에는 항상 `append > prev` 다. CI 스택처럼 "호출자 검사는 통과, 엄격 부등호만 실패" 가 나오려면 `prev == append` 여야 하는데 구조적으로 불가능하다. 찢어진 읽기만이 이 서명을 만든다. 아래 재현에서 잡은 값들이 이를 그대로 보여 준다.

초기 분석에서 나온 다른 두 가설도 같은 값으로 배제된다. 레코드에 잘못된 `prev_version_lsa` 가 적혔다면 잡힌 `process_lsa` 가 LOAD 1 시점의 일관된 append 위치보다 앞에 있을 수 없고, `heap_file.c:26377` 이 먼저 터진다. undo 레코드가 아직 prior list 에 남아 있었다면 역시 `process_lsa` 가 append 위치 뒤에 있어야 하는데, 네 번 모두 앞에 있었다.

### 왜 드문가

자연 상태의 창은 몇 ns (로컬 빌드는 인접 두 명령, GCC 8 빌드는 약 10 명령) 이고, 그 안에 다른 스레드의 두 store 가 모두 들어와야 한다. 나머지 조건은 이 워크로드에서 거의 항상 참이다. 이전 버전이 현재 append 페이지에 있었던 비율은 시도별로 82/82, 74/135, 34/34 였고, 새 페이지의 어린 offset 은 옛 페이지의 거의 모든 offset 보다 작다. 로그 페이지는 16 KB 이고 40 개 스레드가 인덱스 딸린 `t1` 을 계속 갱신하므로 페이지 전환이 잦다. 브레이크포인트로 느려진 서버에서도 4.7 초에 8 회였다 (gdb-04). 디버거 없이 시나리오 7 만 10 회 돌린 로컬 실행은 모두 깨끗했고, CI 에서는 1 회 관측됐다.

### 같은 뿌리의 다른 노출 (재현하지 않음)

STORE 1 과 STORE 2 사이에는 `(P+1, 예전 offset)` 이라는, 실제보다 앞선 위치가 잠깐 보인다. 8바이트를 한 번에 읽는 쪽 (`heap_file.c:26369`, `logpb_fetch_page`) 이 P+1 페이지의 레코드를 찾다가 이 값을 보면 prior list flush 를 건너뛰거나 아직 만들어지지 않은 로그 페이지를 복사하려 할 수 있다. 같은 수정으로 함께 닫혀야 한다.

## Test Build

- CI: `CUBRID 11.5.0 (11.5.0.2634-2940b1c) (64 optdebug build)`, PR #6864 head `2940b1cfbc3c2d4d0fac3f9244a960350debd380`, 컴파일러 `GCC 8.5.0 20210514 (Red Hat 8.5.0-28)`, `libcubrid.so.11.5` BuildID `2d15b11204389cb271f79f0403a11645a494d72b` (내부 아티팩트 서버 `http://192.168.1.48:30080/builds/pr/2940b1c.../debug/CUBRID/`).
- 로컬 재현: 같은 커밋의 optdebug 빌드, GCC 11.5.0, Rocky Linux 9.6 (kernel 5.14).
- 원인 코드 blame: `63378ed15c` (2016-05-06). `feat/oos` 와 `origin/develop` 의 관련 코드가 바이트 단위로 같다.

## Repro

### 1. 자연 재현 (확률 낮음)

CTP (CUBRID 테스트 플랫폼) shell 로 테스트를 그대로 돌린다. `shell_ci.conf` 의 `scenario` 를 `cubrid-testcases-private-ex/shell/_06_issues/_11_1h/bug_bts_4633` 으로 맞춘다.

```bash
ctp.sh shell -c conf/shell_ci.conf
```

스크립트 결과가 OK 여도 `cases/` 아래 `core.*` 와 서버 에러 로그를 확인해야 한다. 로컬 10 회에서는 재현되지 않았다.

### 2. 결정적 재현 (GDB 로 두 load 사이의 창을 넓힘)

데이터베이스 내용은 건드리지 않고, `log_get_undo_record` 의 LOAD 1 과 LOAD 2 사이에서 스레드를 잠깐 멈춰 다른 스레드가 페이지를 넘길 시간을 준다. 아래 오프셋(`+48`, `+117`) 은 2940b1c GCC 11.5 optdebug 기준이며, 다른 빌드에서는 `disassemble log_get_undo_record` 로 `call log_get_append_lsa` 다음의 `mov (%rax),%rcx` 바로 뒤 명령과 assert 분기 진입 명령을 확인해 맞춘다. `process_lsa` 는 DWARF 위치 정보로 읽으므로 빌드마다 고칠 필요가 없다. `+117` 시점의 `rsi` 가 LOAD 2 값인 것도 GCC 11.5 빌드 기준이다.

```bash
ulimit -c unlimited
export CTP_HOME=/path/to/CTP                      # cubrid-testtools 의 CTP 디렉터리
cubrid createdb -r db_4633 en_US.utf8 && cubrid server start db_4633 && cubrid broker start
cd cubrid-testcases-private-ex/shell/_06_issues/_11_1h/bug_bts_4633/cases
printf '<ShellConfig><ip>localhost</ip><port>33000</port></ShellConfig>\n' > shell_config.xml   # 브로커 포트
export REAL_INIT_PATH=$PWD CLASSPATH=$CUBRID/jdbc/cubrid_jdbc.jar:$CTP_HOME/shell/init_path/commonforjdbc.jar:.
javac TestBasel.java Scenario.java
gdb -nx -q -batch -iex 'set non-stop on' -iex 'set pagination off' -iex 'set confirm off' \
    -x probe.py -p "$(pgrep -x cub_server)" > gdb.log 2>&1 &
sleep 3
java -Xms1024m -Xmx1024m -XX:MaxPermSize=512m -XX:+UseParallelGC TestBasel > java.log 2> error.log
```

`probe.py`:

```python
import gdb, time
MASK = 0xffffffffffff
def lsa(w):
    p = w & MASK
    if p & (1 << 47): p -= 1 << 48
    o = (w >> 48) & 0xffff
    if o & 0x8000: o -= 0x10000
    return (p, o)
def u64(addr):
    return int.from_bytes(bytes(gdb.selected_inferior().read_memory(addr, 8)), "little")
def reg(f, name):
    return int(f.read_register(name).cast(gdb.lookup_type("unsigned long")))
def process_lsa_word():                           # 스필된 인자 process_lsa 를 DWARF 위치로 읽는다
    return int(gdb.parse_and_eval("*(unsigned long *) &process_lsa"))
APPEND = int(gdb.parse_and_eval("(unsigned long)&log_Gl.hdr.append_lsa"))
PRIOR = int(gdb.parse_and_eval("(unsigned long)&log_Gl.prior_info.prior_lsa"))
HIT = []
class Pause(gdb.Breakpoint):                      # LOAD 1 과 LOAD 2 사이
    def stop(self):
        word1 = reg(gdb.selected_frame(), "rcx")
        proc = process_lsa_word()
        if lsa(word1)[0] != lsa(proc)[0] or lsa(u64(PRIOR))[0] <= lsa(word1)[0]:
            return False                          # 이전 버전이 현재 페이지가 아니거나, 다음 flush 가 페이지를 넘기지 않음
        t0 = time.monotonic()
        while time.monotonic() - t0 < 0.2 and lsa(u64(APPEND))[0] <= lsa(word1)[0]:
            time.sleep(0.0002)                    # 다른 스레드가 prior list 를 flush 해 페이지를 넘길 때까지
        print("paused: word1=%s process_lsa=%s append_now=%s" % (lsa(word1), lsa(proc), lsa(u64(APPEND))))
        return False
class Stop(gdb.Breakpoint):
    def stop(self):
        HIT.append(gdb.selected_thread()); return True
Pause("*log_get_undo_record+48"); Stop("*log_get_undo_record+117"); Stop("__assert_fail")
while not HIT:
    gdb.execute("continue -a")                    # attach 직후 idle 스레드의 가짜 stop 은 그냥 재개
HIT[0].switch()
f = gdb.selected_frame()
if f.name() and "log_get_undo_record" in f.name():   # +117 에서 rcx 는 이미 word1 XOR process_lsa 다
    proc = process_lsa_word()
    print("word1=%s load2_offset=%d process_lsa=%s append_now=%s"
          % (lsa(reg(f, "rcx") ^ proc), reg(f, "rsi") & 0xffff, lsa(proc), lsa(u64(APPEND))))
gdb.execute("bt 8")                               # 다른 assert 였다면 스택만 남긴다
gdb.execute("detach")                             # 서버는 그대로 abort 하고 core 를 남긴다
```

## Expected Result

7 개 시나리오가 끝날 때까지 `cub_server` 가 살아 있고, 스냅샷보다 새 버전을 만난 조회는 undo 로그에서 이전 버전을 읽어 정상 결과를 돌려준다. `cases/` 아래에 core 가 없다.

## Actual Result

CI 에서는 테스트 스크립트가 `bug_bts_4633-1 : OK` 를 찍었다. Java stderr 에 무엇이든 찍혀 있으면 (여기서는 `-XX:MaxPermSize` JVM 경고) 결과와 무관하게 OK 로 처리하는 예외 분기(CUBRIDSUS-15963) 때문이다. 실패는 CTP 의 core 감지가 `[NOK]` 로 보고했다 (GHA run 34186373809 shard 31).

```
SUMMARY : [Core dumped in log_get_undo_record at src/transaction/log_lsa.hpp:173]
#7  __assert_fail
#8  log_get_undo_record (process_lsa=...)                      log_lsa.hpp:173 (operator< inline, log_manager.c:9856)
#9  heap_get_visible_version_from_log                          heap_file.c:26399
#10 heap_get_visible_version_internal
#11 heap_scan_get_visible_version_impl
#12 heap_next_internal
#13 heap_next
#14 scan_next_heap_scan                                        scan_manager.c:5934
#18 qexec_intprt_fnc                                           query_executor.c:9496
```

로컬 GDB 재현 4 회 (2940b1c optdebug, 모두 `+117` 진입 → `__assert_fail` → SIGABRT → core):

| 시도 | 워크로드 | 창 넓힘 | 발생 시점 | LOAD 1 | `process_lsa` | LOAD 2 offset | 비교값 | 호출 경로 |
|---|---|---|---|---|---|---|---|---|
| gdb-02 | 7 시나리오 전체 | 200 ms 이내 대기 | 약 6 초 (시나리오 1) | (201, 16328) | (201, 15112) | 48 | (201, 48) | 인덱스 스캔: `heap_get_visible_version` ← `scan_next_index_lookup_heap` ← `qexec_execute_update` |
| gdb-03 | 시나리오 7 만 | 200 ms 이내 대기 | 6.6 초 | (208, 15488) | (208, 14720) | 3912 | (208, 3912) | CI 와 동일: `heap_next` ← `scan_next_heap_scan` ← `qexec_intprt_fnc` |
| gdb-04 | 7 시나리오 전체 | 없음 (브레이크포인트의 ptrace stop 만) | 4.7 초 | (182, 16368) | (182, 15976) | 712 | (182, 712) | 인덱스 스캔 |
| gdb-05 | 시나리오 7 만 | 위 `probe.py` 그대로 | 약 3 초 | (204, 11968) | (204, 11416) | 1224 | (204, 1224) | CI 와 동일 |

네 번 모두 `process_lsa` 는 LOAD 1 시점의 일관된 append 위치보다 앞에 있는, 이미 페이지 버퍼에 들어간 정상 레코드였다. gdb-04 는 인위적 대기 없이 브레이크포인트 처리에 드는 ptrace (디버거가 프로세스를 세우는 커널 인터페이스) stop 시간(1 ms 미만) 만으로 5 초 안에 재현됐다.

## Additional Information

- GHA job: <https://github.com/CUBRID/cubrid/actions/runs/34186373809/job/101937472116>, 테스트 리비전 `01af62db73351ea3fdb445ccd03a19c39084d1cc` (`tc/pr-6864`). 같은 shard 의 `cbrd_27064` (CDC) 실패와는 별개다.
- 호출자의 `oldest_prior_lsa = *log_get_append_lsa ();  /* TODO: fix atomicity issue on x86 */` (`heap_file.c:26369`) 주석이 같은 문제를 가리키고 있다.
- 테스트 테이블은 정수 컬럼만 있어 OOS 값이 생성되지 않고, 실패 경로는 일반 MVCC 이전 버전 읽기다.
- 상세 진단, 프로브 전체 소스, 두 바이너리의 디스어셈블, core backtrace: `my-cubrid-docs/cbrd-27400/2940b1c_claude/` (`bug_bts_4633-diagnosis.md`, `evidence/`).

## Remarks

수정 방향 후보:

| 순위 | 후보 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | `append_lsa` 를 8바이트 원자 값으로 발행·소비 | `logpb_next_append_page` 에서 새 LSA 를 만들어 `__atomic_store_n` (또는 `std::atomic_ref<int64_t>`) 한 번으로 쓰고, 락 없는 읽기 (`log_get_undo_record`, `heap_get_visible_version_from_log`, `logpb_fetch_page`) 는 `__atomic_load_n` 으로 지역 복사본을 만든 뒤 필드를 본다. 같은 뿌리의 다른 노출도 함께 닫힌다. 비용 없음. |
| 2 | 비교 구간에서 `LOG_CS` 획득 | 정확하지만 조회 경로가 전역 락을 더 자주 잡는다. 이미 호출자가 필요할 때만 잡는 구조라 뒤로 가는 변경이다. |
| 3 | `log_get_undo_record` 의 assert 제거·완화 | 증상만 감춘다. 찢어진 값이 다른 판단에도 쓰이므로 비권장. |

JDBC 시나리오 수준의 회귀 테스트로는 ns 단위 창을 고정할 수 없다. 위 GDB 프로브가 재현 가능한 검증 수단이며, 수정 후에는 같은 프로브에서 `+117` 이 도달하지 않아야 한다.
