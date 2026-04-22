# [OOS] OOS 디버그 로거의 stderr 출력 오류 수정 및 조건부 출력

## Description

### 배경

`src/storage/oos_log.hpp` 의 `oos_log_internal()` 은 모든 OOS 디버그 로그 라인(`oos_debug` / `oos_trace` / `oos_info` / `oos_warn` / `oos_error`)을 **무조건 stderr 에도 기록** 하고 있다. 파일 싱크(`$CUBRID/log/oos.log`)와는 별개의 보조 싱크로 동작한다.

이로 인해 다음과 같은 상황에서 **제어 터미널이 손상** 된다.

1. **cgdb 아래에서 서버/csql 실행**
   - cgdb 의 ncurses UI 가 stderr OOS 로그 라인으로 덮어쓰여 프레임이 깨진다.

2. **csql 이 readline/linenoise 로 tty 를 raw 모드로 전환한 뒤, 같은 세션에서 백그라운드 cub_server 가 stderr 출력을 내보낼 때**
   - raw 모드에서는 터미널 드라이버가 `\n` 을 `\r\n` 으로 변환하는 `ONLCR` 후처리를 수행하지 않으므로, 아래와 같이 계단식(staircase) 출력이 발생한다.

   ```
   [06:09:04] OOS [DEBUG](oos_insert:1074): arguments: oos_vfid={fileid=576, volid=1}, recdes.length=608
                                                                                                               [06:09:04] OOS [DEBUG](oos_insert:1095): inserted to oid={vol=1,page=578,slot=0}
                                  [06:09:04] OOS [DEBUG](oos_insert:1074): arguments: oos_vfid={fileid=576, volid=1}, recdes.length=1708
   ```

3. **daemonize 된 cub_server** 의 경우 inherit 된 stderr 가 의미 있는 소비자가 없는 fd 로 이어져 있어, stderr 출력은 정보 전달 가치가 거의 없고 I/O 만 소모한다.

### 목적

- OOS 로그의 **단일 진실 공급원(Single Source of Truth)** 을 `$CUBRID/log/oos.log` 파일로 고정한다.
- stderr 출력은 로컬 개발 중 한정적으로 유용하므로, `CUBRID_OOS_LOG_STDERR` 환경 변수로 **명시적으로 opt-in** 할 때만 동작하도록 바꾼다.
- `\r\n` 같은 표면적인 우회(심볼 보정)에 의존하지 않고 근본 원인(무조건적 stderr 쓰기)을 제거한다.

---

## Spec Change

### 로그 싱크 동작 변경

| 환경 | 기존 | 변경 후 |
|---|---|---|
| `$CUBRID/log/oos.log` | 항상 기록 | 항상 기록 (변경 없음) |
| `stderr` (기본) | **항상 기록** | **기록 안 함** |
| `stderr` (opt-in) | — | `CUBRID_OOS_LOG_STDERR` 가 set 되어 있을 때만 기록 |

### 신규 환경 변수

| 변수 | 값 | 효과 |
|---|---|---|
| `CUBRID_OOS_LOG_STDERR` | set (임의의 값) | `oos_log_internal()` 이 stderr 에도 라인을 flush |
| `CUBRID_OOS_LOG_STDERR` | unset (기본) | stderr 출력 없음 |

값을 체크하지 않고 환경 변수의 **존재 여부만** 판단한다 (`std::getenv(...) != nullptr`). 호출 비용을 최소화하기 위해 함수 로컬 static 으로 결과를 캐싱한다.

### 변경 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `oos_log_internal()` | `src/storage/oos_log.hpp` | 파일 싱크를 먼저 수행하고, stderr 싱크는 `CUBRID_OOS_LOG_STDERR` 가 set 된 경우에만 실행 |

---

## Implementation

### 1. `oos_log.hpp` 변경

```cpp
#include <cstdlib>   // for std::getenv

inline void oos_log_internal (OosLogLevel level, const char *file, int line,
                              const char *func, const char *fmt, ...)
{
    // ... (header / body 포맷팅은 기존과 동일)

    // 1차 싱크: 항상 파일로 기록
    FILE *logfp = oos_log_get_file();
    if (logfp != nullptr)
      {
        std::fputs (header, logfp);
        std::fputs (body,   logfp);
        std::fputc ('\n',   logfp);
        std::fflush (logfp);
      }

    // 2차 싱크: CUBRID_OOS_LOG_STDERR 가 set 된 경우에만 stderr 에 기록
    static const bool stderr_enabled =
        (std::getenv ("CUBRID_OOS_LOG_STDERR") != nullptr);
    if (stderr_enabled)
      {
        std::fputs (header, stderr);
        std::fputs (body,   stderr);
        std::fputc ('\n',   stderr);
        std::fflush (stderr);
      }
}
```

### 2. 캐싱 전략

- `static const bool stderr_enabled = ...` 는 C++11 magic static 으로 thread-safe 하게 단 한 번만 초기화된다 (ISO C++ §6.7/4).
- `getenv` 가 프로세스 lifetime 동안 단 한 번만 호출되어 호출 비용 무시 가능.
- 환경 변수는 프로세스 시작 시 결정되므로 runtime 동안 변경할 필요가 없다.

### 3. 하위 호환성

- 기존 사용자가 OOS 디버그 로그를 **파일로만** 기대했다면 동작 변화 없음.
- 기존 사용자가 stderr 에서 로그를 **기대했다면** 환경 변수 설정이 필요 — 변경 사항은 릴리스 노트/문서에 명시.

---

## Alternative Options (not adopted)

설계 검토 과정에서 고려했으나 채택하지 않은 옵션:

| 옵션 | 설명 | 탈락 사유 |
|---|---|---|
| `\r\n` 로 교체 | stderr 에 `\r\n` 출력으로 raw-mode tty 에서도 정렬 유지 | 근본 원인(무조건 stderr) 을 가리는 workaround. cgdb 문제는 여전히 해결 안 됨. |
| `isatty(STDERR_FILENO)` + `tcgetpgrp()` 체크 | stderr 가 자기 tty 일 때만 기록 | 검사 로직 복잡하고 fragile (세션/프로세스 그룹 전환 시 오동작) |
| syslog 전환 | `syslog(LOG_DEBUG, ...)` 사용 | CUBRID 가 전반적으로 syslog 를 쓰지 않음 — 새 의존성 도입 부담 |
| stderr 브랜치 완전 제거 | 파일 싱크만 유지 | 로컬 개발 시 `tail -f` 없이 stderr 로 즉시 보고 싶은 시나리오가 있음 |

최종 선택은 **파일 전용 기본 + 환경 변수 opt-in** 의 조합으로, 운영 환경의 안정성과 개발 환경의 편의성을 모두 충족시킨다.

---

## A/C

- [ ] 기본 상태 (`CUBRID_OOS_LOG_STDERR` unset) 에서 OOS 를 트리거하는 DML 을 실행해도 stderr 에 OOS 로그 라인이 나타나지 않는다.
- [ ] 기본 상태에서 `$CUBRID/log/oos.log` 에는 기존과 동일하게 OOS 로그 라인이 기록된다.
- [ ] `CUBRID_OOS_LOG_STDERR=1` 환경에서 OOS DML 실행 시 stderr 와 `$CUBRID/log/oos.log` 양쪽에 동일한 라인이 기록된다.
- [ ] cgdb 아래에서 cub_server 를 실행하여 OOS 를 트리거해도 cgdb UI 가 깨지지 않는다.
- [ ] csql 이 실행 중인 tty 에서 백그라운드 cub_server 의 OOS 출력이 터미널에 계단식으로 찍히지 않는다.
- [ ] 기존 OOS 단위 테스트 / shell 테스트 regression 없음.

---

## Test Plan

### 재현 및 검증용 SQL

```sql
-- record > DB_PAGESIZE/8 (2KB) AND column > 512B 를 동시에 충족
DROP TABLE IF EXISTS t_oos_stderr;
CREATE TABLE t_oos_stderr (id INT PRIMARY KEY, payload BIT VARYING);
INSERT INTO t_oos_stderr VALUES (1, CAST(REPEAT('AA', 2500) AS BIT VARYING));
INSERT INTO t_oos_stderr VALUES (2, CAST(REPEAT('BB', 2500) AS BIT VARYING));
```

### 검증 스크립트 (repo root `test_oos_log_stderr.sh`)

`csql -udba -S -c "..." testdb` 를 두 번 수행하며 각각 다음을 확인한다.

| 케이스 | 기대 결과 |
|---|---|
| `CUBRID_OOS_LOG_STDERR` unset | `oos.log` 신규 라인 ≥ 1, stderr `OOS [` 매치 = 0 |
| `CUBRID_OOS_LOG_STDERR=1` | `oos.log` 신규 라인 ≥ 1, stderr `OOS [` 매치 ≥ 1 |

### 실측 결과

```
=== default (CUBRID_OOS_LOG_STDERR unset) ===
  oos.log new : 4 lines
  stderr hits : 0 lines
=== opt-in  (CUBRID_OOS_LOG_STDERR=1) ===
  oos.log new : 4 lines
  stderr hits : 4 lines
ALL OK
```

---

## Remarks

- 관련 커밋: `57f58b4eb [CBRD-26723] Gate OOS debug logger stderr output behind env var`
- `oos_log.hpp` 는 header-only 라 `oos_file.cpp` / `heap_file.c` 가 리컴파일된다.
- 단위 테스트(`unit_tests/oos/`) 는 별도의 `test_oos_log.hpp` 기반 logger fixture 를 사용하므로 이번 변경에 영향받지 않는다.
- 후속 작업으로 `cubrid.conf` 파라미터(`oos_log_stderr=yes/no`) 로 승격하는 안을 고려할 수 있으나, 환경 변수 방식이 개발자용 기능으로서 충분하다고 판단.
