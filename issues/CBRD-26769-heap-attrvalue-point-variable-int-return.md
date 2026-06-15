# [OOS] [Refactoring] 인라인 OOS read 실패를 int 반환으로 호출자까지 전파 + OOS 전용 corruption 에러 코드 신설

> **TL;DR**
>
> OOS 인라인 이정표(`[OID | length]` 16B 헤더)가 손상돼도 SQL 에러로 보고되지 않고 NULL 값이 그대로 결과셋에 섞여 나갔다. 이 티켓은 인라인 OOS read 함수를 `void` → `int` 로 바꿔 실패를 호출자까지 전파하고, 손상 전용 에러 코드 `ER_HEAP_OOS_BAD_INLINE_HEADER` (-1375) 를 신설한다.

> **Status**: Implemented — PR [CUBRID/cubrid#7296](https://github.com/CUBRID/cubrid/pull/7296) (base `feat/oos`). 아래 본문은 **실제 구현 결과** 기준으로 갱신됨. 최초 스펙과의 차이는 [구현 중 스펙 변경](#구현-중-스펙-변경) 절 참조.

## Summary

- **변경**: 인라인 OOS read 함수 `heap_attrvalue_read_oos_inline` 와 `heap_attrvalue_point_variable` 의 반환 타입을 `void` → `int` 로 바꾸고, 호출자 `heap_attrvalue_read` / `heap_midxkey_get_value` 두 곳이 에러를 전파한다.
- **신규 에러 코드**: OOS 인라인 헤더 손상 전용 `ER_HEAP_OOS_BAD_INLINE_HEADER` (-1375) 를 신설했다 (최초 스펙은 `ER_HEAP_BAD_RELOCATION_RECORD` 재사용이었으나, 의미 불일치로 전용 코드로 전환).
- **부수 수정**: `default:` 분기에서 즉시 에러를 반환해, 다음 라인의 미초기화 `offset` 참조(Case D, indeterminate read)를 막는다.

---

## Description

### 사전 정보

- 인라인 OOS read 로직은 (최초 스펙 작성 이후 머지된) 별도 헬퍼 `heap_attrvalue_read_oos_inline` 에 들어 있다. `heap_attrvalue_point_variable` 은 `offset_size` switch (Case D) 만 처리하고, OOS 분기는 이 헬퍼에 위임한다.
- `recdes_allocate_data_area` 는 NULL 시 `ER_FAILED` 만 반환하고 자체 `er_set` 을 하지 않는다 (`storage_common.c`). Case 4 에서 호출자 측 `er_set` 이 필요한 근거다.
- `assert_release(false)` 는 NDEBUG 에서 `ER_NOTIFICATION_SEVERITY` 만 남기고 통과한다 (`error_manager.h`). 이 동작이 본 티켓의 발단이다.
- `*oos_owned_buffer` 는 호출자 cleanup 필요 여부 플래그 (최초 스펙의 `*is_oos` 에서 개명). 스택 스크래치 fast-path 가 함께 머지돼, 호출자 cleanup 은 `if (oos_owned_buffer && raw.data != oos_scratch) recdes_free_data_area(&raw)` 형태다.

### 실패 모드

OOS 분기에서 발생할 수 있는 실패 모드를 다음 번호로 부른다.

| 케이스 | 트리거 시점 | 무엇이 잘못 | 위치 |
|---|---|---|---|
| **Case 1** | 인라인 헤더 검증 | 인라인 페이로드 영역이 16B 미만 (버퍼 부족) | `heap_attrvalue_read_oos_inline` |
| **Case 2** | `or_get_oid` / `or_get_bigint` 결과 검증 | bigint 읽기 실패 또는 OID 가 NULL | `heap_attrvalue_read_oos_inline` |
| **Case 3** | length 범위 검증 | 인라인 length 가 (0, INT_MAX] 범위 밖 | `heap_attrvalue_read_oos_inline` |
| **Case 4** | alloc 단계 | `recdes_allocate_data_area` 실패 (OOM) | `heap_attrvalue_read_oos_inline` |
| **Case 5** | `oos_read` 단계 | `oos_read` 자체 실패 | `heap_attrvalue_read_oos_inline` |
| **Case D** | `offset_size` switch default | recdes 헤더의 `offset_size` 가 비합법 값 | `heap_attrvalue_point_variable` |

Case 5 는 `oos_read` 가 이미 `er_set` 을 마치고 음수 코드를 반환한다. 호출자는 중복 `er_set` 없이 그 값을 그대로 올린다.

### 발단

CBRD-26741 (PR #7097) squash 단계에서 corrupt-OID 처리가 비대칭하게 정리되었다. 일부 경로는 `er_set` + `assert_release_error` 를 쓰고, 일부는 `assert(...)` / `assert_release(false)` 만 호출한다.

NDEBUG 빌드에서 `assert_release(e)` 는 abort 가 아니라 `er_set(ER_NOTIFICATION_SEVERITY, ...)` 만 호출한다. 결과:

- 사용자는 SQL ERROR 가 아니라 NOTIFICATION 로그만 본다.
- 함수는 `raw->data == NULL` 상태로 정상처럼 반환된다.
- 호출자는 NULL 데이터를 받지만 그 사실을 모르고 결과셋에 NULL 을 섞어 내보낸다.

### 문제점

1. **시그니처가 `void`** — Case 1~5 에서 `er_set` 이 불려도 호출자는 에러가 났다는 사실 자체를 알 길이 없다.
2. **Case 4 는 `er_set` 마저 누락** — Case 1~3 과 달리 SQL 에러 응답이 아예 만들어지지 않는다.
3. **Case D — indeterminate read** — `default:` 경로에서 `offset` 이 초기화되지 않은 채 다음 라인 `OR_IS_OOS(offset)` 의 인자로 들어가, 스택 잔재값에 따라 OOS 분기 진입 여부가 비결정적으로 바뀐다.

진단 정보도 부족하다. Case 1~3 이 모두 인자 0개 코드로 통합돼 있어 손상된 OID 값을 실을 수 없었다.

### `*oos_owned_buffer` 계약

`*oos_owned_buffer == true` 의 의미: 호출자가 `recdes_free_data_area(&raw)` 를 불러야 할 (스크래치가 아닌) 버퍼가 남아 있다. 호출자 cleanup 은 `if (oos_owned_buffer && raw.data != oos_scratch)` 로 가드되며, 모든 에러 경로에서 `raw->data == NULL` 이라 NULL-tolerant free 와 맞물려 안전하다.

| 경로 | `*oos_owned_buffer` | 호출자 cleanup |
|---|---|---|
| 성공 (OOS 분기, heap-backed) | `true` | 사용 후 `recdes_free_data_area(&raw)` |
| 성공 (OOS 분기, scratch-backed) | `true` | `raw.data == oos_scratch` 라 가드에 걸려 no-op (스택 버퍼) |
| `OR_VAR_IS_NULL` early-return | `false` | 불필요 |
| Case D (default switch) | `false` | 불필요 |
| Case 1, 2, 3 (allocator 미접촉) | `false` | 불필요 |
| Case 4 (alloc 자체가 실패) | `false` | 불필요 |
| Case 5 (`oos_read` 실패) | `true` | 함수 내부에서 free + NULL 화. 호출자가 한 번 더 free 해도 NULL-tolerant 라 no-op |

### NULL 안전성

`recdes_free_data_area` → `db_private_free_and_init(NULL, rec->data)`. NDEBUG 는 매크로 자체에서, DEBUG 는 `db_private_free_*` 본문 첫 줄에서 NULL 을 가드한다. 양쪽 모두 `raw->data == NULL` 일 때 no-op.

---

## Specification Changes

사용자가 보는 스펙 변화: OOS corruption 시 종전에는 NOTIFICATION 로그만 남기고 NULL 값(또는 비결정적 분기)을 반환했으나, 이제는 SQL 에러로 응답한다.

### 케이스별 에러 코드 매핑

| Case | 트리거 | 에러 코드 | 코드 번호 | `*oos_owned_buffer` |
|---|---|---|---|---|
| Case 1 | 인라인 영역 < 16B | `ER_HEAP_OOS_BAD_INLINE_HEADER` | -1375 | false |
| Case 2 | OID null / bigint 실패 | `ER_HEAP_OOS_BAD_INLINE_HEADER` | -1375 | false |
| Case 3 | length 범위 위반 | `ER_HEAP_OOS_BAD_INLINE_HEADER` | -1375 | false |
| Case 4 | alloc 실패 | `ER_OUT_OF_VIRTUAL_MEMORY` | -3 | false |
| Case 5 | `oos_read` 실패 | callee-set 그대로 | (callee) | true |
| Case D | `offset_size` 비합법 | `ER_GENERIC_ERROR` | -2 | false |

### 함수 시그니처 변경

| 함수 | 전 | 후 |
|---|---|---|
| `heap_attrvalue_read_oos_inline` | `static void (RECDES*, RECDES*, char*, int)` | `static int (RECDES*, RECDES*, char*, int, bool* oos_owned_buffer)` |
| `heap_attrvalue_point_variable` | `static void` | `static int` (NO_ERROR / 에러 코드) |
| `heap_attrvalue_read` | 호출 결과 무시 | 반환값 받아 에러 시 cleanup + 상위 전파 |
| `heap_midxkey_get_value` | 시그니처는 이미 `int` | 호출자 측에서 에러 전파만 추가 |

### 에러 코드 선택 근거

#### Case 1 / 2 / 3 — `ER_HEAP_OOS_BAD_INLINE_HEADER` (-1375, 신규)

- **메시지 (en_US)**: `"Internal error: out-of-row storage record of object %1$d|%2$d|%3$d may be corrupted."`
- **메시지 (ko_KR)**: `"내부 에러: 오브젝트 "%1$d|%2$d|%3$d"의 out-of-row storage 레코드에 오류가 생겼을 수 있습니다."`
- **인자**: `OID_AS_ARGS(&oos_oid)` → `volid|pageid|slotid` (arity 3). OOS 분기 진입 직후 `OID_SET_NULL(&oos_oid)` 로 초기화해 Case 1 의 인자 안전성을 보장한다.
- **왜 전용 코드인가**: 최초 스펙은 `ER_HEAP_BAD_RELOCATION_RECORD` (-50) 재사용이었다. 그러나 그 메시지 본문에 "relocation record" 가 박혀 있어, OOS 손상을 그 코드로 보고하면 운영자가 heap `REC_RELOCATION` forwarder 서브시스템을 오인할 소지가 있다 (찍히는 OID 도 heap forwarder 슬롯이 아니라 OOS OID). 의미 정확도를 위해 전용 코드를 신설했다.
- **운영자 알람**: `ER_HEAP_OOS_BAD_INLINE_HEADER` 를 `system_parameter.c` 의 `call_stack_dump_error_codes[]` 에 등록 → SQL 에러와 함께 cub_server 가 콜스택을 자동 덤프한다 (기존 relocation 코드가 누리던 운영 편의를 그대로 유지).

#### Case 4 — `ER_OUT_OF_VIRTUAL_MEMORY` (-3)

- 메시지 ID 3: `"Out of virtual memory: unable to allocate %1$zu memory bytes."`. 포맷 `%1$zu` 가 `size_t` 를 요구하므로 인자는 `(size_t) oos_len`.
- 호출 측에서 명시적 `er_set` 필요 (callee 미설정).

#### Case 5 — `oos_read` 실패

- `oos_read` (`oos_file.cpp`) 가 자체 `er_set`. 호출 측은 중복 `er_set` 금지, `ASSERT_ERROR()` 로 callee-set 검증만.

#### Case D — `offset_size` 불법값 → `ER_GENERIC_ERROR` (-2)

- Case D 시점에는 OOS 인라인 페이로드를 아직 읽지 않아 OID 정보가 없다. recdes 헤더 자체의 inconsistency 에 해당하는 `ER_GENERIC_ERROR` 를 쓴다.

### 신규 에러 코드 6-step 워크플로우

| # | 파일 | 변경 |
|---|---|---|
| 1 | `src/base/error_code.h` | `ER_HEAP_OOS_BAD_INLINE_HEADER -1375` 정의, `ER_LAST_ERROR` 를 `-1376` 으로 갱신 |
| 2 | `msg/en_US.utf8/cubrid.msg` | 메시지 `1375` 추가, `Last Error` 센티넬을 `1376` 으로 재번호 |
| 3 | `msg/ko_KR.utf8/cubrid.msg` | 한글 메시지 `1375` 추가, 센티넬을 `1376` 으로 재번호 |
| 4 | (`ER_LAST_ERROR` 갱신) | error_code.h 에서 함께 처리 |
| 5 | `src/base/system_parameter.c` | `call_stack_dump_error_codes[]` 에 등록 (콜스택 자동 덤프) |
| 6 | `dbi_compat.h` / CCI `base_error_code.h` | **미적용** — 아래 근거 |

- 에러 코드 ↔ 메시지 번호는 **위치 기반 매핑**이라 신규 코드는 반드시 끝(센티넬 자리)에 추가해야 기존 1374개 코드 메시지가 안 밀린다.
- 런타임은 텍스트 `.msg` 가 아니라 `gencat` 이 컴파일한 `cubrid.cat` 을 읽는다. `msg/CMakeLists.txt` 가 `.msg` 변경 시 `.cat` 을 재생성하므로 빌드만 돌리면 반영된다.
- **dbi_compat.h 미적용 근거**: 이 파일은 heap 에러 코드를 미러하지 않는다 (`ER_* -num` 정의 0개).
- **CCI 미적용 근거**: `cubrid-cci/src/cci/base_error_code.h` 는 서브모듈이고 미러가 `-1264` 에서 멈춰 있다. 깊은 서버 heap 에러는 애초에 미러 대상이 아니며, 기존 `ER_HEAP_BAD_RELOCATION_RECORD` 이웃 코드들의 선례와 동일.

---

## Implementation

### Step 1. 시그니처 변경

forward 선언과 정의 모두:
- `heap_attrvalue_read_oos_inline`: `static void (...)` → `static int (..., bool * oos_owned_buffer)`.
- `heap_attrvalue_point_variable`: `static void` → `static int`.

### Step 2. 정상 종료 경로

- `heap_attrvalue_point_variable` 진입부에서 `*oos_owned_buffer = false` 명시. `OR_VAR_IS_NULL` early-return 과 비-OOS 분기 끝에서 `return NO_ERROR`.
- 헬퍼는 성공 경로에서 `raw->length` 설정 후 `*oos_owned_buffer = true; return NO_ERROR;`.

### Step 3. Case D (`default:` switch) early-return

```c
default:
  /* Case D: corrupt offset_size. Return now so the indeterminate `offset` below is never read. */
  er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
  return ER_GENERIC_ERROR;
```
`*oos_owned_buffer` 는 진입부에서 이미 false. 미초기화 `offset` 으로 다음 라인 `OR_IS_OOS(offset)` 도달 불가.

### Step 4. OOS 분기 실패 처리 (`heap_attrvalue_read_oos_inline`)

OOS 분기 진입 직후 `OID_SET_NULL(&oos_oid)`. Cases 1~3 은 가드만 다르고 형태가 같다:

```c
/* Case 1 */
if (buf.endptr - buf.ptr < OR_OID_SIZE + OR_BIGINT_SIZE)
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_OOS_BAD_INLINE_HEADER, 3, OID_AS_ARGS (&oos_oid));
    raw->data = NULL;
    *oos_owned_buffer = false;
    return ER_HEAP_OOS_BAD_INLINE_HEADER;
  }
/* Case 2: rc != NO_ERROR || OID_ISNULL (&oos_oid)        — 동일 형태 */
/* Case 3: oos_len <= 0 || oos_len > (DB_BIGINT) INT_MAX  — 동일 형태 */
```

Case 4 / Case 5:

```c
/* Case 4: alloc 실패 (scratch 안 맞을 때만 heap alloc) */
else if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_OUT_OF_VIRTUAL_MEMORY, 1, (size_t) oos_len);
    raw->data = NULL;
    *oos_owned_buffer = false;
    return ER_OUT_OF_VIRTUAL_MEMORY;
  }

/* Case 5: oos_read 실패 — callee-set 전파 */
error = oos_read (thread_p, oos_oid, oos_buffer (raw->data, (std::size_t) oos_len));
if (error != NO_ERROR)
  {
    ASSERT_ERROR ();
    if (raw->data != oos_scratch)
      {
        recdes_free_data_area (raw);
      }
    raw->data = NULL;
    *oos_owned_buffer = true;
    return error;
  }
```

### Step 5. 호출자 변경

`heap_attrvalue_read` / `heap_midxkey_get_value` 공통 패턴:

```c
error = heap_attrvalue_point_variable (recdes, attr_info, attrepr, &raw, &oos_owned_buffer, oos_scratch,
                                       IO_MAX_PAGE_SIZE);
if (error != NO_ERROR)
  {
    if (oos_owned_buffer && raw.data != oos_scratch)
      {
        recdes_free_data_area (&raw);
      }
    return error;
  }
```

핵심: 에러일 때 **값 변환(`heap_attrvalue_transform_to_dbvalue`)으로 흘러가지 않게** 막는다. 안 그러면 NULL `raw.data` 가 다시 "정상 NULL 값" 으로 둔갑한다. `heap_midxkey_get_value` 는 진입부에서 이미 `db_make_null(value)` 호출.

### Step 6. 호출 체인

```
heap_attrinfo_read_dbvalues / heap_get_indexvalue_of_attribute / ...
   → heap_attrvalue_read (int)           — 반환값 받기
       → heap_attrvalue_point_variable (int)   — void → int
           → offset_size switch default        Case D (ER_GENERIC_ERROR)
           → heap_attrvalue_read_oos_inline (int)   — void → int, Case 1~5
```

---

## Acceptance Criteria

- [x] `heap_attrvalue_read_oos_inline` / `heap_attrvalue_point_variable` 반환 타입 `int`, forward 선언 + 정의 모두 갱신.
- [x] 정상 경로 (`OR_VAR_IS_NULL`, 비-OOS 분기 끝): `*oos_owned_buffer` 설정 + `return NO_ERROR`.
- [x] Case D: `er_set(ER_GENERIC_ERROR)` + early-return → 미초기화 `offset` 도달 불가.
- [x] OOS 분기 진입 직후 `OID_SET_NULL(&oos_oid)`.
- [x] Case 1~3 → `ER_HEAP_OOS_BAD_INLINE_HEADER`, `oos_owned_buffer = false`.
- [x] Case 4 → `ER_OUT_OF_VIRTUAL_MEMORY` (`(size_t) oos_len`), false.
- [x] Case 5 → callee-set 전파, `recdes_free_data_area` + `oos_owned_buffer = true`.
- [x] 모든 에러 반환 경로에서 `raw->data == NULL`.
- [x] 호출자 두 곳이 반환값 받아 cleanup + 상위 전파, 에러 시 transform 미진입.
- [x] 신규 에러 코드 6-step (dbi_compat/CCI 제외 근거 명시).
- [x] 단위 테스트: `bridge_heap_attrvalue_read_oos_inline` (`CUBRID_UNIT_TEST_ENABLED` 가드) + `TEST(OosTest, HeapAttrvalueReadOosInlineCorruptHeader)` 로 Case 1~3 커버.
- [x] 회귀: OOS ctest 13개 전부 통과 (`test_oos_sql_*` SQL 회귀 포함).

### 단위 테스트 커버리지

| Case | In-scope test? | 근거 |
|---|---|---|
| 1 | yes | 인라인 영역 합성 가능 |
| 2 (NULL OID) | yes | 인라인 OID 합성 가능 |
| 2 (bigint read fail) | no | 합성 trigger 어려움 |
| 3 | yes | 인라인 length 합성 가능 |
| 4 | no | OOM injection 인프라 부재 |
| 5 | no | mock seam 부재, callee-set 비결정 |
| D | no | `offset_size` 합성 인프라 부재 |

테스트는 합성 16바이트 이정표(`or_put_oid` + `or_put_bigint` 로 작성)를 `bridge_heap_attrvalue_read_oos_inline` 에 넣고, `ER_HEAP_OOS_BAD_INLINE_HEADER` 반환 / `er_errid()` / `raw->data == NULL` / `oos_owned_buffer == false` 를 검증한다.

---

## 구현 중 스펙 변경

최초 스펙(JIRA 작성 시점) 대비 두 가지가 달라졌다.

1. **에러 코드: 재사용 → 전용 신설.** 최초 스펙은 "신규 에러 코드 없음, `ER_HEAP_BAD_RELOCATION_RECORD` 재사용". 그러나 OOS 이정표와 heap `REC_RELOCATION` forwarder 는 의미가 다르고, 재사용 코드의 메시지("relocation record")가 운영자를 오인시킬 수 있다는 지적에 따라 `ER_HEAP_OOS_BAD_INLINE_HEADER` 를 신설했다. CBRD-26637 후속으로 미뤘던 작업을 본 티켓에서 수행한 셈.
2. **코드 구조: 단일 함수 → 헬퍼 분리 기준.** 최초 스펙은 인라인 OOS 로직이 `heap_attrvalue_point_variable` 한 함수 안에 있던 시점 기준으로 작성됐다. 이후 (스펙이 out-of-scope 로 분류했던) 인라인 헬퍼 분리 + 스택 스크래치 fast-path 가 먼저 머지됐다. 그래서 Case 1~5 는 헬퍼 `heap_attrvalue_read_oos_inline` 에, Case D 는 `heap_attrvalue_point_variable` 에 위치한다. `*is_oos` 플래그는 `*oos_owned_buffer` 로 개명됐고, 헬퍼의 출력 파라미터로 추가됐다.

---

## Out of Scope

- 스택 버퍼 fast-path (이미 선행 머지됨).
- PEEK-mode `oos_read` 와 dbvalue zero-copy (`heap_attrvalue_read` 의 TODO 주석).
- Case 4 (alloc 실패), Case 5 (`oos_read` 실패), Case D (`offset_size` corruption), Case 2 의 `bigint` read-fail 분기 — 단위 테스트 trigger 인프라 부재. 코드 리뷰로 본다.
- Case 2 진단 메시지에 부모 OID / `attrepr->location` 추가 — 시그니처 추가 변경 또는 `oos_error` 보조 로깅 필요. 본 티켓 범위 밖.
- 로컬 `offset` 변수를 함수에서 완전히 제거하는 후속 정리. 본 티켓은 default 경로 indeterminate read 만 차단한다.

---

## References

### `src/storage/heap_file.c`

| 무엇 | 비고 |
|---|---|
| `heap_attrvalue_read_oos_inline` | `static int (..., bool * oos_owned_buffer)`. OOS 분기 Case 1~5 |
| `heap_attrvalue_point_variable` | `static int`. `offset_size` switch (Case D) + 헬퍼 위임 |
| `heap_attrvalue_read` | 호출자 1 — 반환값 받아 전파 |
| `heap_midxkey_get_value` | 호출자 2 — 반환값 받아 전파 |
| `bridge_heap_attrvalue_read_oos_inline` | `#if defined(CUBRID_UNIT_TEST_ENABLED)` 테스트 seam (파일 끝) |

### 다른 소스

| 파일 | 무엇 |
|---|---|
| `src/base/error_code.h` | `ER_HEAP_OOS_BAD_INLINE_HEADER -1375`, `ER_LAST_ERROR -1376` |
| `msg/en_US.utf8/cubrid.msg` | 메시지 1375 + 센티넬 1376 |
| `msg/ko_KR.utf8/cubrid.msg` | 한글 메시지 1375 + 센티넬 1376 |
| `src/base/system_parameter.c` | `call_stack_dump_error_codes[]` 등록 |
| `src/storage/oos_file.cpp` | `oos_read(THREAD_ENTRY*, const OID&, oos_buffer)` (callee, 이미 int, callee-set) |
| `src/storage/storage_common.c` | `recdes_allocate_data_area` (NULL 시 `ER_FAILED`, 자체 `er_set` 없음), `recdes_free_data_area` (NULL-tolerant) |
| `unit_tests/oos/test_oos.cpp` | `TEST(OosTest, HeapAttrvalueReadOosInlineCorruptHeader)` + bridge 선언 |

## Remarks

- 부모 에픽: CBRD-26583 (OOS M2).
- PR: [CUBRID/cubrid#7296](https://github.com/CUBRID/cubrid/pull/7296) (draft, base `feat/oos`).
- PR #7097 리뷰 후속(r3200880248, r3201449095, r3201449462).
- 관련 티켓: CBRD-26637 (error handling refactor) — 본 티켓에서 OOS 전용 코드를 신설하며 한 걸음 진전.
