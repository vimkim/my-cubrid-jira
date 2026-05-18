# [OOS] transform_cl.c 의 VOT 오프셋 4-byte 정렬

## Issue Triage

**이슈 수행 목적**: `transform_cl.c` (클라이언트 측 recdes 생성 경로) 가 만드는 VOT(Variable Offset Table) 엔트리를 항상 4-byte 정렬된 오프셋으로 기록한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: VOT 엔트리의 하위 2비트는 `OR_VAR_BIT_OOS` / `OR_VAR_BIT_LAST_ELEMENT` flag 로 reserved 되어 있어 오프셋 자체는 4의 배수여야 한다. 사용자 데이터 레코드 경로는 정렬을 보장하지만, `transform_cl.c` 의 메타클래스/카탈로그 직렬화기는 그렇지 않아 홀수 오프셋이 발생할 수 있다.
- **영향**: 홀수 오프셋의 bit 0 이 `OR_VAR_BIT_OOS` 위치라 카탈로그 레코드를 OOS 로 오탐(false positive) 한다. 작성자 환경에서 `createdb demodb en_US` 직후 debug 빌드의 `[OOS-CONSISTENCY] MISMATCH` 가 6건 관측됨.

**이슈 수행 방안**:

- `transform_cl.c` 의 `*_to_disk` / `*_size` 함수에서 `or_put_offset()` 직전, size 누적 직전에 `DB_ALIGN(offset, INT_ALIGNMENT)` 적용.
- `put_attributes()` 의 가변 컬럼 사이에 `or_put_align32()` 로 4-byte boundary 패딩.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 보조 자료입니다.

### 배경

OOS 도입 이후 VOT 엔트리는 하위 2비트가 flag 로 reserved 되었다.

- `bit 0` = `OR_VAR_BIT_OOS`
- `bit 1` = `OR_VAR_BIT_LAST_ELEMENT`

`OR_GET_VAR_OFFSET(v) == (v & ~OR_VAR_FLAG_MASK)` 이 마스킹을 수행하므로 VOT 에 기록되는 오프셋 자체가 4의 배수가 아니면 (1) 1-3바이트만큼 read offset 이 어긋나고, (2) 홀수 오프셋의 bit 0 이 OOS flag 로 잘못 해석된다.

### Test Build

debug 빌드 성공. `createdb demodb en_US` 직후 `[OOS-CONSISTENCY] MISMATCH` 가 6건 -> 0건.

## Remarks

- `heap_file.c::heap_recdes_check_has_oos()` 가 같은 파일의 `heap_recdes_contains_oos()` (헤더 flag 비트를 읽는 hot-path 함수) 와 이름이 거의 같아서 역할 구분이 안 됐다. 이 함수는 update 시점에 VOT 를 스캔해서 그 flag 값을 *결정* 하는 함수라 `heap_recdes_compute_oos_flag()` 로 rename.
- 관련 PR: CUBRID/cubrid#7162
- 원본 PR: CUBRID/cubrid#6986 (vimkim:oos-vacuum)
- 관련 epic: CBRD-26583 (OOS M2)
