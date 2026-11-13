# [Build] printf 계열 로그 함수에 포맷 검사 속성을 붙여 포맷 오류를 컴파일할 때 잡는다

**한 줄 요약**: CBRD-28094에서 로그 호출 16곳의 포맷 오류를 고친 뒤에도 같은 종류의 오류가 77줄 더 남아 있다. 이 이슈는 남은 경고를 정리하고, `_er_log_debug` 를 비롯한 로그 함수에 `format(printf)` 속성을 붙여 새 포맷 오류가 빌드에서 바로 드러나게 한다.

## Issue Triage

**이슈 수행 목적**: printf 계열 로그 함수에 포맷 문자열과 맞지 않는 인자를 넘기면 GCC가 컴파일할 때 알려 준다. 그러면 틀린 로그 호출이 develop에 들어오지 않는다.

**이슈 수행 이유**: CUBRID의 로그 함수 대부분이 `vsnprintf` 류로 메시지를 만들지만, 선언에 `__attribute__ ((format (printf, F, A)))` 가 없다. 그래서 컴파일러가 호출부를 검사하지 않고, 틀린 호출이 오래 남는다. CBRD-28094의 16곳이 그 예다. 속성을 임시로 붙여 빌드해 보니, CBRD-28094 대상을 빼고도 경고 272건이 나왔다. 46개 파일, 205줄에 걸쳐 있다.

**영향**: 개발자와 QA가 로그를 켜고 장애를 분석할 때, 틀린 값이 찍힌 로그를 보게 된다. 남은 경고 중 77줄은 인자의 크기나 종류가 실제로 다르다. 예를 들어 64비트 값을 `%d` 로 찍으면 값이 잘리고, 인자가 모자라면 쓰레기 값이 찍힌다. 이는 C 표준상 정의되지 않은 동작이다. 지금은 이런 호출을 리뷰에서 눈으로 찾아야 한다. 일반 사용자에게는 영향이 없다. 대부분 기본 설정에서 꺼진 디버그 로그이기 때문이다. 다만 `cas_log`, `proxy_log` 처럼 운영 중에 켜는 broker 로그도 일부 포함된다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

[CBRD-28094](https://jira.cubrid.org/browse/CBRD-28094)를 조사하면서 아래 로그 함수 28개의 선언에 `format(printf)` 속성을 임시로 붙이고 GCC로 빌드해 경고를 모두 모았다. 경고는 286건이었다. 이 중 CBRD-28094가 고치는 16곳을 빼면 272건이 남는다.

속성을 붙이려면 남은 경고를 먼저 없애야 한다. CUBRID의 `CMakeLists.txt` 는 Release와 RelWithDebInfo 빌드에 `-Werror` 를 쓴다. 모든 빌드 타입에는 `-Werror=format-security` 를 쓴다. 따라서 남은 경고를 그대로 두고 속성만 붙이면 Release 빌드가 실패하고, 일부 경고는 Debug 빌드도 깨뜨린다. 시험 빌드에서 Release는 오류 280건과 함께 번역 단위 78개의 컴파일에 실패했다.

아래 수치는 `develop` `e64a04a79a`, Linux x86-64, GCC 11.5.0의 Debug 빌드(`-k 0` 로 끝까지 컴파일)에서 얻었다. CBRD-28094 대상 16곳은 뺐다.

### 남은 경고의 종류

| 분류 | 경고 수 | 줄 수 | 뜻 |
|---|---|---|---|
| 실제 불일치 | 112 | 77 | 인자의 크기나 종류가 다르다. 예를 들어 64비트 값을 `%d` 로, 포인터를 정수 지정자로, 문자열이 아닌 값을 `%s` 로 넘긴다. 인자 개수가 틀린 경우도 있다 |
| 폭 차이 | 114 | 82 | LP64에서 크기가 같은 정수끼리의 차이다(`long` 과 `long long`). Linux에서는 값이 맞게 찍히지만, `long` 이 32비트인 Windows에서는 다를 수 있다 |
| 비리터럴 포맷 | 41 | 41 | 인자 없이 변수 문자열을 포맷으로 넘긴다(`-Wformat-security`). 문자열에 `%` 가 들어 있으면 잘못 찍힌다 |
| 빈 포맷 | 5 | 5 | 길이가 0인 포맷 문자열이다(`-Wformat-zero-length`) |

### 함수별 분포 (경고 수)

| 함수 | 실제 불일치 | 폭 차이 | 비리터럴 | 빈 포맷 |
|---|---|---|---|---|
| `_er_log_debug` (`er_log_debug`, `vacuum_er_log`, `file_log`, `dwb_log` 등) | 91 | 99 | 6 | |
| `cubrid_log_tracelog` (CDC API 추적 로그) | 13 | 9 | | |
| `print_log_msg` (loaddb) | | | 19 | |
| `cas_log_write` 계열 | | 2 | 11 | 4 |
| `proxy_log_write` | 8 | | | |
| `logpb_fatal_error`, `log_dump_log_info` | | 4 | 1 | |
| `util_log_write_errstr`, `util_log_write_warnstr` | | | 3 | |
| `er_emergency` | | | 1 | |
| `logddl_*` | | | | 1 |

`_er_log_debug` 하나에 실제 불일치가 몰려 있다. `ANALYSIS` 에서는 함수별로 나눠 경고를 정리하고 속성을 붙이는 순서를 검토할 수 있다.

### 시험에 쓴 속성 위치

| 파일 | 함수 | `format (printf, F, A)` |
|---|---|---|
| `src/base/error_manager.h` | `_er_log_debug`, `er_print_callstack` | 3, 4 |
| `src/base/error_manager.c` | `er_emergency` | 3, 4 |
| `src/broker/cas_log.h` | `cas_log_write_nonl`, `cas_log_write_nonl_noflush`, `cas_log_write`, `cas_log_write_and_end`, `cas_slow_log_write_and_end` | 3, 4 |
| `src/broker/cas_log.h` | `cas_log_write2_nonl_noflush`, `cas_log_write2`, `cas_slow_log_write2` | 1, 2 |
| `src/broker/cas_log.h` | `cas_log_open_and_write`, `cas_slow_log_write` | 4, 5 |
| `src/broker/cas_log.c` | `cas_fprintf` | 2, 3 |
| `src/broker/cas_sql_log2.h` | `sql_log2_write` | 1, 2 |
| `src/broker/shard_proxy_log.h` | `proxy_log_write` | 3, 4 |
| `src/base/util_func.h` | `util_log_write_errstr`, `util_log_write_warnstr` | 1, 2 |
| `src/cm_common/cm_dep.h` | `cm_util_log_write_errstr` | 1, 2 |
| `src/base/ddl_log.h` | `logddl_set_msg`, `logddl_write_tran_str`, `logddl_write_end_for_csql_fileinput` | 1, 2 |
| `src/executables/master_heartbeat.h` | `hb_disable_er_log` | 2, 3 |
| `src/executables/unload_object.c` | `unload_log_write` | 2, 3 |
| `src/loaddb/load_sa_loader.hpp` | `print_log_msg` | 2, 3 |
| `src/transaction/log_comm.h` | `log_dump_log_info` | 3, 4 |
| `src/transaction/log_impl.h` | `logpb_fatal_error` | 5, 6 |
| `src/transaction/log_impl.h` | `logpb_fatal_error_exit_immediately_wo_flush` | 4, 5 |
| `src/api/cubrid_log.c` | `cubrid_log_tracelog` | 6, 7 |

`porting.h` 와 `dbtype_def.h` 는 GNU C가 아닌 컴파일러에서 `__attribute__(X)` 를 빈 매크로로 정의한다. 그래서 MSVC 빌드에는 영향이 없다.

## Specification Changes

- 실행 결과가 바뀌는 것은 고쳐진 로그 메시지의 내용뿐이다.
- 이후 위 함수에 맞지 않는 인자를 넘기면 GCC가 경고를 낸다. Release 빌드에서는 오류가 된다.

## Acceptance Criteria

- 위 로그 함수(또는 ANALYSIS에서 정한 범위)의 선언에 `format(printf)` 속성이 붙어 있다.
- Linux GCC의 Debug와 Release 빌드가 새 `-Wformat*` 경고 없이 성공한다.
- Windows 빌드가 계속 성공한다.

## Test Build

`develop` `e64a04a79a`, Linux x86-64, GCC 11.5.0. 수치는 CBRD-28094의 수정 이전 소스에서 얻은 것이다. CBRD-28094가 병합되면 16곳이 빠진 것과 같은 결과가 나올 것으로 예상하지만, 아직 그 상태로 다시 빌드해 확인하지는 않았다.

## Repro

1. 위 표의 선언 끝에 `__attribute__ ((format (printf, F, A)))` 를 붙인다.
2. 오류가 나도 끝까지 컴파일하도록 빌드하고 경고를 모은다.

   ```sh
   cmake --preset debug
   cmake --build --preset debug -- -k 0 2>&1 | tee build.log
   grep -E '\[-W(error=)?format' build.log | sort -u | wc -l
   ```

3. 매크로 안에서 난 경고는 `note: format string is defined here` 와 `note: in expansion of macro` 줄을 따라가 실제 호출 위치로 옮겨 센다.

## Additional Information

- 선행 이슈는 [CBRD-28094](https://jira.cubrid.org/browse/CBRD-28094)다. 영향이 큰 16곳은 이 이슈에서 따로 고친다.
- [CBRD-27004](https://jira.cubrid.org/browse/CBRD-27004)는 사용자 입력이 든 문자열을 포맷 위치에 직접 넘기던 printf 호출을 `"%s"` 로 고쳤다. 남은 비리터럴 포맷 41곳도 같은 방식으로 고칠 수 있다. 다만 이 41곳은 그 이슈가 다루지 않은 로그 함수 래퍼를 거친다.
- 기존 이슈 중 같은 작업을 다루는 것은 찾지 못했다.
