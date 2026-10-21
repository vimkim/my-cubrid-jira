# [PGBUF] 일반 중첩 READ-to-WRITE fix의 BCB와 holder 회계 불일치를 해소한다

## Issue Triage

**이슈 수행 목적**: 같은 스레드의 일반 중첩 READ-to-WRITE 요청을 처리한 뒤에도 성공한 fix와 대응 unfix의 회계가 일치하도록 한다. 일반 승격을 허용할지 거부할지는 API 계약 확인 후 결정한다.

**이슈 수행 이유**: 단독 READ holder가 일반 `pgbuf_fix(..., PGBUF_LATCH_WRITE, ...)`를 호출하면 현재 분석 기준 소스는 BCB의 `fcnt`를 `1`로 저장하면서 holder의 `fix_count`는 증가시킨다. 과거 SA 직접 호출 probe에서는 이 불일치와 첫 unfix의 조기 래치 해제, 후속 unfix의 assertion 또는 내부 오류가 기록되었다.

**영향**: 해당 내부 API 호출 순서를 사용하는 엔진 코드에서 남은 fix가 있는데도 페이지 래치가 해제될 수 있다. 역사적 debug probe의 중단과 release probe의 내부 오류는 확인되었으나, 일반 SQL로 이 순서에 도달하는 경로, 운영 발생 빈도, 데이터 손상 및 영향 릴리스 범위는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 일반 READ-to-WRITE fix의 계약, 호출부 호환성, 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼의 fix는 메모리에 적재된 페이지의 사용을 계상하고 요청한 페이지 래치를 획득하는 작업이며, unfix는 그 사용을 반환한다. 페이지 래치는 메모리 페이지 접근을 조정하는 단기 동기화 수단이다. 트랜잭션의 논리적 접근을 제어하는 transaction lock과 구분한다. BCB(Buffer Control Block)는 버퍼 슬롯의 제어 상태이고, 여기의 `fcnt`는 해당 BCB 전체의 미반환 fix 수를 나타낸다. `PGBUF_HOLDER::fix_count`는 한 스레드가 그 BCB에 가진 미반환 fix 수를 나타낸다. 두 값이 같은 조건은 그 스레드가 유일한 holder인 경우이며, 여러 holder가 있는 경우 각 holder의 수와 BCB 전체 수를 구분해야 한다.

이 이슈의 조건은 같은 스레드가 같은 VPID(volume/page 식별자)의 페이지를 READ로 한 번 이상 fix한 뒤, 기존 fix를 반환하지 않고 일반 `pgbuf_fix`로 WRITE를 추가 요청하는 경우다. 전용 `pgbuf_promote_read_latch` 호출이나 watcher를 사용하는 ordered fix와는 구별한다.

2026-10-21 분석 기준 커밋 `f6cac312310f39f46711693da157a08f0e725693`의 `pgbuf_latch_bcb_upon_fix`는 기존 래치가 READ이고 `old_impl.impl.fcnt == holder->fix_count`이면 즉시 WRITE를 허용한다. 이때 `new_impl.impl.fcnt = 1`을 CAS로 저장한 뒤 공통 성공 처리에서 `holder->fix_count++`를 실행한다. 따라서 다른 holder가 없는 `READ, READ, WRITE` 호출 순서에서는 BCB 수가 `1, 2, 1`, holder 수가 `1, 2, 3`이 되는 경로가 존재한다. 이 대입과 holder 증가는 `SA_MODE`와 `SERVER_MODE`에 공통인 코드에 있다. [현재 승격 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6361-L6410), [공통 성공 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6452-L6495)를 근거로 한다.

일반 승격이 허용되는 API라면 새로 성공한 WRITE fix까지 계상해야 한다. 금지되는 API라면 기존 READ 사용을 보존하며 실패해야 한다. 어느 계약을 택하더라도 성공으로 반환하면서 두 회계를 다르게 만드는 상태는 해소해야 한다. 현재 API의 허용 정책은 합의가 확인되지 않았다.

### 왜 문제인가

unfix는 holder 수를 감소시키고, BCB 수를 감소시킨 결과가 `0`이면 `PGBUF_NO_LATCH`로 전환한다. 위의 불일치가 만들어지면 첫 unfix에서 BCB는 `1 -> 0`으로 전환하지만 holder에는 두 번의 반환 의무가 남는다. 이는 호출자가 성공한 fix마다 정확히 unfix해도 페이지 접근 보호가 먼저 끝날 수 있음을 뜻한다. [holder 감소](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6103-L6135), [BCB 감소와 래치 해제](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6633-L6661)를 근거로 한다.

과거 직접 호출 probe는 실제로 첫 unfix 후 holder가 `2`인데 BCB는 `0/NO_LATCH`가 된 상태를 기록했다. debug 실행은 두 번째 unfix에서 assertion으로 중단되었고, 별도 release 실행은 두 번째와 세 번째 unfix에서 `ER_PB_UNFIXED_PAGEPTR`에 해당하는 내부 오류 `-19`를 기록했다. 이는 내부 API 회계와 진단의 실패를 입증한다. 다른 스레드가 이 틈에 페이지를 사용하는 동시 실행 결과나 SQL 오동작, 데이터 손상을 관측한 기록은 아니다. 빌드별 근거는 아래에 구분한다.

### 왜 해결해야 하는가

fix/unfix의 대응은 페이지 버퍼 호출자가 의존하는 기본 수명 규칙이다. 이를 지켜도 조기 해제와 내부 오류가 생기는 경로를 남기면 엔진 변경 시 API를 안전하게 사용하고 실패를 진단하기 어렵다. 일반 승격을 허용하는지 불명확한 상태도 새 호출부와 회귀 테스트의 기대값을 정하지 못하게 한다. 현재 기준 소스에 문제 경로가 남아 있고 역사적 직접 재현도 있으므로, 도달 가능한 호출부와 계약을 확인하고 회계 일관성을 보장하는 작업이 필요하다.

전용 승격 API는 기존 fix의 래치 모드를 바꾸는 작업이다. 현재 소스의 단독 holder 즉시 승격은 `fcnt`를 바꾸지 않으며, SERVER_MODE 대기 경로는 기존 `fix_count`를 저장해 대기 요청과 새 holder에 전달한다. 따라서 새 fix를 하나 추가하는 일반 호출을 전용 승격으로 이름만 바꾸면 반환 횟수와 오류 처리까지 달라질 수 있다. 이 관찰은 전용 API 전체의 무결성 보장이나 모든 호출부에 대한 우회책 검증을 뜻하지 않는다. [전용 승격의 즉시 처리와 대기 준비](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2825-L2918), [기존 수 복원과 SA 분기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2924-L2981)를 근거로 한다. 긴급도와 고객 노출 범위는 추가 근거 없이 단정하지 않는다.

## Test Build

| 구분 | 빌드 또는 소스 식별 | 확인 범위와 한계 |
|---|---|---|
| 이번 정적 확인 | CUBRID `f6cac312310f39f46711693da157a08f0e725693` | 위 대입과 성공·unfix 제어 흐름을 확인했다. 이 커밋에서 runtime probe를 새로 실행하지 않았다. |
| 최초 이슈의 실행 보고 | Linux, 64-bit debug, `11.5.0.2431-198b42a` | 기존 이슈가 SA probe의 BCB `1`/holder `3` 출력을 보고한다. 이 빌드와 아래 실행을 같은 빌드로 취급하지 않는다. |
| 최초 이슈의 교차 확인 보고 | `f799e05d77d5300c6ea5753b4a6cc7caee6d8912`, debug/release SA | 기존 이슈의 보고를 보존한다. 이번 검토에서 이 조합의 원시 실행 로그를 별도로 확보하지 못했다. |
| 2026-09-04 후속 검증 보고의 debug 실행 | Linux, SA, `5f3a30d0998beafcc3932ed8cf65e66020a53c4c` | 보존된 debug 로그에서 holder 관측, 첫 unfix 후 조기 해제와 두 번째 unfix의 SIGABRT를 확인했다. |
| 같은 후속 검증 보고의 release 실행 | Linux, SA, develop `0888ccb`, 2026-08-03 설치본으로 기록 | 보존된 release 로그에서 조기 해제와 후속 오류 `-19`를 확인했다. 보고에는 짧은 커밋만 기록되어 있으며 debug와 동일 커밋의 비교 실행이 아니다. |

최초 보고는 [기존 이슈의 보존된 원문](https://github.com/vimkim/my-cubrid-jira/blob/da39b0f3ee0bc1c55d2063588c3969a808a95687/issues/CBRD-27370-pgbuf-read-write-fix-count_5f3a30d_codex.md#L48-L54), 후속 실행의 빌드 식별은 [2026-09-04 검증 보고서](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/CBRD-27370-claim-verification-report_5f3a30d_claude.md#L56-L92)를 근거로 한다. 보존 로그 자체에는 전체 빌드 정보가 모두 포함되지 않아 빌드 귀속은 해당 보고에 따른다. 별도 릴리스 태그와 SERVER_MODE 실행은 이번 검토에서 시험하지 않았다.

## Repro

### 보존된 재현 자료

후속 검증의 [probe 소스](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/repro/cbrd27370_probe.cpp)와 [GDB 스크립트](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/repro/cbrd27370_probe.gdb)를 사용한다. 이 probe는 임시 DB의 VPID `{0, 0}`에 같은 스레드로 `READ, READ, WRITE`를 일반 `pgbuf_fix`로 요청한 뒤 세 번 unfix한다. 각 단계에서 BCB 수와 래치 모드를 출력하고 GDB가 holder 수를 읽는다.

최초 이슈에 실린 `/tmp/vs18_probe.cpp`는 WRITE 직후 `_Exit`하므로 그 코드만으로는 후속 unfix 결과를 확인할 수 없다. 위의 보존된 후속 probe에는 세 번의 unfix가 포함되어 있다. 이는 엔진 내부 API를 직접 호출하는 진단 프로그램이며 SQL 재현문이 아니다. 해제 이후에도 상태 관측을 위해 포인터를 읽고 `_Exit`로 종료하므로 일반 애플리케이션의 사용 예제로 삼지 않는다.

### 현재 기준 재검증 절차

아래는 이번에 실행하지 않은 재검증 절차다. Linux의 CUBRID 빌드 의존성, C++ 컴파일러, GDB, curl이 필요하다. 소스와 하위 모듈을 준비하고 CMake로 구성한 SA 포함 빌드 디렉터리가 있어야 한다. `SOURCE_ROOT`와 `BUILD_ROOT`는 같은 커밋·구성의 경로를 지정한다. debug 심볼이 있어야 GDB가 holder를 관측할 수 있다. release 검증에서는 빌드 구성과 함께 `PROBE_MODE=release`를 사용해 헤더의 `pgbuf_fix_release` 매핑에 맞춘다.

```bash
SOURCE_ROOT=/absolute/path/to/cubrid
BUILD_ROOT=/absolute/path/to/matching-cmake-build
PROBE_MODE=debug
PROBE_ROOT=$(mktemp -d /tmp/cbrd27370.XXXXXX)
PROBE_INSTALL="$PROBE_ROOT/install"
PROBE_DATA="$PROBE_ROOT/data"
EVIDENCE_BASE=https://raw.githubusercontent.com/vimkim/my-cubrid-docs/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/repro

cmake --build "$BUILD_ROOT"
cmake --install "$BUILD_ROOT" --prefix "$PROBE_INSTALL"
curl --fail --location "$EVIDENCE_BASE/cbrd27370_probe.cpp" -o "$PROBE_ROOT/probe.cpp"
curl --fail --location "$EVIDENCE_BASE/cbrd27370_probe.gdb" -o "$PROBE_ROOT/probe.gdb"

PROBE_CXXFLAGS=()
if [ "$PROBE_MODE" = release ]; then
  PROBE_CXXFLAGS+=(-DNDEBUG)
fi
g++ -std=gnu++17 -g -O0 "${PROBE_CXXFLAGS[@]}" \
  -DSA_MODE -DLINUX -DGCC -DI386 -DX86 -DSYSV -D_GNU_SOURCE \
  -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE -D_REENTRANT \
  -I"$BUILD_ROOT" -I"$SOURCE_ROOT/include" \
  -I"$SOURCE_ROOT/src/api" -I"$SOURCE_ROOT/src/base" \
  -I"$SOURCE_ROOT/src/compat" -I"$SOURCE_ROOT/src/storage" \
  -I"$SOURCE_ROOT/src/thread" -I"$SOURCE_ROOT/src/transaction" \
  -I"$SOURCE_ROOT/src/communication" -I"$SOURCE_ROOT/src/connection" \
  -I"$SOURCE_ROOT/src/monitor" -I"$SOURCE_ROOT/src/object" \
  -I"$SOURCE_ROOT/src/query" -I"$SOURCE_ROOT/src/xasl" \
  -I"$SOURCE_ROOT/cubrid-cci/src/cci" \
  -I"$BUILD_ROOT/3rdparty/include" \
  -I"$BUILD_ROOT/3rdparty/Source/lz4/lib" \
  -I"$BUILD_ROOT/3rdparty/Source/rapidjson/include" \
  "$PROBE_ROOT/probe.cpp" -L"$PROBE_INSTALL/lib" \
  -Wl,-rpath,"$PROBE_INSTALL/lib" -lcubridsa -lpthread -ldl \
  -o "$PROBE_ROOT/probe"

mkdir -p "$PROBE_DATA/db" "$PROBE_DATA/registry"
export CUBRID="$PROBE_INSTALL"
export CUBRID_DATABASES="$PROBE_DATA/registry"
export LD_LIBRARY_PATH="$PROBE_INSTALL/lib:$PROBE_INSTALL/cci/lib"
"$PROBE_INSTALL/bin/cubrid" createdb -F "$PROBE_DATA/db" -L "$PROBE_DATA/db" \
  cbrd27370_probe en_US.utf8
cd "$PROBE_DATA/db"
gdb -q -batch -x "$PROBE_ROOT/probe.gdb" \
  --args "$PROBE_ROOT/probe" cbrd27370_probe > "$PROBE_ROOT/run.log" 2>&1
cat "$PROBE_ROOT/run.log"
```

결과에는 소스 전체 커밋, 실제 라이브러리의 빌드 문자열, CMake 구성, OS 및 debug/release 구성을 함께 기록해야 한다. GDB 실행 명령의 종료 코드만으로 성공을 판정하지 않고 각 단계의 수·래치·오류 및 중단 위치를 확인한다. 이 절차는 단독 holder의 직접 호출 재검증이며, 다른 holder나 WRITE 대기자와의 동시 실행 검증은 별도로 설계해야 한다.

## Expected Result

일반 승격을 허용하기로 한다면 같은 단독 holder의 `READ, READ, WRITE` 성공 후 BCB와 holder 수가 모두 `3`이어야 한다. 이후 세 번의 unfix에서 두 수가 `2, 1, 0`으로 감소하고 마지막 반환 전까지 WRITE 접근 보호가 유지되어야 한다.

일반 승격을 거부하기로 한다면 세 번째 호출은 실패하고 기존 상태인 BCB `2`, holder `2`, READ를 보존해야 한다. 기존 두 fix는 두 번의 unfix로 정상 반환되어야 한다. 허용 정책의 선택 자체는 ANALYSIS 대상이다.

## Actual Result

보존된 [debug 원시 로그](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/repro/run_debug.log#L12-L32)는 다음 상태와 두 번째 unfix의 SIGABRT를 기록한다.

```text
단계             BCB fcnt   holder fix_count   latch
READ 1           1          1                  READ(1)
READ 2           2          2                  READ(1)
WRITE            1          3                  WRITE(2)
UNFIX 1          0          2                  NO_LATCH(0)
UNFIX 2          assertion -> SIGABRT
```

별도 [release 원시 로그](https://github.com/vimkim/my-cubrid-docs/blob/fd2e244e585de7a78dfccbbdfde722eef1b49210/cbrd-27370/repro/run_release.log#L1-L7)는 WRITE까지 BCB 수 `1, 2, 1`과 같은 포인터 반환을 기록한다. 첫 unfix 후 BCB는 `0/NO_LATCH`이고, 두 번째와 세 번째 unfix는 관측값 `0/NO_LATCH`를 유지하면서 오류 `-19`, `page ... is not fixed`를 기록한다. release 로그는 holder 수를 직접 출력하지 않는다. 래치 숫자의 의미는 [현재 enum 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.h#L189-L197)와 같다.

현재 소스의 음수 방어 분기는 `impl_new`라는 지역 후보값을 감소시킨 뒤 음수이면 assertion과 오류 설정을 수행하고, 지역값을 `0`으로 바꾼 다음 CAS 전에 `break`한다. 따라서 위 로그를 BCB에 음수가 저장되었다가 정상 복구된 증거로 해석하지 않는다. [현재 음수 분기의 실제 제어 흐름](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L6633-L6661)을 근거로 한다.

## Additional Information

### 회귀 이력과 API 계약의 불확실성

[CBRD-26425](https://jira.cubrid.org/browse/CBRD-26425)의 atomic latch 개편 직전 커밋 `051851d1e1a04b43c649159fb71a5cf3177e662a`에는 단독 READ holder의 WRITE 요청에서 BCB 수와 holder 수를 각각 증가시키는 분기가 있다. 개편 커밋 `58cef8e01fcf121acbe3a35b7249deda54217532`에서는 이 자리에 BCB 수를 `1`로 설정하는 분기와 공통 holder 증가가 들어가 있다. 이 비교는 회계 동작의 회귀 근거다. [개편 전 증가 분기](https://github.com/CUBRID/cubrid/blob/051851d1e1a04b43c649159fb71a5cf3177e662a/src/storage/page_buffer.c#L6012-L6041), [개편 후 대입](https://github.com/CUBRID/cubrid/blob/58cef8e01fcf121acbe3a35b7249deda54217532/src/storage/page_buffer.c#L6173-L6182), [개편 후 holder 증가](https://github.com/CUBRID/cubrid/blob/58cef8e01fcf121acbe3a35b7249deda54217532/src/storage/page_buffer.c#L6255-L6265)를 근거로 한다.

다만 개편 전 코드에도 READ 보유자의 일반 WRITE 요청을 검사하는 `assert_release`와 debug의 `assert(false)` 및 `ER_FAILED` 반환 코드가 앞에 있다. 같은 검사 구조는 2014년 커밋 `076bf011458615c7262c56f5e4fe999e8d1459ae`에서도 확인된다. 따라서 개편 전 debug 동작을 단순히 오류만 반환하는 정상 실패 경로로 표현해서는 안 된다. assertion이 활성화된 일반 debug 실행은 반환에 앞서 중단될 수 있다. release에 증가 분기가 존재한다는 사실만으로 일반 승격이 공식 지원 계약이었다고 확정할 수도 없다. [개편 전 검사](https://github.com/CUBRID/cubrid/blob/051851d1e1a04b43c649159fb71a5cf3177e662a/src/storage/page_buffer.c#L5968-L5985), [2014년 검사](https://github.com/CUBRID/cubrid/blob/076bf011458615c7262c56f5e4fe999e8d1459ae/src/storage/page_buffer.c#L4831-L4849)를 근거로 한다.

### 범위와 관련 이슈

이 작업은 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 페이지 버퍼 정합성 작업 중 일반 중첩 fix의 회계와 계약에 한정한다. `pgbuf_simple_fix`의 로딩 실패 정리나 ordered fix의 deallocation 보호 회계는 각각 [CBRD-27630](https://jira.cubrid.org/browse/CBRD-27630), [CBRD-27263](https://jira.cubrid.org/browse/CBRD-27263)의 별도 검토 범위다. 페이지 래치 대기 정책은 [CBRD-27356](https://jira.cubrid.org/browse/CBRD-27356)과 정보를 공유할 수 있으나 이 회계 결함의 해결을 그 정책 선택에 종속시키지 않는다.

현재 근거의 중심은 `src/storage/page_buffer.c`와 회귀 검증이다. 일반 승격을 거부하거나 전용 API 사용으로 전환하는 선택은 호출부 동작을 바꿀 수 있으므로, SQL 호환성이나 디스크 형식에 영향이 전혀 없다고 미리 보장하지 않는다. 실제 SQL 진입 경로와 영향 릴리스는 ANALYSIS에서 별도로 확인한다.

## Options for Analysis

아래는 확정한 구현이 아닌 검토 후보이다.

| 후보 방안 | 기대 효과와 장점 | 한계·실패 조건 | 비용·위험·호환성 | 판별 근거 |
|---|---|---|---|---|
| 일반 중첩 승격을 허용하고 성공한 fix를 모두 계상한다 | 기존 반환 의무를 보존하면서 새 WRITE fix를 추가하는 계약을 일관되게 만든다. | 단독 holder의 대입만 고쳐도 다중 reader·실패·대기 경로까지 안전해지는지는 별도 확인이 필요하다. | 기존 release 호출부의 성공 동작을 유지할 수 있으나, 일반 승격 지원을 계약으로 채택해야 한다. 범위와 비용은 미상이다. | 개편 전 증가 분기, 현재 즉시 성공 경로, 일반 호출부 조사와 동시 실행 검증 |
| 일반 중첩 승격을 거부하고 필요한 호출부를 전용 승격 계약에 맞춘다 | 금지된 요청을 회계 변경 없이 실패시키는 경계를 명확히 한다. | 전용 API는 fix를 추가하지 않으므로 함수 치환만으로 반환 의무가 맞지 않을 수 있다. | 과거 검사 의도와의 연속성이 있으나 현재 성공을 기대하는 호출부의 호환성·오류 처리를 조사해야 한다. 범위와 비용은 미상이다. | 과거 assertion, 현재 전용 승격의 기존 수 보존 동작, 호출부별 반환 횟수와 실패 처리 |

첫 후보는 추가 fix의 의미를 유지하고 두 번째 후보는 호출 허용 범위를 좁힌다. 현 상태를 유지하면 직접 probe에서 확인된 회계 불일치가 남는다. 어느 후보를 선택할지는 유지보수자가 의도한 API 계약과 실제 호출부 조사로 결정해야 하며, 과거 release 동작 또는 debug 검사 하나만으로 결정하지 않는다.

## Acceptance Criteria

- 일반 READ-to-WRITE fix를 허용하는지 명시하고 실제 호출부 및 전용 승격과의 반환 의무 차이를 근거로 기록한다.
- 단독 holder의 READ 1회/2회 뒤 일반 WRITE 요청에서 선택한 계약에 맞는 성공 또는 실패가 관측된다. 성공 시 기존 사용과 새 fix가 모두 계상되고, 실패 시 기존 READ 수와 래치 상태가 보존된다.
- 성공한 fix에 대응하는 unfix가 끝날 때까지 BCB와 holder 회계가 일치하며 조기 래치 해제, 음수 계산으로 인한 assertion 및 내부 오류가 발생하지 않는다.
- 다른 reader나 WRITE 대기자가 있는 조건에서 남은 사용이 있는데도 래치가 해제되거나 대기자에게 인계되지 않는지 확인한다. 전용 승격 대조군은 기존 반환 횟수를 보존한다.
- debug/release 및 SA_MODE/SERVER_MODE의 확인 결과를 빌드 식별과 함께 남긴다. SQL 도달 경로와 영향 릴리스는 확인 결과 및 미확인 범위를 구분해 기록한다.

## Definition of done

선택한 API 계약과 필요한 호출부 변경을 리뷰하고, 분석에서 정한 검증 방식으로 fix부터 마지막 unfix까지 수·래치·오류·대기자 상태를 관측하는 회귀 결과를 남긴다. 기존 probe는 출발점으로 활용하되 같은 커밋의 debug/release 비교와 SERVER_MODE 동시 실행 근거를 보완한다. 구현 범위, 최종 테스트 구성 및 대상 릴리스는 ANALYSIS에서 결정한다.

## Triage Request

기존 Confirmed 상태의 회계 결함 범위를 위 근거로 재확인하고, 작성자 측에 ANALYSIS를 배정해 줄 것을 요청한다. 분석에서는 일반 승격의 허용 정책, 실제 엔진·SQL 호출 경로, 선택한 정책의 호출부 호환성, 같은 커밋의 debug/release 재검증 및 영향 릴리스 범위를 확인한다. 우선순위와 최종 담당 배정은 triage 결정에 따른다.
