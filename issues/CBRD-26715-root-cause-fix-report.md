# [OOS] `heap_update_adjust_recdes_header`에서 OOS 플래그 판정 방식 변경 보고

## Summary

`heap_update_adjust_recdes_header()`에서 OOS 플래그를 판정하는 방식을 VOT 스캔(`heap_recdes_check_has_oos`)에서 MVCC 헤더 플래그 참조(`mvcc_flags & OR_MVCC_FLAG_HAS_OOS`)로 변경하였다.

---

## Background

### 기존 코드

```c
// heap_update_adjust_recdes_header()  [heap_file.c:21744]
bool has_oos = heap_recdes_check_has_oos (update_context->recdes_p);

if (has_oos)
    repid_and_flag_bits |= (OR_MVCC_FLAG_HAS_OOS << OR_MVCC_FLAG_SHIFT_BITS);
else
    repid_and_flag_bits &= ~(OR_MVCC_FLAG_HAS_OOS << OR_MVCC_FLAG_SHIFT_BITS);
```

이 코드는 새로 구성된 레코드의 **VOT(Variable Offset Table)를 스캔**하여 OOS 여부를 재판정한 뒤, 그 결과를 MVCC 헤더에 기록한다.

### 변경 후 코드

```c
/* Trust the OOS flag already set by the record transformer. */
bool has_oos = (mvcc_flags & OR_MVCC_FLAG_HAS_OOS) != 0;
```

레코드 변환기(transformer)가 **이미 정확하게 설정한 MVCC 플래그를 그대로 신뢰**한다.

---

## Problem

### `OR_VAR_BIT_OOS` (bit 0)와 홀수 오프셋의 충돌

`heap_recdes_check_has_oos()`는 VOT의 각 엔트리에서 `OR_IS_OOS(offset)`를 호출한다:

```c
#define OR_IS_OOS(offset)  ((offset) & OR_VAR_BIT_OOS)   // offset & 0x1
```

OOS 기능은 VOT 오프셋의 하위 2비트를 플래그로 재정의하였다:

| 비트 | 매크로 | 의미 |
|------|--------|------|
| bit 0 (0x1) | `OR_VAR_BIT_OOS` | 해당 컬럼이 OOS로 저장됨 |
| bit 1 (0x2) | `OR_VAR_BIT_LAST_ELEMENT` | VOT의 마지막 엔트리 |

그러나 **VOT 오프셋은 레코드 내부의 바이트 오프셋**이므로, 홀수 값이 자연스럽게 발생할 수 있다. 홀수 오프셋은 bit 0이 1이므로 `OR_IS_OOS()`가 `true`를 반환한다 — **거짓 양성(false positive)**.

### 거짓 양성 확인

`createdb` 실행 시 카탈로그 레코드에서 거짓 양성이 발생함을 확인하였다:

```
[OOS-CONSISTENCY] MISMATCH: flag_has_oos=0, vot_has_oos=1
repid_and_flags=0x40000000, mvcc_flags=0x00, rec_len=136, offset_size=2
```

- `flag_has_oos=0`: MVCC 헤더에는 OOS 플래그가 없음 (정상)
- `vot_has_oos=1`: VOT 스캔이 홀수 오프셋을 OOS로 잘못 판정 (거짓 양성)
- 136바이트의 카탈로그 레코드로, OOS 데이터가 있을 수 없는 크기

### CI 타임아웃으로 이어지는 전파 경로

```
① 카탈로그 또는 일반 레코드에 홀수 VOT 오프셋이 존재
                    ↓
② UPDATE 시 heap_update_adjust_recdes_header() 호출
                    ↓
③ heap_recdes_check_has_oos()가 홀수 오프셋을 OOS로 판정 (거짓 양성)
                    ↓
④ OR_MVCC_FLAG_HAS_OOS가 MVCC 헤더에 설정됨
                    ↓
⑤ Vacuum이 MVCC 플래그를 읽고 OOS 파일을 찾으려 함
                    ↓
⑥ OOS 파일이 없어 ER_FAILED 반환
                    ↓
⑦ 릴리즈 빌드에서 continue가 page_ptr 전진을 건너뜀 → 무한 루프
                    ↓
⑧ CPU 100%, SQL 테스트 기아 → 45분 CI 타임아웃
```

---

## Why This Fix Is Correct

### 레코드 변환기가 이미 OOS 플래그를 정확하게 설정함

`heap_update_adjust_recdes_header()`에 전달되는 `recdes_p`는 직전에 `heap_attrinfo_transform_to_disk_internal()`이 구성한 레코드이다. 이 함수의 내부 흐름:

```
heap_attrinfo_transform_to_disk_internal()
  │
  ├─ heap_attrinfo_determine_disk_layout()        ← has_oos를 권위적으로 판정
  │   (각 컬럼의 크기를 OOS 임계값과 비교하여 OOS 여부 결정)
  │
  ├─ heap_attrinfo_transform_header_to_disk(..., has_oos)
  │   └─ if (has_oos) repid_bits |= OR_MVCC_FLAG_HAS_OOS   ← MVCC 헤더에 설정
  │
  └─ heap_attrinfo_transform_variable_to_disk(..., is_oos, ...)
      └─ if (is_oos) length = OR_SET_VAR_OOS(length)       ← VOT에 OOS 마킹
```

즉, `heap_update_adjust_recdes_header()`가 호출되는 시점에 **MVCC 플래그는 이미 올바르게 설정**되어 있다. VOT를 재스캔할 필요가 없다.

### INSERT 경로와 동일한 방식

INSERT 경로(`heap_insert_adjust_recdes_header`, line 21607)는 이미 MVCC 플래그를 신뢰한다:

```c
bool has_oos = (mvcc_flags & OR_MVCC_FLAG_HAS_OOS) != 0;
```

변경 후 UPDATE 경로도 동일한 방식을 사용하므로, **두 경로의 일관성이 확보**된다.

### if/else 블록 제거 이유

기존 if/else 블록:

```c
if (has_oos)
    repid_and_flag_bits |= (OR_MVCC_FLAG_HAS_OOS << OR_MVCC_FLAG_SHIFT_BITS);
else
    repid_and_flag_bits &= ~(OR_MVCC_FLAG_HAS_OOS << OR_MVCC_FLAG_SHIFT_BITS);
```

`has_oos`가 이미 `mvcc_flags`에서 읽은 값이므로, 이 블록은 `repid_and_flag_bits`에 **이미 설정된 동일한 값을 다시 쓰는 no-op**이다. 따라서 제거하였다.

---

## Additional Changes

### `heap_recdes_check_has_oos()` 개선

VOT에 `LAST_ELEMENT` 센티넬이 없으면 (구형 레코드 포맷) OOS 판정을 신뢰하지 않도록 변경:

```c
// 변경 전: OR_IS_OOS를 먼저 확인 → 홀수 오프셋에서 바로 true 반환
if (OR_IS_OOS (offset))
    return true;
if (OR_IS_LAST_ELEMENT (offset))
    return false;

// 변경 후: 모든 엔트리를 스캔하고, LAST_ELEMENT이 있을 때만 OOS 결과를 신뢰
if (OR_IS_OOS (offset))
    has_oos = true;
if (OR_IS_LAST_ELEMENT (offset))
    return has_oos;

// LAST_ELEMENT 없음 → 구형 포맷 → false 반환
return false;
```

### 교차 검증 assert 추가

`heap_recdes_contains_oos()` (MVCC 플래그 확인)에 디버그 모드 assert를 추가하여, MVCC 플래그가 설정되었으나 VOT에서 OOS를 찾지 못하는 **위험한 불일치**(flag=1, VOT=0)를 감지한다:

```c
#if !defined (NDEBUG)
if (flag_has_oos && !vot_has_oos)
    assert (false && "MVCC flag has OOS but VOT scan finds no OOS");
#endif
```

반대 방향(flag=0, VOT=1)은 홀수 오프셋에 의한 알려진 거짓 양성이므로 assert하지 않는다.

---

## Verification

| 테스트 | 결과 |
|--------|------|
| `cubrid createdb` (SA_MODE) | 성공 — 이전에는 카탈로그 레코드 거짓 양성으로 assert 실패 |
| CTP SQL 17,392 테스트 | 실행 중 (무한 루프 없음, 서버 크래시 없음) |
| CI `test_sql` | 빌드 대기 중 |

---

## References

- **JIRA**: http://jira.cubrid.org/browse/CBRD-26715
- **PR**: https://github.com/CUBRID/cubrid/pull/6986
- **관련 티켓**: CBRD-26671 (PR #7009, `OR_VAR_BIT_LAST_ELEMENT` 추가)
- **커밋**: `a3a3673f4` (fix(oos): stop false-positive OOS flag from VOT odd-offset collision)
