# [PGBUF] 중첩 READ-to-WRITE fix가 BCB fix count를 초기화하는 회귀

## Issue Triage

**이슈 수행 목적**: 중첩된 page fix와 unfix의 회계가 끝까지 일치하도록 READ-to-WRITE 경로를 수정한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 같은 스레드의 중첩 READ 뒤에 일반 `pgbuf_fix(..., PGBUF_LATCH_WRITE, ...)`가 성공하면 BCB와 스레드의 fix count가 서로 달라진다. |
| **TO-BE (목표 상태 / 기대 동작)** | 일반 READ-to-WRITE fix를 허용하면 모든 성공 호출을 계상하고, 허용하지 않으면 기존 READ 상태를 바꾸지 않은 채 WRITE 요청을 실패시킨다. |
| **영향** | 설계 의도 훼손 - 래치가 남은 fix보다 먼저 풀리거나 정상적인 unfix가 내부 오류로 처리될 수 있다. |

**이슈 수행 방안**: 성공한 `pgbuf_fix` 수와 BCB/스레드별 fix count를 항상 일치시킨다. 일반 READ-to-WRITE 요청을 허용할지, 전용 `pgbuf_promote_read_latch`만 허용할지는 `TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI가 코드와 실행 결과를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c`의 `pgbuf_latch_bcb_upon_fix`와 관련 회귀 테스트가 대상이다. 문제 분기는 `SERVER_MODE`(서버 프로세스 빌드)와 `SA_MODE`(서버 기능을 프로세스 안에서 실행하는 standalone 빌드)가 공유하며 디스크 형식이나 공개 SQL 호환성 변경은 예상하지 않는다.

---

## Description

`pgbuf_fix`는 페이지 버퍼의 페이지를 고정하고 래치(latch - 페이지의 물리적 일관성을 보호하는 잠금)를 얻는다. 성공한 호출마다 BCB(Buffer Control Block - 버퍼 페이지의 상태 구조체)의 전역 `fcnt`와 해당 스레드의 `PGBUF_HOLDER::fix_count`가 함께 증가해야 한다. 각 호출자는 같은 횟수만큼 `pgbuf_unfix`를 실행하며, 마지막 unfix에서만 래치가 풀린다.

문제는 이미 READ 래치를 가진 스레드가 일반 `pgbuf_fix`로 WRITE를 요청할 때 발생한다.

```
pgbuf_fix(READ) 반복            global fcnt == holder fix_count
  └ pgbuf_fix(WRITE)
      ├ 단독 holder 확인        old fcnt == holder fix_count
      ├ WRITE로 변경
      ├ global fcnt = 1          ★ 이전 READ 회계를 덮어씀
      └ 공통 성공 처리           holder fix_count++
```

`pgbuf_latch_bcb_upon_fix`는 `old_impl.impl.fcnt == holder->fix_count`이면 즉시 승격 가능한 단독 holder로 판단한다. 이때 `new_impl.impl.fcnt = 1`을 저장한 뒤, 공통 성공 처리에서 `holder->fix_count`를 1 증가시킨다. 서로 같아야 할 두 회계가 한 번의 성공 경로 안에서 어긋난다.

회귀는 CBRD-26425 atomic latch 개편 커밋 `58cef8e01fcf121acbe3a35b7249deda54217532`에서 들어왔다. 개편 전 release 빌드는 이 경로에서 `bufptr->fcnt`와 `holder->fix_count`를 각각 1 증가시켰다. 반면 debug 빌드는 2014년 커밋 `076bf011458615c7262c56f5e4fe999e8d1459ae`가 추가한 검사로 일반 중첩 WRITE 요청을 `ER_FAILED`로 거부했다. 개편 후에는 두 빌드 모두 요청을 성공시키면서 전역 값만 초기화한다. 2026-09-02 기준 develop HEAD `5f3a30d0998beafcc3932ed8cf65e66020a53c4c`에도 이 대입이 남아 있다.

## Test Build

| 확인 항목 | 환경 |
|-----------|------|
| 최신 소스 확인 | Linux, develop `5f3a30d0998beafcc3932ed8cf65e66020a53c4c` |
| SA runtime probe | Linux, CUBRID `11.5.0.2431-198b42a`, 64-bit debug build |
| 최초 교차 확인 | Linux, `f799e05d77d5300c6ea5753b4a6cc7caee6d8912`, debug/release SA build |

## Repro

`/tmp/vs18_probe.cpp`:

```cpp
#include "config.h"
#include "dbi.h"
#include "page_buffer.h"
#include "storage_common.h"
#include "thread_manager.hpp"

#include <cstdio>
#include <cstdlib>

__attribute__ ((noinline)) static void
probe_point (const char *label, THREAD_ENTRY *thread_p, PAGE_PTR page)
{
  std::printf ("%s: global_fcnt=%d latch=%d\n", label, pgbuf_get_fix_count (page),
               static_cast<int> (pgbuf_get_latch_mode (page)));
}

int
main (int argc, char **argv)
{
  if (argc != 2)
    {
      return 2;
    }

  std::setvbuf (stdout, nullptr, _IONBF, 0);
  db_login ("dba", nullptr);
  if (db_restart (argv[0], 0, argv[1]) != NO_ERROR)
    {
      return 3;
    }

  THREAD_ENTRY *thread_p = thread_get_thread_entry_info ();
  VPID vpid = { 0, 0 };

  PAGE_PTR p1 = pgbuf_fix (thread_p, &vpid, OLD_PAGE,
                           PGBUF_LATCH_READ, PGBUF_UNCONDITIONAL_LATCH);
  probe_point ("after READ 1", thread_p, p1);

  PAGE_PTR p2 = pgbuf_fix (thread_p, &vpid, OLD_PAGE,
                           PGBUF_LATCH_READ, PGBUF_UNCONDITIONAL_LATCH);
  probe_point ("after READ 2", thread_p, p2);

  PAGE_PTR p3 = pgbuf_fix (thread_p, &vpid, OLD_PAGE,
                           PGBUF_LATCH_WRITE, PGBUF_UNCONDITIONAL_LATCH);
  probe_point ("after WRITE", thread_p, p3);

  std::_Exit (p1 == p2 && p2 == p3 ? 0 : 4);
}
```

`/tmp/vs18_probe.gdb`:

```gdb
set pagination off
set breakpoint pending on
break probe_point
commands
  silent
  set $iop = (pgbuf_iopage_buffer *) ((char *) page - (long) &((pgbuf_iopage_buffer *) 0)->iopage.page)
  set $holder = pgbuf_find_thrd_holder (thread_p, $iop->bcb)
  printf "GDB %s: holder_fix_count=%d\n", label, $holder->fix_count
  continue
end
run cbrd27370_probe
```

```bash
SOURCE_ROOT=$(pwd)
SA_LIB=$(find "$SOURCE_ROOT" -path '*/sa/libcubridsa.so' -print -quit)
BUILD_ROOT=$(dirname "$(dirname "$SA_LIB")")
PROBE_INSTALL=$(mktemp -d /tmp/cbrd27370-install.XXXXXX)
PROBE_DATA=$(mktemp -d /tmp/cbrd27370-data.XXXXXX)

cmake --build "$BUILD_ROOT"
cmake --install "$BUILD_ROOT" --prefix "$PROBE_INSTALL"

g++ -std=gnu++17 -g -O0 -DSA_MODE -DLINUX -DGCC -DI386 -DX86 -DSYSV \
  -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE -D_REENTRANT \
  -I"$BUILD_ROOT" -I"$SOURCE_ROOT/include" -I"$SOURCE_ROOT/src/api" \
  -I"$SOURCE_ROOT/src/base" -I"$SOURCE_ROOT/src/compat" -I"$SOURCE_ROOT/src/storage" \
  -I"$SOURCE_ROOT/src/thread" -I"$SOURCE_ROOT/src/transaction" \
  -I"$SOURCE_ROOT/src/communication" -I"$SOURCE_ROOT/src/connection" \
  -I"$SOURCE_ROOT/src/monitor" -I"$SOURCE_ROOT/src/object" -I"$SOURCE_ROOT/src/query" \
  -I"$SOURCE_ROOT/src/xasl" -I"$SOURCE_ROOT/cubrid-cci/src/cci" \
  -I"$BUILD_ROOT/3rdparty/include" -I"$BUILD_ROOT/3rdparty/Source/lz4/lib" \
  -I"$BUILD_ROOT/3rdparty/Source/rapidjson/include" \
  /tmp/vs18_probe.cpp -L"$(dirname "$SA_LIB")" -L"$BUILD_ROOT" \
  -L"$BUILD_ROOT/3rdparty/lib" -Wl,-rpath,"$(dirname "$SA_LIB")" \
  -lcubridsa -lpthread -ldl -o /tmp/vs18_probe

mkdir "$PROBE_DATA/db"
CUBRID="$PROBE_INSTALL" CUBRID_DATABASES="$PROBE_INSTALL/databases" \
LD_LIBRARY_PATH="$PROBE_INSTALL/lib:$PROBE_INSTALL/cci/lib" \
  "$PROBE_INSTALL/bin/cubrid" createdb -F "$PROBE_DATA/db" -L "$PROBE_DATA/db" \
  cbrd27370_probe en_US.utf8

cd "$PROBE_DATA/db"
CUBRID="$PROBE_INSTALL" CUBRID_DATABASES="$PROBE_INSTALL/databases" \
LD_LIBRARY_PATH="$PROBE_INSTALL/lib:$PROBE_INSTALL/cci/lib" \
  gdb -q -batch -x /tmp/vs18_probe.gdb /tmp/vs18_probe
```

## Expected Result

일반 READ-to-WRITE fix를 지원하는 계약이라면 출력은 `fcnt=1 -> 2 -> 3`이고 세 포인터가 같으며 최종 래치는 WRITE여야 한다. 세 번의 unfix는 `fcnt=2 -> 1 -> 0`으로 진행하고 마지막 호출에서만 래치를 해제해야 한다.

일반 READ-to-WRITE fix를 금지하는 계약이라면 세 번째 호출은 실패하고 기존 상태 `fcnt=2`, `holder->fix_count=2`, READ를 그대로 유지해야 한다. 이후 두 번의 unfix로 정상 해제해야 한다.

## Actual Result

```text
GDB after READ 1: holder_fix_count=1
after READ 1: global_fcnt=1 latch=1
GDB after READ 2: holder_fix_count=2
after READ 2: global_fcnt=2 latch=1
GDB after WRITE: holder_fix_count=3
after WRITE: global_fcnt=1 latch=2
```

세 번째 호출은 성공하고 공통 성공 경로가 `holder->fix_count`를 `3`으로 올리지만 전역 `fcnt`는 `1`로 되돌아간다. release 빌드에서는 첫 unfix 직후 `fcnt=0`, `PGBUF_NO_LATCH`가 되었고, 나머지 두 호출에서 내부 값이 음수가 된 뒤 `0`으로 보정되었다. debug 빌드는 음수 방어 assertion에서 중단되었다.

출력의 latch 값 `1`은 READ, `2`는 WRITE다.

## Additional Information

### 관련 코드

| 위치 | 의미 |
|------|------|
| `src/storage/page_buffer.c:6310-6319` | 단독 READ holder의 일반 WRITE 요청 분기 |
| `src/storage/page_buffer.c:6392-6408` | 즉시 획득 후 공통 성공 처리 |
| `src/storage/page_buffer.c:6573-6601` | 일반 unfix의 전역 count 처리 |
| `src/storage/page_buffer.c:2740-2924` | 기존 fix 회계를 보존하는 전용 `pgbuf_promote_read_latch` 경로 |

### 수정 정책 검토

| 후보 | 동작 | 고려사항 |
|------|------|----------|
| 일반 승격 유지 | `new_impl.impl.fcnt`를 기존 값에서 1 증가시켜 공통 holder 증가와 맞춘다. | 개편 전 동작과 일치한다. 동일 스레드 READ 1회/다회 및 대기자 유무를 모두 검증해야 한다. |
| 일반 승격 금지 | 상태를 변경하지 않고 WRITE fix를 실패시키며 `pgbuf_promote_read_latch` 사용을 강제한다. | 2014년 커밋 `076bf011458615c7262c56f5e4fe999e8d1459ae`의 "do not permit nested write mode fix operation" 의도와 맞지만 호출부 호환성 조사가 필요하다. |

정책 선택과 무관하게 다음 회귀 검증이 필요하다.

- READ 1회 후 일반 WRITE fix
- READ 2회 후 일반 WRITE fix
- 성공한 fix 수만큼 unfix했을 때 전역/스레드 count와 래치 상태
- WRITE 대기자가 있는 상태에서 조기 깨우기나 인계가 없는지 확인
- `pgbuf_promote_read_latch` 대조군에서 기존 fix 회계 보존 확인
- debug/release 및 `SA_MODE`/`SERVER_MODE` 확인

관련 이슈: CBRD-26425, CBRD-27193
