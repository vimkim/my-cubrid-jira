# [OOS] [Refactoring] heap_attrvalue_point_variable 시그니처를 int 반환으로 변경하여 OOS read 실패 전파

> **TL;DR**: 현재 `heap_attrvalue_point_variable` 는 `void` 반환이라 OOS 인라인 OID 손상 / `oos_read` 실패 시 `assert_release (false)` + `raw->data = NULL` 만 남기고 에러를 호출자에게 전달하지 못한다. 시그니처를 `int` 로 바꾸고 `er_set` + 에러 전파 경로를 살려 release 빌드에서도 corruption 을 안전하게 보고하도록 한다.

## Summary

- **문제 / 목적**: `heap_attrvalue_point_variable` 가 OOS 경로에서 발생하는 corruption / read 실패를 호출자에게 전달하지 못한다.
- **원인 / 배경**: CBRD-26741 squash 단계에서 corrupt-OID 런타임 검사를 assert 패턴으로 회귀시키면서 `raw->data = NULL` 만 남고 에러 코드 전파 경로가 제거됨. 함수 시그니처가 `void` 라 호출자도 받을 방법이 없음.
- **제안 / 변경**: `heap_attrvalue_point_variable` 의 반환 타입을 `int` 로 변경하고, 호출 체인 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 에서 에러를 전파.
- **영향 범위**: `src/storage/heap_file.c` 의 가변 길이 속성 읽기 경로 (heap scan, midxkey 추출). 정상 경로 동작 변화 없음. release 빌드에서 OOS corruption 시 `er_set` 으로 정확한 에러를 사용자에게 보고할 수 있게 됨.

---

## Description

### 배경

CBRD-26741 (PR #7097) 에서 `oos_read` 를 caller-preallocated buffer API 로 리팩터링하면서, `heap_attrvalue_point_variable` 가 인라인 8B 길이 필드를 읽고 `recdes_allocate_data_area` + `oos_read` 를 호출하는 흐름으로 정리되었다.

PR 리뷰 과정에서 다음과 같은 corrupt-OID / 실패 경로 처리 코드가 제안되었다.

```c
er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD, 3,
        oos_oid.volid, oos_oid.pageid, oos_oid.slotid);
raw->data = NULL;
/* TODO(CBRD-XXXXX): propagate this failure via int return; for now caller
 * sees raw->data == NULL and treats it as absence-of-data. */
```

리뷰어 의견 (`hornetmj`): "이슈화 해주세요." (PR #7097 review comment 3200880248)

squash 과정에서 위 TODO 블록은 제거되고, 현재 코드는 다음과 같이 `assert_release (false)` 패턴으로 회귀되어 있다 (`src/storage/heap_file.c:10668-10672`).

```c
if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR
    || oos_read (thread_p, oos_oid, *raw) != NO_ERROR)
  {
    raw->data = NULL;
    assert_release (false);
  }
```

### 문제점

1. **release 빌드에서 corruption 이 silent 하게 사라진다**: `assert_release` 는 release 에서 활성 (`abort`) 되긴 하지만, 그 직전 `raw->data = NULL` 로 데이터 부재 신호만 남고 에러 코드는 호출자에게 전달되지 않는다.
2. **에러 코드 일원화 위배**: CUBRID 의 표준 에러 흐름은 `er_set` + `return error_code` 인데, 이 경로만 예외적으로 `void` 라 표준 흐름에 합류하지 못한다.
3. **호출 체인이 에러를 받을 준비가 안 되어 있다**: `heap_attrvalue_read` 와 `heap_midxkey_get_value` 는 이미 `int` 반환이지만, `heap_attrvalue_point_variable` 에서 발생한 에러를 받을 채널이 없다.

### 목적

- `heap_attrvalue_point_variable` 의 시그니처를 `void` -> `int` 로 변경
- OOS 경로의 모든 실패 (corrupt OID, 인라인 길이 범위 위반, alloc 실패, `oos_read` 실패) 를 `er_set` + return code 로 표준화
- 호출자 (`heap_attrvalue_read`, `heap_midxkey_get_value`) 에서 에러를 받아 상위로 전파

---

## Specification Changes

사용자/매뉴얼 관점의 스펙 변화 없음. 내부 API 시그니처 변경.

| 함수 | 파일 | 변경 전 | 변경 후 |
|---|---|---|---|
| `heap_attrvalue_point_variable` | `src/storage/heap_file.c` | `static void` | `static int` (NO_ERROR / 에러 코드 반환) |
| `heap_attrvalue_read` | `src/storage/heap_file.c` | 내부에서 `heap_attrvalue_point_variable` 호출 후 무시 | 반환값을 받아 에러 시 즉시 return |
| `heap_midxkey_get_value` | `src/storage/heap_file.c` | 동일 | 동일 |

릴리즈 빌드의 사용자 가시 동작 변화: OOS corruption 시 종전에는 `abort` 로 죽거나 `raw->data == NULL` 로 잘못된 dbvalue 가 흘러갔던 경로가, `ER_HEAP_BAD_RELOCATION_RECORD` (또는 `oos_read` 가 set 한 에러) 로 정상적인 SQL 에러 응답이 된다.

---

## Implementation

### 1. `heap_attrvalue_point_variable` 시그니처 변경

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

### 2. 실패 경로마다 `er_set` + return

```c
/* corrupt OID */
if (OID_ISNULL (&oos_oid))
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_BAD_RELOCATION_RECORD,
            3, OID_AS_ARGS (&oos_oid));
    raw->data = NULL;
    return ER_HEAP_BAD_RELOCATION_RECORD;
  }

/* inline length out of range */
if (oos_len <= 0 || oos_len > (DB_BIGINT) INT_MAX)
  {
    er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_GENERIC_ERROR, 0);
    raw->data = NULL;
    return ER_GENERIC_ERROR;
  }

/* alloc failure */
if (recdes_allocate_data_area (raw, (int) oos_len) != NO_ERROR)
  {
    ASSERT_ERROR_AND_SET (error);
    raw->data = NULL;
    return error;
  }

/* oos_read failure */
error = oos_read (thread_p, oos_oid, *raw);
if (error != NO_ERROR)
  {
    ASSERT_ERROR ();
    recdes_free_data_area (raw);
    raw->data = NULL;
    return error;
  }
```

`OID_AS_ARGS` 매크로 사용 (PR #7097 리뷰 comment 3200899741 반영).

### 3. 호출자 변경

```c
/* heap_attrvalue_read */
else
  {
    error = heap_attrvalue_point_variable (recdes, attr_info, attrepr, &raw, &is_oos);
    if (error != NO_ERROR)
      {
        ASSERT_ERROR ();
        return error;
      }
  }

/* heap_midxkey_get_value */
else
  {
    error = heap_attrvalue_point_variable (recdes, attr_info, att, &raw, &is_oos);
    if (error != NO_ERROR)
      {
        ASSERT_ERROR ();
        db_make_null (value);
        return error;
      }
  }
```

### 4. 호출 체인 그림

```
heap_attrinfo_read_dbvalues / heap_get_indexvalue_of_attribute / ...
   |
   v
heap_attrvalue_read (int)         ----  변경: point_variable 반환값 받기
   |
   v
heap_attrvalue_point_variable (int)  ----  void -> int
   |
   +-- or_get_oid       (no change)
   +-- or_get_bigint    (no change)
   +-- recdes_allocate_data_area  ----  실패 시 er_set + return
   +-- oos_read         ----  실패 시 er_set + return
```

---

## Acceptance Criteria

- [ ] `heap_attrvalue_point_variable` 의 반환 타입이 `int` 로 변경되고 정상 경로에서 `NO_ERROR` 반환
- [ ] OOS 인라인 OID 가 NULL 인 경우 `ER_HEAP_BAD_RELOCATION_RECORD` 가 `er_set` 되고 호출자에게 전파
- [ ] 인라인 length 가 범위 (0, INT_MAX] 를 벗어나면 적절한 에러 코드가 `er_set` 되고 전파
- [ ] `recdes_allocate_data_area` 실패 시 `ASSERT_ERROR_AND_SET` 으로 에러 코드 추출 후 전파
- [ ] `oos_read` 실패 시 callee 가 set 한 에러를 그대로 전파 (이중 set 금지)
- [ ] `heap_attrvalue_read` / `heap_midxkey_get_value` 가 `point_variable` 의 반환값을 받아 에러 시 상위로 전파
- [ ] 정상 경로의 OOS read 동작 변화 없음 (기존 단위 테스트 / SQL 테스트 그대로 통과)
- [ ] 의도적으로 corrupt 시킨 인라인 OID / length 가 release 빌드에서 `abort` 가 아닌 정상 SQL 에러로 응답되는 시나리오 테스트 추가
- [ ] CI (`test_sql`, `test_medium`, unit_tests/oos) 전체 통과

## Definition of done

- [ ] 위 A/C 충족
- [ ] PR 리뷰 / merge
- [ ] CBRD-26741 의 corrupt-OID 처리 후속 약속 (PR #7097 review comments 3201449095, 3201449462) 해소

---

## 참고 코드

- `src/storage/heap_file.c:10602-10690` — `heap_attrvalue_point_variable` 본체
- `src/storage/heap_file.c:10761-10820` — `heap_attrvalue_read` (호출자 1)
- `src/storage/heap_file.c:10830-10920` — `heap_midxkey_get_value` (호출자 2)
- `src/storage/heap_file.c:701-707` — 정적 함수 forward 선언
- `src/storage/oos_file.cpp` — `oos_read` (callee, 이미 int 반환)
- `src/base/error_code.h` — `ER_HEAP_BAD_RELOCATION_RECORD`

## Remarks

- 선행: CBRD-26741 (oos_read caller-preallocated 리팩터링) merge 후 진행
- 부모 에픽: CBRD-26583 (OOS M2)
- PR #7097 관련 리뷰 코멘트
  - 3200880248 (`hornetmj`): "이슈화 해주세요"
  - 3201449095 (`vimkim`): TODO 블록 제거 + 별도 후속 티켓으로 분리 약속
  - 3201449462 (`vimkim`): `OID_AS_ARGS` 패턴 적용은 후속 티켓에서 처리 약속
- 본 티켓은 *시그니처/에러 전파* 작업만 다룸. 다음 후속 작업은 별도 티켓:
  - 스택 버퍼 fast-path (PR #7097 review comment 3201451481, `HEAP_CACHE_ATTRINFO` scratch buffer 도입)
