# [OOS] [Refactoring] heap_attrvalue_point_variable 시그니처를 int 반환으로 변경하여 OOS read 실패 전파

> **TL;DR**
>
> 현재는 디스크에 저장된 큰 컬럼 값이 손상되어도 에러가 SQL 응답에 실려 나가지 않고 NULL 데이터로 흘러간다. 이 티켓은 해당 경로의 함수가 에러 코드를 반환하도록 시그니처를 `void` -> `int` 로 바꾼다.

## Summary

- **무엇을**: `heap_attrvalue_point_variable` 시그니처 `void` -> `int`. 호출자 2곳 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 도 에러 전파.
- **부수 수정**: `default:` switch 직후 라인의 미초기화 `offset` 읽기를 early-return 으로 차단.
- **신규 에러 코드 없음**: 기존 `ER_HEAP_BAD_RELOCATION_RECORD` / `ER_OUT_OF_VIRTUAL_MEMORY` / `ER_GENERIC_ERROR` 만 사용.

---

## Description

### 용어 (한 번만 정의)

| 용어 | 한 줄 설명 |
|---|---|
| **OOS** | Out-of-row Overflow Storage. heap recdes 가 너무 크면 본문을 외부 페이지로 분리 저장하는 메커니즘. |
| **인라인 페이로드** | heap recdes 안에 남는 16B 영역. `OID 8B + length(BIGINT) 8B`. OOS 본문이 어디 있는지 가리키는 forwarder. |
| **forwarder** | 본문이 아니라 본문 위치만 들고 있는 16바이트짜리 stub. |
| **`recdes`** | heap record descriptor. 데이터 포인터와 길이를 들고 있는 구조체 (`data`, `length`, `area_size`, `type`). |
| **`recdes_allocate_data_area`** | `recdes` 의 `data` 영역에 raw 버퍼를 `db_private_alloc` 하는 헬퍼. NULL 시 `ER_FAILED` 만 반환하고 자체 `er_set` 안 한다 (`storage_common.c:310-324`). |
| **`attrepr`** | `OR_ATTRIBUTE`. 컬럼 메타데이터 (`location`, `domain`, `type` 등) 를 들고 있는 구조체. |
| **`OR_VAR_IS_NULL`** | 매크로. 가변 컬럼이 SQL NULL 인지 검사. |
| **`assert_release(e)`** | NDEBUG 빌드에서 abort 안 하고 `er_set(ER_NOTIFICATION_SEVERITY, ..., ER_FAILED_ASSERTION, ...)` 만 남기는 약한 assert (`error_manager.h:189-191`). |
| **`*is_oos`** | OOS 분기에서 raw 버퍼 할당이 일어나 호출자가 cleanup 해야 하는지를 알리는 출력 플래그 (true 면 호출자가 `recdes_free_data_area` 호출). |
| **NULL-tolerance** | `db_private_free` 가 NULL 포인터에도 안전하게 동작하는 성질. |
| **indeterminate value** | 미초기화 자동 변수에 들어있는 값. 무엇이 들어있을지 알 수 없어 분기 선택이 비결정적이 된다. |
| **callee-set** | 호출된 함수가 이미 `er_set` 으로 에러 코드를 설정한 상태. 호출자는 중복 `er_set` 금지. |
| **alarm/dump array** | `system_parameter.c` 의 `call_stack_dump_error_codes[]`. 에러 코드가 등록되어 있으면 발생 시 cub_server 가 자동으로 콜스택을 에러 로그에 덤프한다. |

### 케이스 번호 (문서 전체 통일)

OOS 분기에서 발생할 수 있는 실패 모드를 다음 번호로 부른다.

| 케이스 | 트리거 시점 | 무엇이 잘못 |
|---|---|---|
| **Case 1** | `or_get_oid` 직후 (인라인 헤더 검증) | 인라인 페이로드 영역이 16B 미만 (버퍼 부족) |
| **Case 2** | `or_get_oid` / `or_get_bigint` 결과 검증 | bigint 읽기 실패 또는 OID 가 NULL |
| **Case 3** | length 범위 검증 | 인라인 length 가 (0, INT_MAX] 범위 밖 |
| **Case 4** | alloc 단계 | `recdes_allocate_data_area` 실패 (OOM) |
| **Case 5** | `oos_read` 단계 | `oos_read` 자체 실패 |
| **Case D** | `offset_size` switch default | recdes 헤더의 `offset_size` 가 비합법 값 |

Case 5 는 callee-set 의 대표 사례다. `oos_read` 가 페이지를 못 찾으면 자체적으로 `er_set(..., ER_PB_BAD_PAGEID, ...)` 까지 마치고 음수 코드를 반환 — 호출자는 그 값을 그대로 위로 올린다.

### 왜 (한 번만 설명)

CBRD-26741 (PR #7097) squash 단계에서 corrupt-OID 처리가 비대칭하게 정리되었다. 일부 경로는 `er_set` + `assert_release_error`, 일부는 `assert_release(false)` 단독.

NDEBUG 빌드에서 `assert_release(e)` 는 abort 가 아니라 `er_set(ER_NOTIFICATION_SEVERITY, ARG_FILE_LINE, ER_FAILED_ASSERTION, ...)` 만 호출한다 (`error_manager.h:189-191`). 결과:

- 사용자는 SQL ERROR 가 아니라 NOTIFICATION 로그만 본다.
- 함수는 `*is_oos = true; return;` 로 빠져나간다.
- 호출자는 NULL 데이터를 받지만 그 사실을 모른다.

함수가 `void` 라 어차피 호출자에게 알릴 채널 자체가 없다.

### 지금 상태 (현재 코드)

OOS 분기 (`src/storage/heap_file.c:10656-10700`) 의 5 가지 실패 처리는 이렇다.

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

함수 진입부 (`heap_file.c:10630-10634`) 의 offset switch 는 더 미묘하다. `default:` 에서 `assert_release(false); break;` 만 하고 빠지면, 그 다음 라인 `if (OR_IS_OOS (offset))` (`heap_file.c:10639`) 가 미초기화 `offset` 을 읽는다 — Case D.

### 문제점

1. **시그니처가 `void`**. Case 1~3 은 `er_set` 까지는 한다. 그러나 호출자가 "에러 발생 여부" 자체를 받지 못한다. 호출자가 `er_errid()` 를 폴링해야 하는데 현재 그렇게도 안 한다.
2. **Case 4 는 `er_set` 마저 누락**. `recdes_allocate_data_area` 는 NULL 시 `ER_FAILED` 만 반환하고 자체 `er_set` 을 안 한다 (`storage_common.c:310-324`). 따라서 Case 1~3 과 달리 SQL 에러 응답이 아예 발생할 수 없다.
3. **Case D 의 indeterminate read**. `default:` 경로에서 `offset` 변수가 초기화 안 된 상태로 다음 라인에서 읽힌다. 값은 스택 잔재라 사실상 무작위다. 그래서 OOS 분기로 갈지 비-OOS 분기로 갈지가 비결정적이다.

진단 메시지 측면도 문제다. Case 1~3 이 모두 `ER_GENERIC_ERROR` 로 묶여 있어 어떤 corruption 인지 메시지로 구분이 안 되고 (`ER_GENERIC_ERROR` 는 인자 0개), 손상된 OID 값을 메시지에 실을 수도 없다.

### 바꾸려는 것

| 항목 | 변경 |
|---|---|
| 시그니처 | `static void` -> `static int` |
| Case 1, 2, 3 | `er_set(ER_HEAP_BAD_RELOCATION_RECORD, OID_AS_ARGS)` + return code |
| Case 4 | 명시적 `er_set(ER_OUT_OF_VIRTUAL_MEMORY, (size_t) oos_len)` + return code |
| Case 5 | callee-set 그대로 전파 (중복 `er_set` 금지, `ASSERT_ERROR()` 만) |
| Case D | early-return `er_set(ER_GENERIC_ERROR)` -> indeterminate read 차단 |
| 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) | 반환값 받아 cleanup + 상위 전파 |

### `*is_oos` 계약 (호출자가 알아야 할 것)

`*is_oos` 의 의미를 한 줄로: **"`recdes_allocate_data_area` 를 건드려서 호출자가 cleanup 해야 할 데이터가 만들어졌는가?"**

| 경로 | `*is_oos` | 호출자 cleanup |
|---|---|---|
| 성공 (OOS 분기) | `true` | 사용 후 `recdes_free_data_area(&raw)` |
| `OR_VAR_IS_NULL` early-return | `false` | 불필요 |
| Case D (default switch) | `false` | 불필요 |
| Case 1, 2, 3 (allocator 미접촉) | `false` | 불필요 |
| Case 4 (alloc 자체가 실패) | `false` | 불필요 |
| Case 5 (`oos_read` 실패) | `true` | 함수 내부에서 free + NULL 화. 호출자가 한 번 더 free 해도 NULL-tolerant 라 no-op. |

Case 5 의 `*is_oos = true` 는 성공 경로와 신호를 통일하기 위한 의도다. 호출자가 `if (is_oos) recdes_free_data_area(&raw);` 패턴을 그대로 써도 안전하다.

### NULL-안전성 근거

Case 5 에서 호출자가 `recdes_free_data_area(&raw)` 를 부를 때 `raw->data == NULL` 이다.

양쪽 빌드 모두 안전하다. 단, NDEBUG 와 DEBUG 의 NULL 가드 위치가 정반대라 표로 정리한다.

| 빌드 | 매크로 | 가드 |
|---|---|---|
| NDEBUG | `db_private_free_and_init` (`memory_alloc.h` 의 `#if defined(NDEBUG)` 블록) | 매크로 자체에 `if ((ptr)) ...` 가드 있음 |
| DEBUG | `db_private_free_and_init` (`memory_alloc.h` 의 `#else /* NDEBUG */` 블록) | 매크로 가드는 없으나 `db_private_free_*` 본문 첫 줄 `if (ptr == NULL) { return; }` 가드 |

따라서 `recdes_free_data_area` 는 양쪽에서 NULL-tolerant.

---

## Specification Changes

사용자/매뉴얼 관점의 스펙 변화 없음. 내부 API 시그니처만 변경.

### Case -> Error Code 매핑

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

릴리즈 빌드 동작 변화: OOS corruption 시 종전에는 NOTIFICATION 만 남기고 NULL 데이터를 흘려보내거나 비결정적 분기 선택을 하던 경로가, 이제 정상 SQL 에러 응답이 된다.

### 에러 코드 선택 근거

신규 에러 코드 도입 없음. 따라서 `CLAUDE.md` 의 6-step 워크플로우 (`error_code.h`, `dbi_compat.h`, `cubrid.msg` en/ko, `ER_LAST_ERROR`, CCI `base_error_code.h`) 는 적용되지 않는다.

#### Case 1 / Case 2 / Case 3 -> `ER_HEAP_BAD_RELOCATION_RECORD` (-50)

##### 메시지

- `cubrid.msg` ID 50: `"Internal error: relocation record of object %1$d|%2$d|%3$d may be corrupted."`
- 인자: `OID_AS_ARGS (&oos_oid)` -> `volid|pageid|slotid` (`oid.h:42`).

##### 의미 매핑 근거

"relocation record" 는 본래 heap forwarder (REC_RELOCATION) 를 가리킨다. OOS 인라인 페이로드도 *외부 페이지를 가리키는 forwarder* 라는 점에서 같은 카테고리. 메시지 본문 "object ... may be corrupted" 는 일반적이라 의미 충돌 없음.

##### 운영자 알람

- Fact: `ER_HEAP_BAD_RELOCATION_RECORD` 는 `system_parameter.c:5618` 의 `call_stack_dump_error_codes[]` 에 등록되어 있다.
- Effect: SQL 에러와 동시에 cub_server 가 콜스택을 에러 로그에 자동 덤프한다.
- Ops 결론: 별도 모니터링 룰 불필요.

##### 진단 한계 (Case 2)

- `OID_ISNULL(&oos_oid)` 가 트리거되면 `OID_AS_ARGS(&oos_oid)` 는 `-1|-1|-1` 을 출력한다. 운영자가 어떤 record 의 어떤 attribute 인지 메시지만으로 식별할 수 없다.
- 이 한계는 본 티켓에서 수용한다. 부모 OID 를 메시지에 실으려면 함수 시그니처 변경 또는 `oos_error` 보조 로깅이 필요하고, 둘 다 본 티켓 범위 밖이다.

#### Case 4 -> `ER_OUT_OF_VIRTUAL_MEMORY` (-3)

- 메시지 (`cubrid.msg` ID 3): `"Out of virtual memory: unable to allocate %1$zu memory bytes."`
- 인자 arity = 1. 포맷 `%1$zu` 는 `size_t` 를 요구하므로 인자는 `(size_t) oos_len` 으로 캐스팅.
- `recdes_allocate_data_area` 는 자체 `er_set` 없이 `ER_FAILED` 만 반환 (`storage_common.c:310-324`) 하므로 호출 측에서 명시적 `er_set` 필요. 메모리 부족이라는 근본 원인을 정확히 표현.

#### Case 5 -> callee-set 그대로 전파

- `oos_read` (`oos_file.cpp:1365`) 는 자체 `er_set` 함.
- 호출 측은 중복 `er_set` 금지. `ASSERT_ERROR()` 로 callee-set 검증만.

#### Case D -> `ER_GENERIC_ERROR` (-2)

- 인자 arity = 0.
- 이 시점은 OOS 인라인 페이로드를 아직 안 읽은 상태라 OID 컨텍스트 없음. `ER_HEAP_BAD_RELOCATION_RECORD` 에 `0|0|0` 을 채우는 건 의미적으로 부정확 -> 사용 안 함.
- recdes 헤더 자체의 corruption 은 일반적인 internal-state inconsistency 이므로 `ER_GENERIC_ERROR` 가 적절.

---

## Implementation

### Step 1. 시그니처 변경

forward 선언 (`heap_file.c:701-703`) 과 정의 (`10602-10604`) 모두 `static void` -> `static int`.

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

`OR_VAR_IS_NULL` early-return (`heap_file.c:10609-10613`) 에서 `*is_oos` 를 명시적으로 설정한다. 호출자가 `is_oos` 를 pre-init 하지 않아도 함수 내부에서 계약을 보장하기 위함이다.

```c
if (OR_VAR_IS_NULL (recdes->data, attrepr->location))
  {
    *is_oos = false;             /* 비-OOS 정상 경로 */
    return NO_ERROR;
  }
```

함수 끝의 비-OOS 분기 (BLOB/CLOB/SET 등 길이 결정, `heap_file.c:10703-10717`) 도 동일.

```c
  /* ... non-OOS branch: TP_DOMAIN_TYPE switch on attrepr->domain ... */
  *is_oos = false;
  return NO_ERROR;
}   /* end of heap_attrvalue_point_variable */
```

### Step 3. Case D (`default:` switch) early-return

현재 `default: assert_release(false); break;` 후 다음 라인 `if (OR_IS_OOS (offset))` 가 미초기화 `offset` 을 읽는다.

문제점 #3 (indeterminate read) 을 차단한다. NDEBUG 빌드에서 `assert_release(false)` 가 abort 하지 않으므로 사용자가 그대로 노출된다.

`default:` 에서 즉시 에러를 반환해 그 라인 도달 자체를 차단한다.

```c
default:
  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
  *is_oos = false;               /* OOS 분기 진입 전, allocator 미접촉 */
  return ER_GENERIC_ERROR;
```

로컬 `offset` 변수 자체는 정상 OOS 분기에서 `OR_IS_OOS(offset)` 인자로 쓰이므로 dead-code 가 아니다. 본 변경은 default 경로의 미초기화 흐름만 차단한다.

### Step 4. OOS 분기 5 종 실패 모드 통합

OOS 분기 진입 직후 `OID_SET_NULL(&oos_oid)` 를 둔다. Case 1 단계에서 `OID_AS_ARGS(&oos_oid)` 가 미초기화 메모리를 읽지 않게 하기 위함이다.

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

`heap_attrvalue_point_variable` 가 이미 내부에서 (Case 5 에 한해) `ASSERT_ERROR()` 로 callee-set 검증을 마쳤으므로 그 위 계층에서는 한 번 더 부르지 않는다.

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
   +-- offset_size switch default       Case D : ER_GENERIC_ERROR early-return (indeterminate read 차단)
   +-- or_get_oid                       OID null   -> Case 2
   +-- or_get_bigint                    rc != NO_ERROR -> Case 2
   +-- recdes_allocate_data_area        NULL 반환  -> Case 4 (명시적 er_set)
   +-- oos_read                         실패       -> Case 5 (callee-set 전파)
```

---

## Acceptance Criteria

### 시그니처

- [ ] `heap_attrvalue_point_variable` 의 반환 타입이 `int`. forward 선언 (`heap_file.c:701-703`) 과 정의 (`10602-10604`) 둘 다 갱신.

### 정상 경로

- [ ] `OR_VAR_IS_NULL` early-return: `*is_oos = false; return NO_ERROR;` 명시.
- [ ] OOS 가 아닌 분기 (BLOB/CLOB/SET 등) 함수 끝: `*is_oos = false; return NO_ERROR;`.

### Case D (default switch)

- [ ] `default:` 가 `er_set(ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0)` + `*is_oos = false;` + `return ER_GENERIC_ERROR;`.
- [ ] 결과적으로 미초기화 `offset` 으로 다음 라인 `OR_IS_OOS(offset)` 도달 불가.

### OOS 분기 진입 직후

- [ ] OOS 분기 진입 직후 (블록 첫 줄) `OID_SET_NULL(&oos_oid);` 위치. Case 1 의 `OID_AS_ARGS(&oos_oid)` 가 미초기화 메모리를 읽지 않음.

### Case 1~5 처리

- [ ] **Case 1** (인라인 페이로드 버퍼 부족 — 가드: `buf.endptr - buf.ptr < OR_OID_SIZE + OR_BIGINT_SIZE`) -> `ER_HEAP_BAD_RELOCATION_RECORD` (`OID_AS_ARGS(&oos_oid)`), `*is_oos = false`.
- [ ] **Case 2** (bigint 읽기 실패 또는 OID NULL — 가드: `rc != NO_ERROR || OID_ISNULL(&oos_oid)`) -> `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`.
- [ ] **Case 3** (인라인 길이가 (0, INT_MAX] 범위 밖 — 가드: `oos_len <= 0 || oos_len > (DB_BIGINT) INT_MAX`) -> `ER_HEAP_BAD_RELOCATION_RECORD`, `*is_oos = false`.
- [ ] **Case 4** (`recdes_allocate_data_area` 실패) -> `ER_OUT_OF_VIRTUAL_MEMORY` (인자 `(size_t) oos_len`, `%1$zu` 포맷), `*is_oos = false`.
- [ ] **Case 5** (`oos_read` 실패) -> callee-set 그대로 전파, 중복 `er_set` 금지 (`ASSERT_ERROR()` 만), `recdes_free_data_area(raw)` + `raw->data = NULL` + `*is_oos = true`.
- [ ] 모든 에러 반환 경로에서 `raw->data == NULL`, 살아있는 할당 없음.

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

### 본 티켓에서 다루지 않는 테스트

- [ ] Case 4 / Case D / Case 5 의 corruption-injection 테스트는 본 티켓 out of scope (위 커버리지 표 참고).

---

## Definition of done

- [ ] 위 A/C 충족.
- [ ] PR 리뷰 / merge.
- [ ] PR #7097 리뷰 코멘트 후속 약속 이행:
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3200880248 (hornetmj 요청: `assert_release(false)` 를 release 빌드에서 SQL 에러로 변환할 별도 티켓) — 본 티켓이 그 후속 티켓임을 PR 본문에 명시.
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449095 (vimkim 약속: TODO 블록 제거하고 후속 티켓에서 int 시그니처로 처리) — 본 티켓에서 시그니처 전환.
  - https://github.com/CUBRID/cubrid/pull/7097#discussion_r3201449462 (vimkim 약속: `OID_AS_ARGS` 패턴은 후속 티켓) — Case 1~3 에서 `OID_AS_ARGS(&oos_oid)` 사용.
- [ ] CBRD-26741 merge 후 본 티켓의 라인 번호를 마지막으로 한 번 재확인.

---

## Out of scope

본 티켓은 *시그니처 / 에러 전파 / `default:` indeterminate read 제거* 만 다룬다. 다음은 별도 티켓.

- 스택 버퍼 fast-path (PR #7097 review comment 3201451481, `HEAP_CACHE_ATTRINFO` scratch buffer 도입).
- PEEK-mode `oos_read` 와 dbvalue zero-copy. `heap_attrvalue_read` 의 TODO 주석 ("TODO: heap_attrvalue_transform_to_dbvalue() used to PEEK &raw" 로 시작하는 블록, 작성 시점 `heap_file.c:10835` 부근) 은 본 티켓 손대지 않음.
- OOS 전용 corruption 에러 코드 신규 정의 (CBRD-26637 후속). 정의되면 `ER_HEAP_BAD_RELOCATION_RECORD` 호출처 일괄 교체. 그때 `CLAUDE.md` 의 6-step 워크플로우 (`error_code.h`, `dbi_compat.h`, `cubrid.msg` en/ko, `ER_LAST_ERROR`, CCI `base_error_code.h`) 적용.
- 로컬 `offset` 변수를 함수에서 완전히 제거하는 후속 정리 (OOS 분기에서 `OR_IS_OOS` 가 `offset` 참조하지 않도록 매크로 측 변경). 본 티켓은 default 경로 indeterminate read 만 차단.
- Case 4 (alloc 실패) corruption-injection 테스트 — 일반 OOM 시나리오 일부이며 기존 OOM 인프라가 다룸.
- Case 5 (`oos_read` 실패) corruption-injection 테스트:
  - (1) bridge 가 `oos_read` mock seam 을 제공하지 않으므로 단위 테스트로는 trigger 불가.
  - (2) end-to-end 로 잘못된 OID 를 심는 방식은 callee-set 코드가 페이지 버퍼 상태에 따라 달라져 (`ER_PB_BAD_PAGEID`) expected value 를 단정할 수 없다.
  - Case 5 의 callee-set 동작은 기존 `oos_read` 단위 테스트가 책임. 본 티켓은 "호출 체인이 callee-set 코드를 그대로 전파한다" 만 코드 리뷰로 검증.
- Case D (recdes 헤더 `offset_size` corruption) 유닛 테스트 — 합성 RECDES 헤더의 `offset_size` 비트필드를 비합법 값으로 직접 조작하는 인프라가 현재 `unit_tests/oos/` 에 없음. heap recdes 헤더 corruption 일반 테스트 (별도 티켓) 에서 다룬다.
- Case 2 진단 메시지에 부모 OID / `recdes->length` / `attrepr->location` 추가 — 함수 시그니처 추가 변경 또는 `oos_error` 보조 로깅 필요. 본 티켓의 "에러 전파 채널 확보" 범위 밖.

---

## References

소스 라인 번호는 `oos-refactor-oos-read-with-length` 브랜치 기준.

### `src/storage/heap_file.c`

| 라인 | 무엇 |
|---|---|
| 701-703 | `heap_attrvalue_point_variable` forward 선언 |
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
