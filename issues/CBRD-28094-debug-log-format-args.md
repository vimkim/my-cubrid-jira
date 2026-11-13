# [Debug Log] 디버그 로그 호출 16곳의 포맷 문자열과 인자가 맞지 않는다

**한 줄 요약**: 정적 분석 도구(CodeQL)와 GCC 포맷 검사로 찾은, 포맷 문자열과 인자의 개수나 종류가 맞지 않는 디버그 로그 호출 16곳을 고쳐 해당 로그가 올바른 값을 출력하게 한다.

## Issue Triage

**이슈 수행 목적**: 개발자와 QA가 디버그 로그(`er_log_debug`, `dwb_log`, `vacuum_er_log`, `file_log`, `cdc_log`, CDC API 추적 로그, broker proxy 로그)를 켰을 때 각 메시지가 의도한 값을 출력하고, 로그 호출이 정의되지 않은 동작(undefined behavior)을 일으키지 않게 한다.

**이슈 수행 이유**: 16곳에서 printf 계열 포맷 문자열의 변환 지정자와 실제 인자가 맞지 않는다. 인자가 모자라거나 남고, 구조체나 `char *` 를 다른 종류의 지정자로 넘긴다. 특히 vacuum, file, btree, disk 디버그 로그가 공통으로 쓰는 `LOG_THREAD_TRAN_ARGS` 매크로는 서버 모드에서 트랜잭션 ID 대신 `LOG_TDES` 포인터를 `%d` 로 넘긴다. 로그 함수 `_er_log_debug` 에 포맷 검사 속성이 없어서 컴파일러가 이 오류를 경고하지 않았다.

**영향**: 해당 디버그 로그를 켠 개발자와 QA가 틀린 값을 보고 장애를 분석하게 된다. vacuum과 file 로그의 `trid=` 값은 포인터의 일부라 트랜잭션을 식별할 수 없다. 인자가 모자란 호출과 구조체를 넘기는 호출은 C 표준상 정의되지 않은 동작이라 쓰레기 값을 출력한다. 기본 설정에서는 이 로그들이 꺼져 있으므로 일반 사용자의 동작에는 영향이 없다. 로그를 켠 상태에서 서버가 비정상 종료한 사례는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

CUBRID의 디버그 로그는 대부분 `_er_log_debug (file, line, fmt, ...)` 를 감싼 매크로다. 이 함수는 `vsnprintf` 로 메시지를 만들지만, 선언에 `__attribute__ ((format (printf, 3, 4)))` 가 없다. 그래서 GCC의 `-Wformat` 이 호출부의 포맷 문자열과 인자를 비교하지 않는다. CDC API의 `cubrid_log_tracelog` 와 broker proxy의 `proxy_log_write` 도 같은 상태다.

정적 분석 도구 시험(CodeQL `WrongNumberOfFormatArguments`)에서 `double_write_buffer.cpp` 의 `dwb_log` 두 곳을 먼저 찾았다. 이어서 위 로그 함수에 포맷 속성을 임시로 붙이고 GCC로 빌드해 전체 경고를 모았다. 경고는 286건이었고, 대부분은 `%d` 에 64비트 값을 넘기는 폭 차이였다. 이 이슈는 그중 인자 개수나 종류가 틀린 16곳만 다룬다. 포맷 속성 추가와 나머지 폭 차이 정리는 범위가 커서 이 이슈에 포함하지 않는다.

아래 행 번호는 `develop` 의 `e64a04a79a` 기준이다.

### 대상 호출

| 위치 | 로그 | 문제 |
|---|---|---|
| [`log_impl.h:980-981`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_impl.h#L980-L981) | `LOG_THREAD_TRAN_MSG` / `LOG_THREAD_TRAN_ARGS` (서버 모드) | `trid=%d` 에 `LOG_FIND_CURRENT_TDES (thread_p)` 포인터를 넘긴다 |
| [`double_write_buffer.cpp:1426`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/double_write_buffer.cpp#L1426) | `dwb_log` | `%d` 세 개에 인자 두 개 |
| [`double_write_buffer.cpp:3290`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/double_write_buffer.cpp#L3290) | `dwb_log` | `%d` 세 개에 인자 두 개 |
| [`critical_section.c:651`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/thread/critical_section.c#L651), [`:870`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/thread/critical_section.c#L870), [`:1130`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/thread/critical_section.c#L1130), [`:1338`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/thread/critical_section.c#L1338) | `er_log_debug` | `total_elapsed %d.06d` 에서 `%` 가 빠져 마지막 인자가 남는다. `time_t`, `suseconds_t` 값을 `%d` 로 출력한다 |
| [`vacuum.c:4912`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L4912) | `vacuum_er_log_error` | 메시지에 지정자가 없는데 VPID 인자 두 개를 넘긴다 |
| [`file_manager.c:6260`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/file_manager.c#L6260) | `file_log` | `vpid %\|%d` 의 `%\|` 는 변환 지정자가 아니다 |
| [`log_applier.c:5902`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_applier.c#L5902) | `er_log_debug` | `item_type` 에 지정자가 없어 인자가 남는다 |
| [`log_applier.c:8506`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_applier.c#L8506) | `er_log_debug` | 메시지에 지정자가 없는데 pageid를 넘긴다 |
| [`log_manager.c:13879`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L13879) | `cdc_log` | 메시지에 지정자가 없는데 `trid`, `user`, `dcl_type` 을 넘긴다 |
| [`cubrid_log.c:1528`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/api/cubrid_log.c#L1528) | `CUBRID_LOG_WRITE_TRACELOG` | `%lld` 에 `LOG_LSA` 구조체를 값으로 넘긴다. `time_t` 도 캐스트 없이 `%lld` 로 넘긴다 |
| [`shard_proxy_io.c:3510`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/broker/shard_proxy_io.c#L3510), [`:3600`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/broker/shard_proxy_io.c#L3600), [`:3739`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/broker/shard_proxy_io.c#L3739) | `PROXY_LOG` | `%S`(wide 문자열)에 `char *` 를 넘긴다 |

### `LOG_THREAD_TRAN_ARGS` 의 이력

이 매크로는 [CBRD-20692](https://jira.cubrid.org/browse/CBRD-20692)(커밋 `3049b9cb34`)에서 `LOG_FIND_CURRENT_TDES (thread_p)->trid` 를 출력하도록 추가됐다. 이후 [CBRD-22742](https://jira.cubrid.org/browse/CBRD-22742)(커밋 `e1b88d38f6`)에서 vacuum worker 분기를 정리하면서 `->trid` 가 빠졌다. 그 뒤로 서버 모드의 vacuum, file, btree, disk 디버그 로그는 `trid=` 자리에 포인터 하위 32비트를 출력한다. x86-64에서 가변 인자는 각각 8바이트 슬롯을 쓰므로 뒤 인자가 밀리지는 않는다. `LOG_FIND_TDES` 는 범위를 벗어난 인덱스에 NULL을 반환하므로, 고칠 때 NULL 처리를 함께 고려해야 한다. 기존 함수 `logtb_find_current_tranid` 는 NULL일 때 `NULL_TRANID` 를 반환한다.

## Test Build

`develop` `e64a04a79a`, Linux x86-64, GCC 11.5.0.

## Repro

정적 검출은 아래처럼 재현한다. 1단계는 확인용 임시 변경이다.

1. `src/base/error_manager.h` 의 `_er_log_debug` 선언 끝에 `__attribute__ ((format (printf, 3, 4)))` 를 붙인다.
2. 빌드 오류가 나도 끝까지 컴파일하도록 빌드한다.

   ```sh
   cmake --preset debug
   cmake --build --preset debug -- -k 0 2>&1 | tee build.log
   grep -E 'too many arguments for format|expects a matching|unknown conversion type|LOG_TDES\*|log_lsa' build.log
   ```

3. 위 표의 `_er_log_debug` 계열 호출에서 경고가 나온다. `cubrid_log.c` 와 `shard_proxy_io.c` 는 `cubrid_log_tracelog` 와 `proxy_log_write` 선언에 같은 속성을 붙이면 나온다.

실행 중 잘못된 출력은 확인하지 않았다. `er_log_debug=yes` 와 각 모듈의 디버그 로그 설정을 켜고 해당 경로를 실행하면 볼 수 있을 것으로 본다(추정).

## Expected Result

각 호출의 변환 지정자와 인자의 개수, 종류가 일치한다. 서버 모드의 `trid=` 는 현재 트랜잭션 ID를 출력한다. 위 재현 절차로 빌드했을 때 이 16곳에서 인자 개수나 종류에 관한 경고가 나오지 않는다.

## Actual Result

16곳에서 GCC가 `too many arguments for format`, `format '%d' expects a matching 'int' argument`, `unknown conversion type character '|'`, 포인터나 구조체 또는 `char *` 를 다른 지정자로 넘긴다는 경고를 낸다.

## Additional Information

- 포맷 속성을 붙였을 때의 전체 경고 규모는 debug 빌드 기준 286건(호출 행 218개)이다. release 빌드는 `-Werror` 가 켜져 있어, 속성을 붙이려면 폭 차이까지 모두 정리해야 한다. 이 작업은 별도 이슈로 다루는 것이 맞다.
- `load_db.c:137` 은 `stat.log_message` 를 포맷 문자열로 넘긴다. 메시지에 `%` 가 있으면 잘못 해석된다. 인자 개수 문제가 아니므로 이 이슈에는 넣지 않았다.
