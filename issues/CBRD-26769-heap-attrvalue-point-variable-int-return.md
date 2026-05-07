# [OOS] [Refactoring] heap_attrvalue_point_variable 시그니처를 int 반환으로 변경하여 OOS read 실패 전파

> **TL;DR**
>
> OOS 인라인 페이로드가 손상돼도 SQL 에러로 보고되지 않고 NULL 값이 그대로 결과셋에 섞여 나간다. 이 티켓은 `heap_attrvalue_point_variable` 의 반환 타입을 `int` 로 바꿔 실패를 호출자까지 전파한다.

## Summary

- **변경**: `heap_attrvalue_point_variable` 의 반환 타입을 `void` 에서 `int` 로 바꾸고, 호출자 `heap_attrvalue_read` / `heap_midxkey_get_value` 두 곳도 에러를 전파한다.
- **부수 수정**: `default:` 분기에서 즉시 에러를 반환해, 다음 라인의 미초기화 `offset` 참조를 막는다.
- **신규 에러 코드 없음**: `ER_HEAP_BAD_RELOCATION_RECORD`, `ER_OUT_OF_VIRTUAL_MEMORY`, `ER_GENERIC_ERROR` 를 그대로 쓴다.

---

## Description

### 사전 정보

- `recdes_allocate_data_area` 는 NULL 시 `ER_FAILED` 만 반환하고 자체 `er_set` 을 하지 않는다 (`storage_common.c:310-324`). Case 4 에서 호출자 측 `er_set` 이 필요한 근거다.
- `assert_release(false)` 는 NDEBUG 에서 `ER_NOTIFICATION_SEVERITY` 만 남기고 통과한다 (`error_manager.h:189-191`). 이 동작이 본 티켓의 발단이다.
- `*is_oos` 는 호출자 cleanup 필요 여부 플래그. true 일 때만 `recdes_free_data_area` 를 부른다.

### 실패 모드

OOS 분기에서 발생할 수 있는 실패 모드를 다음 번호로 부른다.

| 케이스 | 트리거 시점 | 무엇이 잘못 |
|---|---|---|
| **Case 1** | `or_get_oid` 직후 (인라인 헤더 검증) | 인라인 페이로드 영역이 16B 미만 (버퍼 부족) |
| **Case 2** | `or_get_oid` / `or_get_bigint` 결과 검증 | bigint 읽기 실패 또는 OID 가 NULL |
| **Case 3** | length 범위 검증 | 인라인 length 가 (0, INT_MAX] 범위 밖 |
| **Case 4** | alloc 단계 | `recdes_allocate_data_area` 실패 (OOM) |
| **Case 5** | `oos_read` 단계 | `oos_read` 자체 실패 |
| **Case D** | `offset_size` switch default | recdes 헤더의 `offset_size` 가 비합법 값 |

Case 5 는 `oos_read` 가 이미 `er_set` 을 마치고 음수 코드를 반환한다. 호출자는 중복 `er_set` 없이 그 값을 그대로 올린다.

### 발단

CBRD-26741 (PR #7097) squash 단계에서 corrupt-OID 처리가 비대칭하게 정리되었다. 일부 경로는 `er_set` + `assert_release_error` 를 쓰고, 일부는 `assert_release(false)` 만 호출한다.

NDEBUG 빌드에서 `assert_release(e)` 는 abort 가 아니라 `er_set(ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, ...)` 만 호출한다 (`error_manager.h:189-191`). 결과:

- 사용자는 SQL ERROR 가 아니라 NOTIFICATION 로그만 본다.
- 함수는 `*is_oos = true; return;` 로 빠져나간다.
- 호출자는 NULL 데이터를 받지만 그 사실을 모른다.

### 현재 동작

OOS 분기 (`src/storage/heap_file.c:10656-10700`) 의 현재 실패 처리:

```c
/* Case 1: 인라인 페이로드 버퍼 부족 */
if (buf.endptr - buf.ptr < OR_OID_SIZE + OR_BIGINT_SIZE)
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
    raw->data = NULL;
    assert_release_error (er_errid () != NO_ERROR);
    *is_oos = true;
    return;
  }

or_get_oid (&buf, &oos_oid);
oos_len = or_get_bigint (&buf, &rc);

/* Case 2 / Case 3 : 같은 패턴 (ER_GENERIC_ERROR 로 통합) */

/* Case 4: alloc 실패 - er_set 누락 */
if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
  {
    raw->data = NULL;
    assert_release (false);     /* release 빌드에서는 NOTIFICATION 만 */
  }
/* Case 5: oos_read 실패 - callee 가 er_set 했지만 호출자가 받을 길 없음 */
else if (oos_read (thread_p, oos_oid, *raw) != NO_ERROR)
  {
    recdes_free_data_area (raw);
    raw->data = NULL;
    assert_release (false);
  }
*is_oos = true;
```

함수 진입부 (`heap_file.c:10618-10636`) 의 `offset_size` switch 는 더 위험하다 (Case D). `default:` 가 `assert_release(false); break;` 만 하고 통과해 버리면, 곧이은 `if (OR_IS_OOS (offset))` (`heap_file.c:10639`) 이 미초기화 `offset` 을 읽는다.

### 문제점

1. **시그니처가 `void`**. Case 1~3 에서 `er_set` 은 호출되지만 호출자는 에러가 났다는 사실 자체를 알 길이 없다. `er_errid()` 폴링이라도 해야 하는데 그것조차 하지 않는다.
2. **Case 4 는 `er_set` 마저 누락** (사전 정보 참조). 결과적으로 Case 1~3 과 달리 SQL 에러 응답이 아예 만들어지지 않는다.
3. **Case D — indeterminate read**. `default:` 경로에서 `offset` 이 초기화되지 않은 채 다음 라인 `OR_IS_OOS(offset)` 의 인자로 들어가, 스택 잔재값에 따라 OOS 분기 진입 여부가 비결정적으로 바뀐다.

진단 정보가 부족하다. Case 1~3 이 모두 `ER_GENERIC_ERROR` (인자 0개) 로 통합돼 있어 corruption 종류를 메시지로 구분할 수도, 손상된 OID 값을 실을 수도 없다.

### 변경 사항

| 항목 | 변경 |
|---|---|
| 시그니처 | `static void` -> `static int` |
| Case 1, 2, 3 | `er_set(ER_HEAP_BAD_RELOCATION_RECORD, OID_AS_ARGS)` + return code |
| Case 4 | 명시적 `er_set(ER_OUT_OF_VIRTUAL_MEMORY, (size_t) oos_len)` + return code |
| Case 5 | callee-set 그대로 전파 (중복 `er_set` 금지, `ASSERT_ERROR()` 만) |
| Case D | early-return `er_set(ER_GENERIC_ERROR)` -> indeterminate read 차단 |
| 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) | 반환값 받아 cleanup + 상위 전파 |

### `*is_oos` 계약

`*is_oos == true` 의 의미는 단 하나다. 호출자가 `recdes_free_data_area(&raw)` 를 불러야 할 버퍼가 남아 있다.

| 경로 | `*is_oos` | 호출자 cleanup |
|---|---|---|
| 성공 (OOS 분기) | `true` | 사용 후 `recdes_free_data_area(&raw)` |
| `OR_VAR_IS_NULL` early-return | `false` | 불필요 |
| Case D (default switch) | `false` | 불필요 |
| Case 1, 2, 3 (allocator 미접촉) | `false` | 불필요 |
| Case 4 (alloc 자체가 실패) | `false` | 불필요 |
| Case 5 (`oos_read` 실패) | `true` | 함수 내부에서 free + NULL 화. 호출자가 한 번 더 free 해도 NULL-tolerant 라 no-op. |

Case 5 에서도 `*is_oos = true` 로 두는 이유는, 호출자가 분기 없이 `if (is_oos) recdes_free_data_area(&raw);` 한 줄로 정상/실패를 모두 처리하게 하기 위해서다 (해제 후 NULL 화돼 있어 idempotent).

### NULL 안전성

Case 5 시점 `raw->data == NULL` 인 상태에서 호출자가 `recdes_free_data_area(&raw)` 를 부르는 경우. NDEBUG 와 DEBUG 의 가드 위치가 다르지만 양쪽 모두 no-op 으로 처리된다.

| 빌드 | 매크로 위치 | NULL 가드 |
|---|---|---|
| NDEBUG | `memory_alloc.h` 의 `#if defined(NDEBUG)` | 매크로 자체 (`if ((ptr)) ...`) |
| DEBUG | `memory_alloc.h` 의 `#else` | 함수 본문 첫 줄 (`if (ptr == NULL) return;`) |

---

## Specification Changes

사용자가 보는 스펙 변화는 없다. 내부 API 시그니처만 바뀐다.

### 케이스별 에러 코드 매핑

| Case | 트리거 | 에러 코드 | 코드 번호 | `*is_oos` |
|---|---|---|---|---|
| Case 1 | 인라인 영역 < 16B | `ER_HEAP_BAD_RELOCATION_RECORD` | -50 | false |
| Case 2 | OID null / bigint 실패 | `ER_HEAP_BAD_RELOCATION_RECORD` | -50 | false |
| Case 3 | length 범위 위반 | `ER_HEAP_BAD_RELOCATION_RECORD` | -50 | false |
| Case 4 | alloc 실패 | `ER_OUT_OF_VIRTUAL_MEMORY` | -3 | false |
| Case 5 | `oos_read` 실패 | callee-set 그대로 | (callee) | true |
| Case D | `offset_size` 비합법 | `ER_GENERIC_ERROR` | -2 | false |

### 함수 시그니처 변경

| 함수 | 위치 | 전 | 후 |
|---|---|---|---|
| `heap_attrvalue_point_variable` | `heap_file.c:10602-10718` | `static void` | `static int` (NO_ERROR / 에러 코드) |
| `heap_attrvalue_read` | `heap_file.c:10789-10848` | 호출 결과 무시 | 반환값 받아 에러 시 cleanup + 상위 전파 |
| `heap_midxkey_get_value` | `heap_file.c:10858-10928` | 시그니처는 이미 `int` | 호출자 측에서 에러 전파만 추가 |

릴리즈 빌드 차이: 종전에는 OOS corruption 시 NOTIFICATION 로그만 남기고 NULL 값 또는 비결정적 분기를 그대로 반환했다. 이제는 SQL 에러로 응답한다.

### 에러 코드 선택 근거

신규 에러 코드 없음. 6-step 워크플로우는 적용되지 않는다.

#### Case 1 / 2 / 3 — `ER_HEAP_BAD_RELOCATION_RECORD` (-50)

##### 메시지

- `cubrid.msg` ID 50: `"Internal error: relocation record of object %1$d|%2$d|%3$d may be corrupted."`
- 인자: `OID_AS_ARGS (&oos_oid)` -> `volid|pageid|slotid` (`oid.h:42`).

##### 의미 매핑 근거

`ER_HEAP_BAD_RELOCATION_RECORD` 는 본래 heap forwarder (`REC_RELOCATION`) 손상을 가리키지만, OOS 인라인 페이로드 역시 외부 페이지를 가리키는 forwarder 다. 메시지 본문 `"object ... may be corrupted"` 는 일반적이라 의미상 충돌이 없다.

##### 운영자 알람

`ER_HEAP_BAD_RELOCATION_RECORD` 는 `system_parameter.c:5618` 의 `call_stack_dump_error_codes[]` 에 등록돼 있다. SQL 에러와 함께 cub_server 가 콜스택을 자동 덤프하므로 별도 모니터링 룰은 불필요하다.

##### 진단 한계 (Case 2)

- `OID_ISNULL(&oos_oid)` 가 트리거되면 `OID_AS_ARGS(&oos_oid)` 는 `-1|-1|-1` 을 출력한다. 운영자가 어떤 record 의 어떤 attribute 인지 메시지만으로 식별할 수 없다.
- 이 한계는 그대로 둔다. 부모 OID 를 메시지에 싣자면 함수 시그니처를 더 늘리거나 `oos_error` 보조 로깅을 추가해야 하고, 둘 다 본 티켓 범위를 벗어난다.

#### Case 4 — 메모리 부족

- 메시지 (`cubrid.msg` ID 3): `"Out of virtual memory: unable to allocate %1$zu memory bytes."`
- 인자 arity = 1. 포맷 `%1$zu` 는 `size_t` 를 요구하므로 인자는 `(size_t) oos_len` 으로 캐스팅.
- 호출 측에서 명시적 `er_set` 이 필요한 이유는 사전 정보 참조.

#### Case 5 — `oos_read` 실패

- `oos_read` (`oos_file.cpp:1365`) 는 자체 `er_set` 함.
- 호출 측은 중복 `er_set` 금지. `ASSERT_ERROR()` 로 callee-set 검증만.

#### Case D — `offset_size` 불법값

- 인자 arity = 0.
- Case D 시점에는 OOS 인라인 페이로드를 아직 읽지 않아 OID 정보가 없다. `0|0|0` 을 채워 `ER_HEAP_BAD_RELOCATION_RECORD` 를 쓰는 것은 의미상 부정확하므로, recdes 헤더 자체의 inconsistency 에 해당하는 `ER_GENERIC_ERROR` 를 쓴다.

---

## Implementation

### Step 1. 시그니처 변경

forward 선언 (`heap_file.c:701-702`) 과 정의 (`10602-10604`) 모두 `static void` -> `static int`.

```c
/* before */
static void
heap_attrvalue_point_variable (RECDES * recdes, HEAP_CACHE_ATTRINFO * attr_info,
                               OR_ATTRIBUTE * attrepr, RECDES * raw, bool * is_oos);

/* after */
static int
heap_attrvalue_point_variable (RECDES * recdes, HEAP_CACHE_ATTRINFO * attr_info,
                               OR_ATTRIBUTE * attrepr, RECDES * raw, bool * is_oos);
```

### Step 2. 정상 종료 경로의 `*is_oos` 명시

`OR_VAR_IS_NULL` early-return (`heap_file.c:10609-10613`) 에서 `*is_oos` 를 명시적으로 설정한다. 호출자가 `is_oos` 를 pre-init 하지 않아도 함수 내부에서 계약이 성립하도록 한다.

```c
if (OR_VAR_IS_NULL (recdes->data, attrepr->location))
  {
    *is_oos = false;             /* 비-OOS 정상 경로 */
    return NO_ERROR;
  }
```

함수 마지막의 비-OOS 분기 (BLOB/CLOB/SET 등 길이 결정 경로, `heap_file.c:10703-10717`) 에서도 같은 처리를 한다.

```c
  /* ... non-OOS branch: TP_DOMAIN_TYPE switch on attrepr->domain ... */
  *is_oos = false;
  return NO_ERROR;
}   /* end of heap_attrvalue_point_variable */
```

### Step 3. Case D (`default:` switch) early-return

현재 `default: assert_release(false); break;` 는 NDEBUG 에서 통과해 버려 다음 라인 `if (OR_IS_OOS (offset))` 가 미초기화 `offset` 을 읽는다 (문제점 #3). `default:` 에서 즉시 에러를 반환해 그 도달 경로를 끊는다.

```c
default:
  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
  *is_oos = false;               /* OOS 분기 진입 전, allocator 미접촉 */
  return ER_GENERIC_ERROR;
```

### Step 4. OOS 분기 실패 처리 통합

OOS 분기에 들어가자마자 `OID_SET_NULL(&oos_oid)` 로 초기화한다. Case 1 의 `OID_AS_ARGS(&oos_oid)` 가 미초기화 메모리를 참조하지 않게 막는 용도다.

Case 1 의 전체 형태는 다음과 같다.

```c
if (OR_IS_OOS (offset))
  {
    OR_BUF buf;
    OID oos_oid;
    DB_BIGINT oos_len;
    int rc = NO_ERROR;
    int error;                   /* used by Case 5 below */

    OID_SET_NULL (&oos_oid);     /* Case 1 의 er_set 인자 안전성 보장 */

    buf.ptr = raw->data;
    buf.endptr = recdes->data + recdes->length;

    /* Case 1: 인라인 페이로드 버퍼 부족 - oos_oid 는 NULL OID */
    if (buf.endptr - buf.ptr < OR_OID_SIZE + OR_BIGINT_SIZE)
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD, 3,
                OID_AS_ARGS (&oos_oid));
        raw->data = NULL;
        *is_oos = false;          /* allocator 미접촉 */
        return ER_HEAP_BAD_RELOCATION_RECORD;
      }
```

Case 2 와 Case 3 은 가드 조건만 다르고 처리 형태는 Case 1 과 같다.

| Case | 가드 조건 |
|---|---|
| 2 | `rc != NO_ERROR \|\| OID_ISNULL (&oos_oid)` |
| 3 | `oos_len <= 0 \|\| oos_len > (DB_BIGINT) INT_MAX` |

에러 코드 (`ER_HEAP_BAD_RELOCATION_RECORD`), `*is_oos = false`, `OID_AS_ARGS (&oos_oid)` 인자 사용은 Case 1 과 동일.

Case 4 는 에러 코드가 다르다.

```c
    /* Case 4: recdes alloc 실패 - callee 는 er_set 안 함 */
    if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, (size_t) oos_len);
        raw->data = NULL;
        *is_oos = false;          /* alloc 자체가 실패 -> 산출물 없음 */
        return ER_OUT_OF_VIRTUAL_MEMORY;
      }
```

Case 5 는 `*is_oos` 값과 callee-set 전파가 다르다.

```c
    /* Case 5: oos_read 실패 - callee-set.
     *         이 시점 raw->data 는 살아있는 할당이라 free 후 NULL 화. */
    error = oos_read (thread_p, oos_oid, *raw);
    if (error != NO_ERROR)
      {
        ASSERT_ERROR ();          /* callee-set 검증, 중복 er_set 금지 */
        recdes_free_data_area (raw);
        raw->data = NULL;
        *is_oos = true;           /* 호출자 cleanup 호출이 NULL-tolerant no-op */
        return error;
      }

    *is_oos = true;
    return NO_ERROR;
  }
```

### Step 5. 호출자 변경

`heap_attrvalue_read` (`heap_file.c:10789-10848`):

```c
else
  {
    error = heap_attrvalue_point_variable (recdes, attr_info, attrepr, &raw, &is_oos);
    if (error != NO_ERROR)
      {
        /* 계약: is_oos == true 인 경우만 raw 정리 (Case 5).
         *       그 외 (Case 1~4, D) 는 allocator 미접촉이므로 cleanup 불필요. */
        if (is_oos)
          {
            recdes_free_data_area (&raw);
          }
        return error;
      }
  }
```

`heap_midxkey_get_value` (`heap_file.c:10858-10928`) 도 동일 패턴. 함수 진입부에서 이미 `db_make_null(value)` 를 호출하므로 (`10867`) 에러 분기에서 별도 호출 불필요. 함수 자체 시그니처는 이미 `int` 라 변화 없음.

```c
else
  {
    error = heap_attrvalue_point_variable (recdes, attr_info, att, &raw, &is_oos);
    if (error != NO_ERROR)
      {
        if (is_oos)
          {
            recdes_free_data_area (&raw);
          }
        return error;
      }
  }
```

### Step 6. 호출 체인

```text
heap_attrinfo_read_dbvalues / heap_get_indexvalue_of_attribute / ...
   |
   v
heap_attrvalue_read (int)         ----  변경: 반환값 받기
   |
   v
heap_attrvalue_point_variable (int)  ----  void -> int
   |
   +-- offset_size switch default       Case D
   +-- or_get_oid                       OID null      -> Case 2
   +-- or_get_bigint                    rc != NO_ERROR -> Case 2
   +-- recdes_allocate_data_area        NULL 반환      -> Case 4
   +-- oos_read                         실패           -> Case 5
```

---

## Acceptance Criteria

### 시그니처

- [ ] `heap_attrvalue_point_variable` 의 반환 타입이 `int`. forward 선언 (`heap_file.c:701-702`) 과 정의 (`10602-10604`) 둘 다 갱신.

### 정상 경로

- [ ] `OR_VAR_IS_NULL` early-return: `*is_oos = false; return NO_ERROR;` 명시.
- [ ] OOS 가 아닌 분기 (BLOB/CLOB/SET 등) 함수 끝: `*is_oos = false; return NO_ERROR;`.

### Case D (default switch)

- [ ] `default:` 가 `er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0)` + `*is_oos = false;` + `return ER_GENERIC_ERROR;`.
- [ ] 결과적으로 미초기화 `offset` 으로 다음 라인 `OR_IS_OOS(offset)` 도달 불가.

### OOS 분기 진입 직후

- [ ] OOS 분기 진입 직후 (블록 첫 줄) `OID_SET_NULL(&oos_oid);` 위치. Case 1 의 `OID_AS_ARGS(&oos_oid)` 가 미초기화 메모리를 읽지 않음.

### Case 1~5 처리

- [ ] Case 1 (인라인 페이로드 < 16B) -> `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`.
- [ ] Case 2 (`rc != NO_ERROR || OID_ISNULL`) -> `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`.
- [ ] Case 3 (`oos_len <= 0 || oos_len > INT_MAX`) -> `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`.
- [ ] Case 4 (alloc 실패) -> `ER_OUT_OF_VIRTUAL_MEMORY` (`(size_t) oos_len`), `*is_oos = false`.
- [ ] Case 5 (`oos_read` 실패) -> callee-set 전파, `recdes_free_data_area` + `*is_oos = true`.
- [ ] 모든 에러 반환 경로에서 `raw->data == NULL`.

### 호출자

- [ ] `heap_attrvalue_read` (`10789-10848`) / `heap_midxkey_get_value` (`10858-10928`) 가 반환값을 받아 에러 시 `if (is_oos) recdes_free_data_area(&raw);` 후 상위 전파.

### 단위 테스트 (GoogleTest)

- [ ] `unit_tests/oos/test_oos.cpp` 의 `TEST(...)` / `EXPECT_*` / `ASSERT_*` 매크로 사용 (파일 19라인 `#include "gtest/gtest.h"`).
- [ ] `heap_attrvalue_point_variable` 가 `static` 이므로 `unit_tests/oos/test_oos_common.hpp` 에 `bridge_heap_attrvalue_point_variable` 헬퍼 추가 (기존 `bridge_oos_*` 패턴, `test_oos.cpp:36-40` 참고).
- [ ] 테스트는 합성 `RECDES` 빌드 후 가변 영역 헤더 (`OR_VAR_BIT_OOS = 0x1`, `object_representation.h:441`) 를 set 하고 인라인 16B 영역을 시나리오별로 채워 호출.

#### Case 별 단위 테스트 커버리지 요약

| Case | In-scope test? | 근거 |
|---|---|---|
| 1 | yes | 인라인 영역 합성 가능 |
| 2 | yes | 인라인 영역 합성 가능 |
| 3 | yes | 인라인 영역 합성 가능 |
| 4 | no | OOM injection 인프라 부재 |
| 5 | no | mock seam 부재, callee-set 비결정 |
| D | no | `offset_size` 합성 인프라 부재 |

#### In-scope 시나리오 상세

| 케이스 | 시나리오 | 검증 |
|---|---|---|
| Case 1 | 인라인 페이로드 영역 길이를 `OR_OID_SIZE + OR_BIGINT_SIZE` 미만으로 합성 | `EXPECT_EQ(er_errid(), ER_HEAP_BAD_RELOCATION_RECORD)` + `EXPECT_FALSE(is_oos)` |
| Case 2 | 인라인 OID 8B 를 NULL OID 로 채움 | 동일 |
| Case 3 | 인라인 length 8B 를 `0`, `-1`, `(DB_BIGINT) INT_MAX + 1` 각각 | 동일 |

### 회귀

- [ ] 정상 OOS round-trip 동작 변화 없음. `unit_tests/oos/test_oos.cpp`, `test_oos_delete.cpp`, `test_oos_bestspace.cpp`, `test_oos_remove_file.cpp` 변경 없이 통과.

### CI

- [ ] `just build-test` (debug + `unit_tests/oos`) 통과.
- [ ] CircleCI `test_sql`, `test_medium` 통과.

---

## Definition of Done

- [ ] 위 A/C 충족.
- [ ] PR 리뷰 / merge.
- [ ] PR #7097 리뷰에서 약속한 후속 작업 처리:
  - r3200880248 (hornetmj): release 빌드에서 `assert_release(false)` 를 SQL 에러로 바꾸는 별도 티켓 — 본 티켓이 그 후속임을 PR 본문에 명시. (https://github.com/CUBRID/cubrid/pull/7097#discussion_r3200880248)
  - r3201449095 (vimkim): TODO 블록 제거 후 후속 티켓에서 `int` 시그니처로 정리 — 본 티켓에서 시그니처 전환. (https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449095)
  - r3201449462 (vimkim): `OID_AS_ARGS` 패턴은 후속 티켓 — Case 1~3 에서 `OID_AS_ARGS(&oos_oid)` 사용. (https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449462)
- [ ] CBRD-26741 머지 후 본 티켓의 라인 번호를 다시 한 번 확인한다.

---

## Out of Scope

본 티켓은 *시그니처 / 에러 전파 / `default:` indeterminate read 제거* 만 다룬다. 다음은 별도 티켓.

- 스택 버퍼 fast-path (PR #7097 review comment 3201451481, `HEAP_CACHE_ATTRINFO` scratch buffer 도입).
- PEEK-mode `oos_read` 와 dbvalue zero-copy. `heap_attrvalue_read` 의 TODO 주석 ("TODO: heap_attrvalue_transform_to_dbvalue() used to PEEK &raw" 로 시작하는 블록, 작성 시점 `heap_file.c:10835` 부근) 은 본 티켓 손대지 않음.
- OOS 전용 corruption 에러 코드 신규 정의는 CBRD-26637 후속 작업이다. 정의되면 `ER_HEAP_BAD_RELOCATION_RECORD` 호출처를 일괄 교체하면서 6-step 워크플로우를 그쪽 티켓에서 수행한다.
- 로컬 `offset` 변수를 함수에서 완전히 제거하는 후속 정리 (OOS 분기에서 `OR_IS_OOS` 가 `offset` 참조하지 않도록 매크로 측 변경). 본 티켓은 default 경로 indeterminate read 만 차단한다.
- Case 4 (alloc 실패) corruption-injection 테스트 — 일반 OOM 시나리오 일부이며 기존 OOM 인프라가 다룸.
- Case 5 (`oos_read` 실패) corruption-injection 테스트는 두 가지 이유로 본 티켓에서 빠진다. 첫째, bridge 가 `oos_read` mock seam 을 제공하지 않아 단위 테스트로는 trigger 가 불가능하다. 둘째, end-to-end 에서 잘못된 OID 를 심는 방식은 callee 측 결과 (`ER_PB_BAD_PAGEID` 등) 가 페이지 버퍼 상태에 따라 달라져 expected value 를 고정할 수 없다. callee 동작 자체는 기존 `oos_read` 단위 테스트가 다루므로, 본 티켓은 호출 체인이 그 에러 코드를 그대로 전파하는지만 코드 리뷰에서 본다.
- Case D (recdes 헤더 `offset_size` corruption) 유닛 테스트 — 합성 RECDES 헤더의 `offset_size` 비트필드를 비합법 값으로 직접 조작하는 인프라가 현재 `unit_tests/oos/` 에 없음. heap recdes 헤더 corruption 일반 테스트 (별도 티켓) 에서 다룬다.
- Case 2 진단 메시지에 부모 OID / `recdes->length` / `attrepr->location` 추가 — 함수 시그니처 추가 변경 또는 `oos_error` 보조 로깅 필요. 본 티켓의 "에러 전파 채널 확보" 범위 밖.

---

## References

소스 라인 번호는 `oos-refactor-oos-read-with-length` 브랜치 기준.

### `src/storage/heap_file.c`

| 라인 | 무엇 |
|---|---|
| 701-702 | `heap_attrvalue_point_variable` forward 선언 |
| 705 | `heap_attrvalue_read` forward 선언 |
| 707-708 | `heap_midxkey_get_value` forward 선언 |
| 10602-10718 | `heap_attrvalue_point_variable` 정의. OOS 분기는 10639-10702 |
| 10630-10639 | `offset_size` switch + 다음 라인 `OR_IS_OOS(offset)` (indeterminate read 지점) |
| 10789-10848 | `heap_attrvalue_read` (호출자 1) |
| 10858-10928 | `heap_midxkey_get_value` (호출자 2) |

### 다른 소스

| 파일:라인 | 무엇 |
|---|---|
| `src/storage/oos_file.cpp:1365` | `oos_read(THREAD_ENTRY *, const OID &, RECDES &)` (callee, 이미 int, callee-set) |
| `src/storage/storage_common.c:310-324` | `recdes_allocate_data_area` (NULL 시 `ER_FAILED` 만, 자체 `er_set` 없음) |
| `src/storage/storage_common.c:327-330` | `recdes_free_data_area` -> `db_private_free_and_init(NULL, rec->data)` |
| `src/base/memory_alloc.h` `#if defined(NDEBUG)` 블록 | NDEBUG 빌드 `db_private_free_and_init` 매크로 (NULL 가드) |
| `src/base/memory_alloc.h` `#else /* NDEBUG */` 블록 | DEBUG 빌드 `db_private_free_and_init` 매크로 (가드 없음 — 본문에서 가드) |
| `src/base/memory_alloc.c` | `db_private_free_debug` / `db_private_free_release` 본문 첫 줄 `if (ptr == NULL) { return; }` |
| `src/base/error_code.h:52` | `ER_GENERIC_ERROR` (-2) |
| `src/base/error_code.h:53` | `ER_OUT_OF_VIRTUAL_MEMORY` (-3) |
| `src/base/error_code.h:107` | `ER_HEAP_BAD_RELOCATION_RECORD` (-50) |
| `src/base/error_manager.h:189-191` | NDEBUG `assert_release(e)`: `er_set(ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, 1, ...)` (abort 아님) |
| `src/base/error_manager.h:258-273` | `ASSERT_ERROR()`, `ASSERT_ERROR_AND_SET(error_code)` |
| `src/base/system_parameter.c:5618` | `call_stack_dump_error_codes[]` 에 `ER_HEAP_BAD_RELOCATION_RECORD` 등록 (alarm/dump 채널) |
| `src/base/object_representation.h:441` | `OR_VAR_BIT_OOS = 0x1` |
| `src/base/object_representation.h:451` | `OR_IS_OOS(length)` 매크로 |
| `src/storage/oid.h:42` | `OID_AS_ARGS(oidp)` -> `(oidp)->volid, (oidp)->pageid, (oidp)->slotid` |
| `src/storage/oid.h:88` | `OID_SET_NULL(oidp)` |
| `msg/en_US.utf8/cubrid.msg` ID 3 | `"Out of virtual memory: unable to allocate %1$zu memory bytes."` |
| `msg/en_US.utf8/cubrid.msg` ID 50 | `"Internal error: relocation record of object %1$d|%2$d|%3$d may be corrupted."` |
| `unit_tests/oos/test_oos.cpp:19` | `#include "gtest/gtest.h"` (GoogleTest) |
| `unit_tests/oos/test_oos_common.hpp` | bridge 헬퍼 추가 위치 |
| `src/storage/oos_log.hpp:166-168` | `oos_error` 매크로 (release 빌드에서도 활성, Case 2 진단 보강 후속 티켓에서 활용 가능) |

## Remarks

- 부모 에픽: CBRD-26583 (OOS M2).
- 본 티켓 작성 시점 기준 CBRD-26741 (`oos_read` caller-preallocated 리팩터링) 은 이미 브랜치 `oos-refactor-oos-read-with-length` 에 적용.
- 관련 티켓:
  - CBRD-26637 — error handling refactor. OOS 전용 에러 코드 미정의로 `ER_GENERIC_ERROR` 사용한 선례. 본 티켓은 `ER_HEAP_BAD_RELOCATION_RECORD` 재사용으로 한 단계 진전. OOS 전용 코드 신규 정의는 후속 티켓으로.
