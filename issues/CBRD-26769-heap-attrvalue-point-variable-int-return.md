# [OOS] [Refactoring] heap_attrvalue_point_variable 시그니처를 int 반환으로 변경하여 OOS read 실패 전파

> **TL;DR**: `heap_attrvalue_point_variable` 의 반환 타입을 `void` 에서 `int` 로 바꾸어, OOS 인라인 페이로드 corruption 과 `oos_read` 실패가 호출자에게 정상 에러 코드로 전파되도록 한다. 동시에 `default:` switch 의 미초기화 `offset` 읽기 (`OR_IS_OOS (offset)` 라인 — C++17 indeterminate value 로 인한 비결정적 분기 선택) 를 early-return 으로 제거한다.

## Summary

- **문제 / 목적**: 현재 함수가 `void` 라 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 가 OOS 분기의 어떤 실패 모드도 받아낼 채널이 없다. 또한 `offset_size` switch 의 `default:` 케이스가 `assert_release` 만 한 뒤 미초기화 `offset` 으로 다음 라인의 `OR_IS_OOS (offset)` 검사에 진입해, release 빌드에서 indeterminate `offset` 값에 따라 OOS 분기로 갈지 비-OOS 분기로 갈지 비결정적이 된다.
- **원인 / 배경**: CBRD-26741 squash 단계에서 corrupt-OID 처리가 일부는 `er_set` + `assert_release_error` 로, 일부는 `assert_release (false)` 단독으로 비대칭하게 정리되었다. NDEBUG 빌드에서 `assert_release(e)` 매크로는 abort 가 아니라 `er_set (ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, ...)` 만 발생시키므로 (`error_manager.h:189-191`), 기존 alloc/`oos_read` 실패 경로는 release 빌드에서 SQL ERROR 가 아닌 NOTIFICATION 로그만 남기고 NULL 데이터로 진행될 수 있다.
- **제안 / 변경**: 시그니처 `void` → `int`. 호출자 체인 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 에서 에러 전파. OOS 인라인 페이로드 corruption 3 종 (4-1, 4-2, 4-3) 은 `ER_HEAP_BAD_RELOCATION_RECORD` 로 통일, alloc 실패 (4-4) 는 `ER_OUT_OF_VIRTUAL_MEMORY`, `oos_read` 실패 (4-5) 는 callee-set 코드 그대로 전파. `default:` switch 는 `ER_GENERIC_ERROR` 로 early-return.
- **영향 범위**: `src/storage/heap_file.c` 의 가변 길이 속성 읽기 경로 (heap scan, midxkey 추출). 정상 경로 동작 변화 없음. release 빌드에서 OOS corruption 시 SQL 에러로 정확히 응답.

---

## Description

### 배경

CBRD-26741 (PR #7097) 에서 `oos_read` 를 caller-preallocated buffer API 로 리팩터링하면서, `heap_attrvalue_point_variable` 가 인라인 16B 페이로드 (`OID 8B | full_length BIGINT 8B`) 를 읽어 `recdes_allocate_data_area` + `oos_read` 로 본문을 끌어오는 흐름으로 정리되었다. 그러나 함수 시그니처는 여전히 `void` 다.

본 티켓 작성 시점 (브랜치 `oos-refactor-oos-read-with-length`) 에서 CBRD-26741 의 리팩터는 이미 적용된 상태이며, 이하 line numbers 는 그 상태 기준이다.

현재 코드의 OOS 분기 (`src/storage/heap_file.c:10656-10700`) 는 4 가지 실패 모드를 가지지만 처리 방식이 비대칭이다:

```c
/* 4-1) 인라인 페이로드 버퍼 부족 */
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

/* 4-2) bigint rc 또는 OID null */
if (rc != NO_ERROR || OID_ISNULL (&oos_oid))
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
    /* ... 동일 ... */
    return;
  }

/* 4-3) 인라인 길이 범위 위반 */
if (oos_len <= 0 || oos_len > (DB_BIGINT) INT_MAX)
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
    /* ... 동일 ... */
    return;
  }

/* 4-4) recdes alloc 실패 - er_set 누락 */
if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
  {
    raw->data = NULL;
    assert_release (false);
  }
/* 4-5) oos_read 실패 - er_set 은 callee 가 했으나 함수가 void 라 호출자가 알 길이 없음 */
else if (oos_read (thread_p, oos_oid, *raw) != NO_ERROR)
  {
    recdes_free_data_area (raw);
    raw->data = NULL;
    assert_release (false);
  }
*is_oos = true;
```

또한 함수 진입부의 offset switch 가 corrupted offset_size 값에 대해 `default: assert_release (false); break;` 로만 처리한 뒤 (`heap_file.c:10630-10634`) 곧바로 다음 라인 `OR_IS_OOS (offset)` 에서 미초기화 로컬 `offset` 을 읽는다 (`heap_file.c:10639`).

### 문제점

1. **시그니처가 `void` 라 호출자가 어떤 실패 모드도 받을 수 없다**: 4-1~4-3 경로는 `er_set` 까지는 하지만, 함수가 `void` 라 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 가 "에러 발생 여부" 자체를 알지 못한다. 호출자는 `er_errid ()` 폴링에 의존해야 하는데 현재 그렇게 하지도 않는다.
2. **alloc 실패 경로는 `er_set` 마저 누락**: `recdes_allocate_data_area` 는 `db_private_alloc` 가 NULL 일 때 `ER_FAILED` 만 반환하고 자체 `er_set` 은 하지 않는다 (`storage_common.c:309-324`). NDEBUG 빌드에서 `assert_release (false)` 는 abort 가 아니라 `er_set (ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, ...)` 만 호출하므로 (`error_manager.h:189-191`), 사용자에게 SQL ERROR 가 아닌 NOTIFICATION 만 남고 함수는 그대로 `*is_oos = true; return;` 로 빠져나가 NULL 데이터를 호출자에게 넘긴다.
3. **`oos_read` 실패 경로도 같은 문제**: callee 가 `er_set` 한 에러 코드는 있으나, 호출자가 그것을 받아 상위로 전파하지 못한다.
4. **`default:` switch 케이스의 indeterminate read**: `default:` 에서는 로컬 `offset` 이 미초기화로 남고, 그 다음 라인 `if (OR_IS_OOS (offset))` (`heap_file.c:10639`) 가 그 값을 읽는다. `.c` 파일이 C++17 로 컴파일되는 환경 (CLAUDE.md 참조) 에서 이는 UB 가 아니라 indeterminate value 이지만 (`unsigned char` 가 아닌 자동 정수형의 indeterminate read 는 C++17 [basic.indet] 상 indeterminate value 다), 결과적으로 indeterminate `offset` 값에 따라 OOS 분기로 갈지 비-OOS 분기로 갈지 비결정적인 분기 선택이 발생한다. NDEBUG 빌드의 `assert_release` 는 abort 하지 않으므로 release 빌드 사용자가 그대로 노출된다.
5. **에러 코드가 `ER_GENERIC_ERROR` 로 묶여 있어 진단이 어렵다**: 4-1~4-3 모두 같은 코드라 어떤 corruption 모드인지 메시지로 구분이 안 되고, `ER_GENERIC_ERROR` 는 형식 인자를 받지 않아 손상된 OID 값을 메시지에 실을 수 없다.

### 목적

- `heap_attrvalue_point_variable` 시그니처를 `void` → `int`.
- 4 종 OOS 실패 모드 (인라인 페이로드 버퍼 부족, OID/bigint corruption, 길이 범위 위반, alloc/`oos_read` 실패) 를 모두 `er_set` + return code 로 표준화.
- `default:` switch 케이스를 명시적 에러로 처리해 `OR_IS_OOS (offset)` 라인의 indeterminate read 제거.
- 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 에서 에러 수신 후 상위 전파.

### 호출자 정리 계약

- **성공 시 (NO_ERROR)**: OOS 분기에서는 `*is_oos = true`, `raw->data` 는 새로 할당된 버퍼를 가리킴. 호출자는 사용 후 `recdes_free_data_area (&raw)` 로 해제.
- **에러 반환 시 — `is_oos` 의 의미는 "OOS allocator 를 건드려서 cleanup 이 필요한 데이터를 만들었는지" 다.**
  - **할당 전 실패 (4-1, 4-2, 4-3, 4-4)**: 살아있는 할당이 없으므로 `*is_oos = false`. 호출자는 cleanup 호출을 건너뛴다.
  - **할당 후 실패 (4-5)**: `oos_read` 가 실패하기 직전에 `raw->data` 는 할당된 상태였고, 함수 내부에서 즉시 `recdes_free_data_area (raw)` 로 해제 후 `raw->data = NULL` 로 만든다. `*is_oos = true` 는 성공 경로와 동일하게 유지하여, 호출자가 `if (is_oos) recdes_free_data_area (&raw);` 패턴으로 cleanup 을 시도하더라도 no-op 가 되도록 한다 (아래 NULL-안전성 의존 참조).
  - **`OR_VAR_IS_NULL` early-return**: 정상 경로이며, 명시적으로 `*is_oos = false;` 를 설정한 뒤 `return NO_ERROR;`. (호출자가 invocation 전 `is_oos = false` 를 pre-init 하지 않아도 안전하도록 함수 내부에서 보장.)
  - **`default:` switch early-return**: 4-1 단계 이전이라 OOS 분기 진입 전이다. `*is_oos = false;` 를 설정한 뒤 `return ER_GENERIC_ERROR;`.
- **NULL-안전성 의존**: 4-5 경로에서 호출자가 `recdes_free_data_area (&raw)` 를 부를 때 `raw->data == NULL` 이다. `recdes_free_data_area` 는 내부적으로 `db_private_free_and_init (NULL, raw->data)` 를 부르며 (`storage_common.c:327-329`), NDEBUG 빌드에서 이 매크로는 `if ((ptr)) ...` NULL 가드를 가진다 (`memory_alloc.h:124-130`). DEBUG 빌드에서는 매크로 자체에 NULL 가드가 없지만, 그 안쪽의 `db_private_free` 가 함수 본문 첫 줄에 `if (ptr == NULL) { return; }` 가드를 가지므로 (`memory_alloc.c` 의 `db_private_free_debug` / `db_private_free_release` 본문) NULL 인자가 들어와도 안전하다. 따라서 `recdes_free_data_area` 는 양쪽 빌드에서 NULL-tolerant 다.

---

## Specification Changes

사용자/매뉴얼 관점의 스펙 변화 없음. 내부 API 시그니처 변경.

| 함수 | 파일 | 변경 전 | 변경 후 | 변경 요점 |
|---|---|---|---|---|
| `heap_attrvalue_point_variable` | `src/storage/heap_file.c:10602-10718` | `static void` | `static int` (NO_ERROR / 에러 코드 반환) | 시그니처 변경; OOS 분기 4 경로 모두 `er_set` + return; `default:` switch 의 early-return 으로 indeterminate read 제거; `OR_VAR_IS_NULL` early-return 을 `*is_oos = false; return NO_ERROR;` 로 명시 |
| `heap_attrvalue_read` | `src/storage/heap_file.c:10789-10848` | 내부에서 호출 후 결과 무시 | 반환값 받아 에러 시 cleanup 후 즉시 return | 호출자 측 에러 전파 |
| `heap_midxkey_get_value` | `src/storage/heap_file.c:10858-10928` | 동일 | 동일 (이미 int 반환이라 본인 시그니처 변화 없음) | 호출자 측 에러 전파 |

릴리즈 빌드의 사용자 가시 동작 변화: OOS corruption 시 종전에는 NOTIFICATION 만 남기고 NULL 데이터를 흘려보내거나 미초기화 `offset` 으로 비결정적 분기 선택을 하던 경로가, 이제 `ER_HEAP_BAD_RELOCATION_RECORD` / `ER_OUT_OF_VIRTUAL_MEMORY` / `ER_GENERIC_ERROR` (또는 `oos_read` 의 callee-set 코드) 로 정상 SQL 에러 응답이 된다.

### 에러 코드 선택

본 변경은 **신규 에러 코드를 도입하지 않는다**. 따라서 `CLAUDE.md` 의 6-step 워크플로우 (`error_code.h`, `dbi_compat.h`, `cubrid.msg` en/ko, `ER_LAST_ERROR`, CCI `base_error_code.h`) 는 적용되지 않는다.

각 실패 site 별 코드 선택과 근거:

#### 4-1 / 4-2 / 4-3: OOS 인라인 페이로드 corruption — `ER_HEAP_BAD_RELOCATION_RECORD`

- 메시지 (`msg/en_US.utf8/cubrid.msg` ID 50): `"Internal error: relocation record of object %1$d|%2$d|%3$d may be corrupted."` — 3 인자 (volid, pageid, slotid) `OID_AS_ARGS (&oos_oid)` 로 그대로 펼침 (`oid.h:42`).
- "relocation record" 라는 용어는 원래 heap forwarder (REC_RELOCATION) 를 가리키지만, OOS 인라인 페이로드 역시 *bigobject 의 첫 페이지 위치를 가리키는 forwarder* 라는 의미에서 동일 카테고리. 메시지 본문 "object ... may be corrupted" 는 일반적이라 의미 충돌이 없다.
- **운영자 알람 영향 인지**: `ER_HEAP_BAD_RELOCATION_RECORD` 는 `system_parameter.c` 의 `call_stack_dump_error_codes[]` (5614 라인 부근부터 시작하는 alarm/dump 대상 코드 배열) 에 등록되어 있어, `er_set` 시 콜스택 덤프 알람이 발동된다. 본 티켓의 변경으로 OOS 인라인 페이로드 corruption 발생 시 이 알람이 실제로 트리거되며, 운영자 측 모니터링 룰을 새로 추가하지 않아도 기존 알람 채널로 자동 노출된다. 이는 의도된 동작이다.
- 한 함수의 인라인-페이로드 corruption 신호를 단일 코드로 묶어 진단 일관성을 유지. 향후 OOS 전용 코드 신규 정의 (CBRD-26637 후속) 가 결정되면 일괄 교체.
- **진단 한계 (4-2 한정)**: `OID_ISNULL (&oos_oid)` 로 4-2 가 트리거된 경우, `OID_AS_ARGS (&oos_oid)` 는 `-1|-1|-1` (NULL OID) 을 출력한다. 이 메시지만으로는 어떤 heap record 의 어떤 attribute 가 손상되었는지 운영자가 곧바로 식별할 수 없다. 본 티켓에서는 이 한계를 명시적으로 수용한다 — 부모 OID / `recdes->length` / `attrepr->location` 를 진단에 포함시키려면 `oos_error` 보조 로깅을 추가하거나 (별도 변경) 함수 시그니처 자체에 부모 컨텍스트를 추가해야 하는데 (out of scope), 본 티켓의 범위는 "에러 전파 채널 확보" 까지다. 운영자는 알람 콜스택 덤프와 `ER_HEAP_BAD_RELOCATION_RECORD` 가 발생한 SQL/scan 컨텍스트 (상위 호출자 로그) 로부터 손상된 record 를 식별한다.

#### 4-4: `recdes_allocate_data_area` 실패 — `ER_OUT_OF_VIRTUAL_MEMORY`

- 메시지 (`msg/en_US.utf8/cubrid.msg` ID 3): `"Out of virtual memory: unable to allocate %1$zu memory bytes."` — `%1$zu` 는 `size_t` 를 요구하므로 인자는 `(size_t) oos_len` 으로 캐스팅. 인자 arity = 1.
- `recdes_allocate_data_area` 는 자체 `er_set` 을 하지 않고 `ER_FAILED` 만 반환 (`storage_common.c:309-324`) 하므로, 호출 측에서 명시적 `er_set` 필요. 메모리 부족이라는 근본 원인을 정확히 표현.

#### 4-5: `oos_read` 실패 — callee-set 코드 그대로 전파

- `oos_read` (`oos_file.cpp:1365`) 는 이미 자체 에러 코드를 `er_set` 함. 호출 측은 중복 `er_set` 금지, `ASSERT_ERROR ()` 만 두어 callee 가 set 했음을 검증.

#### `default:` switch (recdes 헤더 offset_size corruption) — `ER_GENERIC_ERROR`

- 이 시점에는 OOS 인라인 페이로드를 아직 읽지 않았으므로 OID 컨텍스트가 존재하지 않는다. `ER_HEAP_BAD_RELOCATION_RECORD` 에 OID 자리에 `0|0|0` 을 넣는 것은 의미적으로 부정확하므로 사용하지 않는다.
- recdes 헤더 자체의 corruption 은 일반적인 internal-state inconsistency 이므로 `ER_GENERIC_ERROR` (`error_code.h:52`) 로 처리. 인자 arity = 0.

---

## Implementation

### 1. 시그니처 변경

forward 선언 (`heap_file.c:701-703`) 과 정의 (`10602-10604`) 모두 `static void` → `static int`.

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

### 2. 정상 종료 경로의 명시적 NO_ERROR 와 `*is_oos` 설정

`OR_VAR_IS_NULL` 의 이른 return (`heap_file.c:10609-10613`) 에서 `*is_oos = false;` 를 명시적으로 설정한 뒤 `return NO_ERROR;` 한다 (호출자가 pre-init 하지 않아도 contract 가 함수 내부에서 보장되도록).

```c
if (OR_VAR_IS_NULL (recdes->data, attrepr->location))
  {
    *is_oos = false;             /* 비-OOS 정상 경로 */
    return NO_ERROR;
  }
```

함수 끝의 비-OOS 분기 (BLOB/CLOB/SET 등 길이 결정, `heap_file.c:10703-10717`) 도 `*is_oos = false;` 를 명시한 뒤 함수 끝에서 `return NO_ERROR;` 로 마무리.

```c
  /* ... non-OOS branch: TP_DOMAIN_TYPE switch on attrepr->domain ... */
  *is_oos = false;
  return NO_ERROR;
}   /* end of heap_attrvalue_point_variable */
```

### 3. `default:` switch 의 early-return 으로 indeterminate read 제거

현재 코드 (`heap_file.c:10630-10634`) 는 `default: assert_release (false); break;` 로 빠지지만, 그 직후 라인 `if (OR_IS_OOS (offset))` (`heap_file.c:10639`) 는 미초기화 로컬 `offset` 을 읽는다. C++17 [basic.indet] 상 `unsigned char` 가 아닌 자동 정수형의 indeterminate read 는 UB 가 아니라 indeterminate value 지만, 결과적으로 indeterminate `offset` 값에 따라 OOS 분기로 갈지 비-OOS 분기로 갈지 비결정적인 분기 선택이 발생한다. NDEBUG 빌드의 `assert_release(false)` 는 `er_set (ER_NOTIFICATION_SEVERITY, ...)` 만 하고 진행을 막지 않으므로, release 빌드 사용자가 그대로 노출된다. 본 티켓에서는 `default:` 에서 즉시 에러 반환하여 `OR_IS_OOS` 라인 도달 자체를 차단한다.

```c
default:
  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
  *is_oos = false;               /* OOS 분기 진입 전, allocator 미접촉 */
  return ER_GENERIC_ERROR;
```

로컬 `offset` 변수 자체는 OOS 분기에서 `OR_IS_OOS (offset)` 인자로 사용되므로 dead-code 가 아니다. 단지 `default:` 경로에서 미초기화 상태로 그 라인까지 흘러가는 것이 문제이며, 본 변경은 그 흐름만 차단한다.

### 4. OOS 분기 4 종 실패 모드 통합

`oos_oid` 는 OOS 분기 진입 직후 (`if (OR_IS_OOS (offset))` 블록이 열린 직후, 4-1 의 bounds 검사 이전) 에 `OID_SET_NULL (&oos_oid);` 로 초기화하여, 4-1 단계에서 `OID_AS_ARGS (&oos_oid)` 가 미초기화 메모리를 읽지 않도록 한다.

```c
if (OR_IS_OOS (offset))
  {
    OR_BUF buf;
    OID oos_oid;
    DB_BIGINT oos_len;
    int rc = NO_ERROR;
    int error;

    OID_SET_NULL (&oos_oid);     /* 4-1 의 er_set 인자 안전성 보장 */

    buf.ptr = raw->data;
    buf.endptr = recdes->data + recdes->length;

    /* 4-1) 인라인 페이로드 버퍼 부족 - oos_oid 는 NULL OID */
    if (buf.endptr - buf.ptr < OR_OID_SIZE + OR_BIGINT_SIZE)
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD, 3,
                OID_AS_ARGS (&oos_oid));
        raw->data = NULL;
        *is_oos = false;          /* allocator 미접촉 */
        return ER_HEAP_BAD_RELOCATION_RECORD;
      }

    or_get_oid (&buf, &oos_oid);
    oos_len = or_get_bigint (&buf, &rc);

    /* 4-2) bigint 읽기 실패 또는 OID null */
    if (rc != NO_ERROR || OID_ISNULL (&oos_oid))
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD, 3,
                OID_AS_ARGS (&oos_oid));
        raw->data = NULL;
        *is_oos = false;          /* allocator 미접촉 */
        return ER_HEAP_BAD_RELOCATION_RECORD;
      }

    /* 4-3) 인라인 길이 범위 위반 */
    if (oos_len <= 0 || oos_len > (DB_BIGINT) INT_MAX)
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD, 3,
                OID_AS_ARGS (&oos_oid));
        raw->data = NULL;
        *is_oos = false;          /* allocator 미접촉 */
        return ER_HEAP_BAD_RELOCATION_RECORD;
      }

    THREAD_ENTRY *thread_p = thread_get_thread_entry_info ();
    assert (thread_p);

    /* 4-4) recdes alloc 실패 - callee 는 er_set 하지 않음 */
    if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
      {
        er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, (size_t) oos_len);
        raw->data = NULL;
        *is_oos = false;          /* alloc 자체가 실패 -> allocator 산출물 없음 */
        return ER_OUT_OF_VIRTUAL_MEMORY;
      }

    /* 4-5) oos_read 실패 - callee 가 er_set 했음.
     *      이 시점 raw->data 는 4-4 가 성공시킨 살아있는 할당이므로 free 후 NULL 화. */
    error = oos_read (thread_p, oos_oid, *raw);
    if (error != NO_ERROR)
      {
        ASSERT_ERROR ();          /* callee-set 검증, 중복 er_set 금지 */
        recdes_free_data_area (raw);
        raw->data = NULL;
        *is_oos = true;           /* 성공 경로와 동일 신호: 호출자 cleanup 호출은 NULL-tolerant 로 no-op */
        return error;
      }

    *is_oos = true;
    return NO_ERROR;
  }
```

### 5. 호출자 변경

`heap_attrvalue_read` (`heap_file.c:10789-10848`):

```c
else
  {
    error = heap_attrvalue_point_variable (recdes, attr_info, attrepr, &raw, &is_oos);
    if (error != NO_ERROR)
      {
        /* point_variable 이 이미 er_set 또는 callee-set 을 마쳤으므로
         * 호출자 측 ASSERT_ERROR () 는 의도적으로 생략 (방어 중복 회피).
         * 계약: is_oos == true 인 경우만 raw 정리 (4-5 경로). 그 외 (4-1~4-4,
         *       default) 는 allocator 미접촉이므로 cleanup 불필요. */
        if (is_oos)
          {
            recdes_free_data_area (&raw);
          }
        return error;
      }
  }
```

`heap_midxkey_get_value` (`heap_file.c:10858-10928`) 도 동일 패턴. 함수 진입부에서 이미 `db_make_null (value);` 를 호출하므로 (`10867`) 에러 분기에서 별도 `db_make_null (value)` 추가는 불필요.

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

`heap_midxkey_get_value` 의 반환 타입은 이미 `int` 이므로 시그니처 변경 없음.

### 6. 호출 체인 그림

```text
heap_attrinfo_read_dbvalues / heap_get_indexvalue_of_attribute / ...
   |
   v
heap_attrvalue_read (int)         ----  변경: point_variable 반환값 받기
   |
   v
heap_attrvalue_point_variable (int)  ----  void -> int
   |
   +-- offset_size switch default       4-default) ER_GENERIC_ERROR early-return (indeterminate read 제거)
   +-- or_get_oid                       corruption 시 OID null -> 4-2)
   +-- or_get_bigint                    rc != NO_ERROR -> 4-2)
   +-- recdes_allocate_data_area        NULL 반환 시 4-4) 명시적 er_set
   +-- oos_read                         callee-set 에러 그대로 전파 (4-5)
```

---

## Acceptance Criteria

- [ ] `heap_attrvalue_point_variable` 의 반환 타입이 `int` 로 변경되고 forward 선언 (`heap_file.c:701-703`) 과 정의 (`10602-10604`) 모두 갱신
- [ ] `OR_VAR_IS_NULL` early-return 경로가 `*is_oos = false; return NO_ERROR;` 를 명시적으로 수행 (호출자 pre-init 의존 제거)
- [ ] OOS 가 아닌 분기 (BLOB/CLOB/SET 등) 도 함수 끝에서 `*is_oos = false;` 후 `return NO_ERROR;` 반환
- [ ] `offset_size` switch 의 `default:` 케이스가 `er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0)` + `*is_oos = false;` + `return ER_GENERIC_ERROR;` 로 처리되어, 미초기화 `offset` 으로 다음 라인의 `OR_IS_OOS (offset)` 검사에 진입하지 않음
- [ ] OOS 분기 진입 직후 (블록 첫 줄) `OID_SET_NULL (&oos_oid);` 가 위치하여, 4-1 단계에서 `OID_AS_ARGS (&oos_oid)` 호출이 미초기화 메모리를 읽지 않음
- [ ] OOS 분기의 4 종 실패 모드 모두 `er_set` + 에러 코드 반환:
  - 인라인 페이로드 버퍼 부족 → `ER_HEAP_BAD_RELOCATION_RECORD` (`OID_AS_ARGS (&oos_oid)`), `*is_oos = false`
  - bigint 읽기 실패 또는 OID null (`rc != NO_ERROR || OID_ISNULL (&oos_oid)` 단일 가드 그대로) → `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`
  - 인라인 길이가 (0, INT_MAX] 범위 밖 → `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`
  - `recdes_allocate_data_area` 실패 → `ER_OUT_OF_VIRTUAL_MEMORY` (인자: `(size_t) oos_len`, `%1$zu` 포맷), `*is_oos = false`
  - `oos_read` 실패 → callee 가 set 한 에러를 그대로 전파, 중복 `er_set` 금지 (`ASSERT_ERROR ()` 만), `recdes_free_data_area (raw)` + `raw->data = NULL` 후 `*is_oos = true` (호출자 cleanup 호출이 no-op 가 되도록 NULL-tolerant 의존)
- [ ] 모든 에러 반환 경로에서 `raw->data == NULL`, 살아있는 할당이 남지 않음
- [ ] `heap_attrvalue_read` (`10789-10848`) / `heap_midxkey_get_value` (`10858-10928`) 가 `point_variable` 의 반환값을 받아 에러 시 `if (is_oos) recdes_free_data_area (&raw);` 후 상위로 전파
- [ ] **단위 테스트 (GoogleTest, `unit_tests/oos/test_oos.cpp` 의 `TEST(...)` / `EXPECT_*` / `ASSERT_*` 매크로 사용)**: `heap_attrvalue_point_variable` 가 `static` 이므로 `unit_tests/oos/test_oos_common.hpp` 에 `bridge_heap_attrvalue_point_variable` 헬퍼를 추가하여 호출 (기존 `bridge_oos_*` 헬퍼 패턴, `test_oos.cpp:36-39` 참고). 테스트는 합성 `RECDES` 를 빌드하고 그 가변 영역 헤더 (`OR_VAR_BIT_OOS = 0x1`, `object_representation.h:441`) 를 set 한 뒤 인라인 16B 영역을 시나리오별로 채워 호출:
  - 모드 4-1: 인라인 페이로드 영역 길이를 `OR_OID_SIZE + OR_BIGINT_SIZE` 미만으로 잘라 합성 → `EXPECT_EQ (er_errid (), ER_HEAP_BAD_RELOCATION_RECORD)` + `EXPECT_FALSE (is_oos)`
  - 모드 4-2: 인라인 OID 8B 를 NULL OID 로 채움 → 동일 검증
  - 모드 4-3: 인라인 length 8B 를 `0`, `-1`, `(DB_BIGINT) INT_MAX + 1` 의 세 값으로 각각 채움 → 동일 검증
  - 모드 4-5: bridge 가 mockable seam 을 제공하지 않으므로 본 A/C 에서는 다루지 않는다 — 4-5 는 `oos_read` 자체의 callee-set 동작이며 기존 `oos_read` 단위 테스트들이 다룬다 (Out of scope 참조)
- [ ] **회귀**: 정상 OOS round-trip 동작 변화 없음 — 기존 `unit_tests/oos/test_oos.cpp`, `test_oos_delete.cpp`, `test_oos_bestspace.cpp`, `test_oos_remove_file.cpp` 가 변경 없이 통과
- [ ] **CI**: `just build-test` (debug 빌드 + `unit_tests/oos`) 통과; CircleCI `test_sql`, `test_medium` 잡 통과
- [ ] 모드 4-4 (alloc 실패) 와 모드 4-default (recdes 헤더 corruption) 의 corruption-injection 테스트는 본 티켓에서 다루지 않음 — Out of scope 참조

## Definition of done

- [ ] 위 A/C 충족
- [ ] PR 리뷰 / merge
- [ ] PR #7097 리뷰 코멘트 후속 약속 이행:
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3200880248 (hornetmj 요청: `assert_release (false)` 를 release 빌드에서 정상 SQL 에러로 변환할 별도 티켓 발행) — 본 티켓이 그 후속 티켓임을 PR 본문에 명시
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449095 (vimkim 약속: TODO 블록 제거하고 후속 티켓에서 int 시그니처로 처리) — 본 티켓에서 시그니처를 int 로 전환
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449462 (vimkim 약속: `OID_AS_ARGS` 패턴은 후속 티켓에서 적용) — 본 티켓의 4-1~4-3 경로에서 `OID_AS_ARGS (&oos_oid)` 를 메시지 인자로 사용
- [ ] CBRD-26741 가 merge 된 후 본 티켓의 라인 번호를 마지막으로 한 번 재확인 (CBRD-26741 가 본 티켓 직전 변경분이라 라인 번호가 한 번 더 흔들릴 가능성 있음)

---

## Out of scope

본 티켓은 *시그니처 / 에러 전파 / `default:` indeterminate read 제거* 작업만 다룬다. 다음 항목은 별도 티켓:

- 스택 버퍼 fast-path (PR #7097 review comment 3201451481, `HEAP_CACHE_ATTRINFO` scratch buffer 도입)
- PEEK-mode `oos_read` 와 dbvalue zero-copy. `heap_attrvalue_read` 의 TODO 주석 ("TODO: heap_attrvalue_transform_to_dbvalue() used to PEEK &raw" 로 시작하는 블록, 작성 시점 기준 `heap_file.c:10835` 부근) 은 본 티켓에서 손대지 않는다 — line 번호는 merge 시점에 흔들릴 수 있어 content 로 식별한다.
- OOS 전용 corruption 에러 코드 신규 정의 (CBRD-26637 후속). 정의될 경우 본 티켓에서 사용한 `ER_HEAP_BAD_RELOCATION_RECORD` 호출처들을 일괄 교체하며, 그때 `CLAUDE.md` 의 6-step 워크플로우 (`error_code.h`, `dbi_compat.h`, `cubrid.msg` en/ko, `ER_LAST_ERROR`, CCI `base_error_code.h`) 를 적용한다.
- `offset_size` switch 의 로컬 `offset` 변수를 함수에서 완전히 제거하는 (즉 OOS 분기에서 `OR_IS_OOS` 가 `offset` 을 참조하지 않도록 매크로 측 변경) 후속 정리 — 본 티켓은 `default:` 경로의 indeterminate read 만 차단하고 변수 자체는 그대로 둔다.
- 모드 4-4 (alloc 실패) 에 대한 corruption-injection 테스트 추가 — alloc 실패는 일반 OOM 시나리오 일부이며 기존 OOM 테스트 인프라가 다루므로 본 티켓에서는 제외한다.
- 모드 4-5 (`oos_read` 실패) 의 corruption-injection 테스트 — 본 티켓의 bridge 가 `oos_read` mock seam 을 제공하지 않고, 또한 "존재하지 않는 OOS chunk OID" 를 인라인 페이로드에 심어 end-to-end 로 유도하는 방식은 callee-set 에러 코드 (예: `ER_PB_BAD_PAGEID` vs. 다른 코드) 가 환경 의존적이라 안정적인 expected value 단정이 어렵다. 4-5 의 callee-set 동작은 기존 `oos_read` 단위 테스트들이 책임지며, 본 티켓은 "호출 체인이 callee-set 에러 코드를 그대로 전파한다" 는 사실만 코드 리뷰로 검증한다.
- 모드 4-default (recdes 헤더 `offset_size` corruption) 의 유닛 테스트 — 합성 `RECDES` 헤더의 `offset_size` 비트필드를 비합법 값으로 직접 조작하는 인프라가 현재 `unit_tests/oos/` 에 없어 본 티켓에서는 제외한다 (OOS 컨텍스트보다는 heap recdes 헤더 검증 컨텍스트에 더 가까운 작업).
- 4-2 진단 메시지에 부모 OID / `recdes->length` / `attrepr->location` 컨텍스트를 포함시키는 작업 — 함수 시그니처 변경 또는 `oos_error` 보조 로깅 추가가 필요하며 본 티켓의 "에러 전파 채널 확보" 범위를 벗어남.

---

## 참고 코드

소스 라인 번호는 본 티켓 작성 시점 (`oos-refactor-oos-read-with-length` 브랜치) 기준. 본 티켓 작성 시점에서 CBRD-26741 의 리팩터는 이미 적용된 상태이며 위 line numbers 는 그 상태 기준이지만, PR 오픈 직전 마지막 한 차례 재확인이 필요하다.

- `src/storage/heap_file.c:701-703` — `heap_attrvalue_point_variable` forward 선언
- `src/storage/heap_file.c:705` — `heap_attrvalue_read` forward 선언
- `src/storage/heap_file.c:707-708` — `heap_midxkey_get_value` forward 선언
- `src/storage/heap_file.c:10592-10718` — `heap_attrvalue_point_variable` 정의 (header comment 포함). OOS 분기는 `10639-10702`
- `src/storage/heap_file.c:10630-10639` — `offset_size` switch + 다음 라인의 `OR_IS_OOS (offset)` (indeterminate read 지점)
- `src/storage/heap_file.c:10780-10848` — `heap_attrvalue_read` (호출자 1)
- `src/storage/heap_file.c:10851-10928` — `heap_midxkey_get_value` (호출자 2)
- `src/storage/oos_file.cpp:1365` — `oos_read (THREAD_ENTRY *, const OID &, RECDES &)` (callee, 이미 int 반환, callee-set 에러)
- `src/storage/storage_common.c:309-324` — `recdes_allocate_data_area` (NULL 시 `ER_FAILED` 만 반환, 자체 `er_set` 없음)
- `src/storage/storage_common.c:327-329` — `recdes_free_data_area` → `db_private_free_and_init (NULL, rec->data)`
- `src/base/memory_alloc.h:124-130` — NDEBUG 빌드의 `db_private_free_and_init` 매크로 (NULL 가드 포함)
- `src/base/memory_alloc.h:148-152` — DEBUG 빌드의 `db_private_free_and_init` 매크로 (매크로 자체에는 NULL 가드 없음)
- `src/base/memory_alloc.c` — `db_private_free_debug` / `db_private_free_release` 본문 첫 줄 `if (ptr == NULL) { return; }` (양쪽 빌드에서 NULL-tolerant 보장)
- `src/base/error_code.h:52` — `ER_GENERIC_ERROR` (-2)
- `src/base/error_code.h:53` — `ER_OUT_OF_VIRTUAL_MEMORY` (-3)
- `src/base/error_code.h:107` — `ER_HEAP_BAD_RELOCATION_RECORD` (-50)
- `src/base/error_manager.h:189-191` — NDEBUG 빌드의 `assert_release (e)` 정의: `er_set (ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, 1, ...)` (abort 아님)
- `src/base/error_manager.h:258-273` — `ASSERT_ERROR ()`, `ASSERT_ERROR_AND_SET (error_code)`
- `src/base/system_parameter.c` — `call_stack_dump_error_codes[]` 배열에 `ER_HEAP_BAD_RELOCATION_RECORD` 등록 (alarm/dump 채널)
- `src/base/object_representation.h:441` — `OR_VAR_BIT_OOS = 0x1`
- `src/base/object_representation.h:451` — `OR_IS_OOS (length)` 매크로
- `src/storage/oid.h:42` — `OID_AS_ARGS (oidp)` → `(oidp)->volid, (oidp)->pageid, (oidp)->slotid`
- `src/storage/oid.h:88` — `OID_SET_NULL (oidp)`
- `msg/en_US.utf8/cubrid.msg` ID 3 — `"Out of virtual memory: unable to allocate %1$zu memory bytes."` (size_t 인자)
- `msg/en_US.utf8/cubrid.msg` ID 50 — `"Internal error: relocation record of object %1$d|%2$d|%3$d may be corrupted."` (volid|pageid|slotid 인자)
- `unit_tests/oos/test_oos.cpp:19` — `#include "gtest/gtest.h"` (GoogleTest)
- `unit_tests/oos/test_oos.cpp:33-39` — 기존 `bridge_oos_*` 헬퍼 패턴 (신규 `bridge_heap_attrvalue_point_variable` 가 따를 모델)
- `unit_tests/oos/test_oos_common.hpp` — bridge 헬퍼 추가 위치 (현재 `oos_read_with_alloc`, `from_string_into_recdes`, `auto_freed_recdes_ptr` 등 유사 헬퍼 보유)
- `src/storage/oos_log.hpp:166-168` — `oos_error` 매크로 (release 빌드에서도 활성, 4-2 진단 보강 후속 티켓 시 활용 가능)

## Remarks

- 부모 에픽: CBRD-26583 (OOS M2)
- 본 티켓 작성 시점 기준 CBRD-26741 (`oos_read` caller-preallocated 리팩터링) 의 리팩터는 이미 브랜치 `oos-refactor-oos-read-with-length` 에 적용되어 있으며, 본 티켓의 line numbers 는 그 상태 기준이다. CBRD-26741 의 PR 이 main 에 merge 되는 시점에 line 이 한 번 더 흔들릴 수 있으므로, 본 티켓 PR 오픈 직전 line 번호 재확인 필요.
- 관련 티켓:
  - CBRD-26637 — error handling refactor. OOS 전용 에러 코드 미정의로 `ER_GENERIC_ERROR` 를 사용한 선례. 본 티켓은 `ER_HEAP_BAD_RELOCATION_RECORD` 재사용으로 한 단계 진전시키되, OOS 전용 코드 신규 정의는 후속 티켓으로 미룸.
