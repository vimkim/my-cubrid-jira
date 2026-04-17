# [OOS/VACUUM] Vacuum 무한 루프 — OR_MVCC_FLAG_HAS_OOS 거짓 양성으로 인한 CI 타임아웃

## Description

### 배경

PR #6986 (`oos-vacuum` 브랜치)의 CircleCI `test_sql` 작업이 45분 타임아웃으로 실패한다.
10개 병렬 노드 중 8개가 실패하며, 서버 에러 로그에 동일한 에러가 **90,000회 이상** 반복된다:

```
VACUUM ERROR: Failed to find OOS VFID for hfid 0|4544.
INTERNAL ERROR: Assertion 'false' failed.  (EID = 121,735,498)
```

`feat/oos` 브랜치에서는 동일 SQL 테스트가 정상 통과한다.

### 목적

1. Vacuum 무한 루프의 원인을 분석하고 임시 수정을 적용한다.
2. `OR_MVCC_FLAG_HAS_OOS` 거짓 양성의 근본 원인을 파악하여 향후 수정 방향을 제시한다.

---

## Analysis

### 1. 무한 루프 메커니즘

Vacuum이 `OR_MVCC_FLAG_HAS_OOS` 플래그가 설정된 레코드를 만났으나 해당 힙에 OOS 파일이 없을 때 발생한다.

```
vacuum_heap_page_execute                         [vacuum.c:1512]
  for (page_ptr = ...; page_ptr < ...; )         ← 증감식 없음
    ↓
    vacuum_heap_page                             [vacuum.c:1558]
      ↓
      vacuum_heap_prepare_record                 [vacuum.c:2173]
        heap_recdes_contains_oos() == true       ← OOS 플래그(0x08) 설정됨
        heap_oos_find_vfid() == false            ← OOS 파일 없음
        → return ER_FAILED
      ↓
      goto end → return ER_FAILED
    ↓
    #if defined(NDEBUG)                          [vacuum.c:1539]
      er_clear();
      error_code = NO_ERROR;
      continue;        ← page_ptr = obj_ptr 건너뜀!
    #endif
    ↓
    동일 page_ptr → 동일 에러 → continue → 무한 루프
```

핵심: `continue` 가 `page_ptr = obj_ptr;` (line 1553)를 건너뛰어 페이지 포인터가 전진하지 않는다. 이 패턴은 릴리즈 빌드(`NDEBUG`)에서만 발생한다.

### 2. 거짓 양성 확인

로컬 CTP 테스트에서 진단 로그를 통해 확인된 거짓 양성 레코드:

```
hfid=0|20928, slotid=1
len=144, repid_and_flags=0xc9000001
mvcc_flags=0x09 (INSID=1 DELID=0 PREV=0 OOS=1)
repid=1, offset_size=2 (SHORT)
```

- 144바이트의 작은 레코드로, OOS가 필요한 크기가 아님
- `OR_MVCC_FLAG_HAS_OOS` (0x08)가 설정되어 있으나 해당 힙에 OOS 파일이 존재하지 않음
- **거짓 양성이 확정됨**: 레코드에 실제 OOS 데이터가 없는데 플래그만 설정됨

### 3. 거짓 양성의 추정 원인

`OR_MVCC_FLAG_HAS_OOS` 플래그는 UPDATE 경로에서 `heap_recdes_check_has_oos()` 를 통해 설정된다:

```c
// heap_update_adjust_recdes_header()            [heap_file.c:21744]
bool has_oos = heap_recdes_check_has_oos (update_context->recdes_p);
if (has_oos)
    repid_and_flag_bits |= (OR_MVCC_FLAG_HAS_OOS << OR_MVCC_FLAG_SHIFT_BITS);
```

`heap_recdes_check_has_oos()` 는 VOT(Variable Offset Table)의 각 엔트리에서 `OR_VAR_BIT_OOS` (bit 0)를 확인한다:

```c
// heap_recdes_check_has_oos()                   [heap_file.c:28019]
if (OR_IS_OOS (offset))    // offset & 0x1
    return true;
```

**`OR_VAR_BIT_OOS`는 VOT 오프셋의 bit 0을 사용한다.** OOS 기능 도입 전에는 VOT 오프셋이 플래그 비트 없이 원시 값으로 저장되었다. 오프셋 값이 홀수인 경우 `OR_IS_OOS()` 가 거짓 양성을 반환할 수 있다.

#### 관련 수정 이력

| 커밋 | 내용 | 영향 |
|------|------|------|
| `e4f847760` ([CBRD-26671] PR #7009) | `OR_VAR_BIT_LAST_ELEMENT` 를 VOT 마지막 엔트리에 추가 | 중간 엔트리의 거짓 양성은 미해결 |
| `c79cdca59` ([CBRD-26537] PR #6829) | `OR_VAR_BIT_OOS`, `OR_VAR_BIT_LAST_ELEMENT` 도입 | VOT 포맷 변경의 시작점 |

커밋 `e4f847760` 은 `transform_cl.c`, `catalog_class.c`, `heap_file.c`, `load_object.c` 의 마지막 VOT 엔트리에 `LAST_ELEMENT` 를 추가했으나, **중간 엔트리에 홀수 오프셋이 존재하면 `OR_IS_OOS()`가 여전히 true를 반환** 할 수 있다.

#### 로컬 테스트 결과

단순 테이블(INT + VARCHAR 조합)에서는 VOT의 첫 번째 오프셋이 항상 짝수(4, 12, 16, 20 등)로 관찰되어 재현이 어려웠다. 그러나 17,392개의 CTP SQL 테스트 중 일부 스키마에서 거짓 양성이 발생함을 확인하였다.

### 4. feat/oos에서 발생하지 않는 이유

`feat/oos` 브랜치에는 vacuum 내 OOS VFID 조회 코드(line 2173-2182)가 존재하지 않는다. Vacuum이 `OR_MVCC_FLAG_HAS_OOS` 플래그를 확인하지 않으므로, 플래그가 잘못 설정되어도 문제가 발생하지 않는다.

---

## Implementation (임시 수정)

### 적용된 임시 수정 (`b85b659b3`)

`heap_oos_find_vfid()` 가 실패할 때 **`ER_FAILED` 반환 대신 `oos_vfid`를 NULL로 유지** 하고 경고만 기록한다:

```c
if (!heap_oos_find_vfid (thread_p, &helper->hfid, &helper->oos_vfid, false))
{
    /* oos_vfid를 NULL로 유지 — 하류 OOS 코드는 모두 !VFID_ISNULL 가드가 있음 */
    vacuum_er_log_warning (VACUUM_ER_LOG_HEAP,
        "OOS flag set but no OOS VFID for hfid %d|%d (slotid=%d) — skipping OOS cleanup",
        VFID_AS_ARGS (&helper->hfid.vfid), (int) helper->crt_slotid);
}
```

하류 OOS 관련 코드는 모두 `!VFID_ISNULL(&helper->oos_vfid)` 가드가 있어 안전하게 OOS 정리를 건너뛴다:

| 위치 | 가드 |
|------|------|
| `vacuum_cleanup_prev_version_oos` 호출부 (line 2277) | `!VFID_ISNULL (&helper->oos_vfid)` |
| `vacuum_heap_oos_delete` 내부 (line 2574) | `assert (!VFID_ISNULL (...))` |
| `has_oos` 판정 (line 2614) | `!VFID_ISNULL (&helper->oos_vfid) && ...` |

REC_HOME과 REC_RELOCATION 양쪽 모두 동일하게 수정하였다.

---

## Root Cause (향후 수정 필요)

임시 수정은 vacuum의 무한 루프를 방지하지만, **거짓 양성의 근본 원인은 미해결** 이다:

1. **`OR_VAR_BIT_OOS` (bit 0)와 VOT 오프셋의 충돌**: VOT 오프셋의 bit 0을 OOS 플래그로 사용하는 설계에서, 홀수 오프셋이 거짓 양성을 유발할 수 있다. `LAST_ELEMENT` 수정(PR #7009)으로 마지막 엔트리 이후의 잘못된 스캔은 방지되었으나, 중간 엔트리의 홀수 오프셋 문제는 해결되지 않았다.

2. **`heap_recdes_check_has_oos()`의 스캔 순서**: `OR_IS_OOS(offset)` 을 `OR_IS_LAST_ELEMENT(offset)` 보다 먼저 확인하므로, 홀수 오프셋의 중간 엔트리가 마지막 엔트리보다 먼저 매칭된다.

3. **가능한 근본 수정 방향**:
   - VOT 오프셋을 항상 2바이트 또는 4바이트로 정렬하여 bit 0이 항상 0이 되도록 보장
   - `heap_recdes_check_has_oos()` 에서 `OR_IS_OOS` 판정 시 추가 검증 로직 도입
   - UPDATE 경로에서 `heap_recdes_check_has_oos()` 대신 `heap_recdes_contains_oos()` (MVCC 플래그 확인)를 사용하여 플래그 전파 방지

---

## Acceptance Criteria

- [x] Vacuum 무한 루프 제거 (임시 수정 적용됨)
- [x] CTP SQL 테스트 통과 확인 (로컬)
- [ ] CI `test_sql` 통과 확인
- [ ] `OR_MVCC_FLAG_HAS_OOS` 거짓 양성의 근본 원인 수정
- [ ] 거짓 양성 레코드가 생성되지 않음을 검증하는 테스트 추가

---

## Remarks

- **관련 PR**: https://github.com/CUBRID/cubrid/pull/6986
- **관련 CI 실패**: [CircleCI job #122402](https://app.circleci.com/pipelines/github/CUBRID/cubrid/28103/workflows/f94a6624-9678-429e-958c-cb153cfa9bfa/jobs/122402/steps)
- **임시 수정 커밋**: `b85b659b3` (fix(vacuum): gracefully skip OOS cleanup when no OOS file exists)
- **관련 티켓**: CBRD-26671 (PR #7009, `OR_VAR_BIT_LAST_ELEMENT` 수정)
- 거짓 양성은 약 17,000개의 SQL 테스트 중 특정 스키마에서만 발생하며, 단순 스키마로는 재현이 어려움
