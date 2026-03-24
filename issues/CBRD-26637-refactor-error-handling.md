# [OOS] OOS 에러 핸들링을 CUBRID 에러 시스템(er_set, ASSERT_ERROR)으로 리팩터링

## Description

### 배경

QA Manual Test 결과 Failed TC가 발생했을 때, 개발자가 에러 원인을 빠르게 판단하기 어렵다는 피드백이 있었다.

현재 OOS 코드의 에러 처리는 `oos_error` 매크로를 통해 stderr에만 출력하는 방식이다.
이 방식에는 다음과 같은 문제가 있다.

1. **release 빌드에서 완전 비활성화**: `oos_error` 가 `#if !defined(NDEBUG)` 안에 정의되어 있어
   release 빌드에서는 에러 메시지가 완전히 무시됨
2. **CUBRID 에러 시스템 미사용**: `er_set()` 을 호출하지 않아 클라이언트 에러 메시지 등
   CUBRID 표준 에러 경로에 에러가 전파되지 않음
3. **debug 빌드에서 조기 감지 불가**: `ASSERT_ERROR()` 가 없어 에러 발생 지점에서
   core dump가 생성되지 않고, 에러가 상위로 전파된 후에야 발견됨

### 목적

- OOS 에러를 CUBRID 표준 에러 시스템(`er_set`, `ASSERT_ERROR`)에 통합하여 디버깅을 용이하게 한다.
- release 빌드에서도 `oos_error` 로그가 출력되도록 한다.
- debug 빌드에서 에러 발생 시 가능한 빨리 core dump를 생성하여 원인 분석을 돕는다.

---

## Implementation

### 1. `oos_log.hpp` — `oos_error`, `oos_warn` 매크로를 release 빌드에서도 활성화

기존에는 모든 로그 매크로(`oos_trace` ~ `oos_error`)가 `#if !defined(NDEBUG)` 안에 있어
release 빌드에서 전부 비활성화되었다.

`oos_error` 와 `oos_warn` 을 조건부 컴파일 밖으로 이동하여 항상 활성화한다.
`oos_trace`, `oos_debug`, `oos_info` 는 기존과 동일하게 debug 전용으로 유지한다.

### 2. `oos_file.cpp` — 모든 에러 반환 경로에 `ASSERT_ERROR()` 추가

callee가 이미 `er_set()` 을 호출한 경우(예: `file_create_with_npages`, `recdes_allocate_data_area`,
`file_alloc`, `pgbuf_fix` 등), 해당 에러 반환 경로에 `ASSERT_ERROR()` 를 추가한다.

debug 빌드에서 callee가 에러를 설정하지 않았다면 즉시 assert failure로 core dump가 생성된다.

### 3. `oos_file.cpp` — bare `ER_FAILED` 반환 경로에 `er_set()` 추가

기존에 `er_set()` 없이 `ER_FAILED` 를 반환하던 경로에
`er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0)` 을 추가한다.

반환값도 `ER_FAILED` → `ER_GENERIC_ERROR` 로 변경하여 `er_set` 과 일치시킨다.

해당 경로:
- `spage_insert` 실패
- `spage_get_record` 실패
- `std::bad_alloc` / `std::exception` catch

### 4. `pgbuf_fix` 실패 시 `er_errid()` 반환

`pgbuf_fix` 는 실패 시 내부에서 `er_set()` 을 호출하므로,
`ASSERT_ERROR()` + `return er_errid()` 로 처리한다.

### 5. 기타

- `if (err)` → `if (err != NO_ERROR)` 일관성 수정 (`oos_file_alloc_new`)

---

## Remarks

- OOS 전용 에러 코드는 아직 정의되어 있지 않아 `ER_GENERIC_ERROR` 를 사용함.
  향후 OOS 전용 에러 코드가 필요하면 `error_code.h` 에 추가 가능.
- `heap_file.c` 의 `oos_error` 사용은 이미 `assert(false)` 또는 `abort()` 와 함께 사용되어 변경 불필요.
- PR: https://github.com/CUBRID/cubrid/pull/6940
