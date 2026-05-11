# [OOS] transform_cl.c / catalog_class.c 의 VOT 오프셋 4-byte 정렬 누락 수정

## Issue Triage

**이슈 수행 목적**: 카탈로그/메타클래스 직렬화기가 만드는 VOT(Variable Offset Table) 엔트리가 항상 4-byte 정렬된 오프셋만 담도록 보정하여, `OR_GET_VAR_OFFSET()` 마스킹 손실과 OOS 오탐을 제거한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `OR_GET_VAR_OFFSET()` 는 VOT 엔트리의 하위 2비트(`OR_VAR_BIT_OOS`, `OR_VAR_BIT_LAST_ELEMENT`) 를 마스킹해서 떼어 내므로, 모든 오프셋은 4의 배수여야 한다. 사용자 데이터 레코드(`heap_attrinfo_transform_*`) 는 이미 정렬된 오프셋을 만들지만, `transform_cl.c` 의 13개 메타클래스 직렬화기(`tf_class_size`, `domain_to_disk`, `attribute_to_disk`, `method_to_disk` 등)와 `catalog_class.c` 의 `catcls_put_or_value_into_buffer()` 는 `or_put_offset()` 직전에 정렬을 보장하지 않아 홀수 오프셋이 생성될 수 있다.
- **영향**: 홀수 오프셋의 하위 비트 0 이 `OR_VAR_BIT_OOS` 위치이므로 `heap_recdes_check_has_oos()` 가 OOS 가 아닌 카탈로그 레코드를 OOS 로 오탐(false positive)한다. `createdb` 직후 vacuum 경로에서 OOS-flag-vs-VOT-scan consistency mismatch 가 다수 발생(작성자 환경에서 6건 관측). 또한 마스킹된 1-3바이트만큼 가변 컬럼 영역의 read offset 이 어긋날 수 있어 데이터 영역 해석 오류로 이어질 위험이 있다.

**이슈 수행 방안**:

- `transform_cl.c` 의 모든 `*_to_disk` / `*_size` 함수에서 `or_put_offset()` 호출 직전, 그리고 size 함수의 각 가변 컬럼 size 누적 직전에 `DB_ALIGN(offset, 4)` 을 적용한다 (총 13개 메타클래스 직렬화기 + 대응 size 함수).
- `catalog_class.c::catcls_put_or_value_into_buffer()` 의 가변 컬럼 루프와 last-offset 기록 직전에 `or_pad()` 로 현재 buffer write 위치를 4-byte 경계까지 패딩한다.
- `heap_recdes_check_has_oos()` 에 1차 sanity check 를 추가하여, 첫 VOT 엔트리가 레코드 길이를 넘으면 false 를 반환한다 (class/root 레코드처럼 VOT 포맷이 아닌 레코드를 OOS 후보에서 조기 배제).
- `heap_recdes_contains_oos()` 의 diagnostic cross-validation 추가 작업은 본 이슈 범위 밖이며, 별도로 진행한다.
- 사용자 인용: "vimkim:oos-vacuum <- in this branch (#6986), there was an alignment bug in transform_cl.c so there was a fix for it. recdes 정렬은 이슈/PR 분리하는게 리뷰하기 용이"

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: 카탈로그/메타클래스 직렬화기가 만든 VOT 오프셋이 4-byte 정렬을 보장하지 않아 OOS 오탐 및 read offset 어긋남을 유발한다.
- **원인 / 배경**: VOT 엔트리의 하위 2비트가 flag 용으로 reserved 되어 있어 오프셋 자체는 항상 4의 배수여야 하지만, 메타클래스 직렬화기는 alignment 를 보장하지 않는다.
- **제안 / 변경**: 모든 `or_put_offset()` 호출 직전과 size 함수의 가변 컬럼 누적 직전에 `DB_ALIGN(.., 4)` 을 적용한다. `catcls_put_or_value_into_buffer()` 에는 `or_pad()` 로 동일한 정렬을 부여한다.
- **영향 범위**: `src/object/transform_cl.c` 13개 메타클래스 직렬화기 + size 함수, `src/storage/catalog_class.c::catcls_put_or_value_into_buffer()`, `src/storage/heap_file.c::heap_recdes_check_has_oos()` sanity check. 호환성은 디스크 포맷 자체의 alignment 가 이미 변경 가능했어야 하는 invariant 라 새 카탈로그 레코드는 약간 더 큰 패딩이 생기는 정도. 기존 카탈로그를 읽을 때는 `OR_GET_VAR_OFFSET()` 이 어차피 마스킹하므로 무해.

---

## Description

### 배경

CUBRID 의 record-on-page 포맷은 가변 컬럼 영역에 진입할 때 VOT(Variable Offset Table) 를 통해 각 가변 컬럼의 시작 오프셋을 인덱싱한다. OOS(Out-of-row Overflow Storage) 도입 이후 VOT 엔트리는 다음과 같이 하위 2비트가 flag 로 reserved 되었다.

- `bit 0` (`OR_VAR_BIT_OOS`): 해당 가변 컬럼이 OOS 외부 저장이라는 표시.
- `bit 1` (`OR_VAR_BIT_LAST_ELEMENT`): VOT 의 마지막 엔트리라는 sentinel.

따라서 `OR_GET_VAR_OFFSET(v) == (v & ~OR_VAR_FLAG_MASK)` 는 항상 하위 2비트를 떼어 낸다. 즉, **VOT 에 기록되는 오프셋 값 자체는 항상 4-byte 정렬이어야 한다.** 그렇지 않으면 (1) 오프셋 정보가 1-3바이트 손실되어 가변 컬럼 read 가 어긋나거나, (2) 짝수가 아닌 오프셋의 하위 비트 0 이 `OR_VAR_BIT_OOS` 로 오탐된다.

### 발단

사용자 데이터 레코드를 만드는 `heap_attrinfo_transform_*` 경로는 가변 컬럼마다 `DB_ALIGN(_, 4)` 로 padding 을 넣어 정렬된 오프셋을 만들어 왔다. 그러나 카탈로그/메타클래스 직렬화기는 다음 패턴으로 정렬 없이 오프셋을 그대로 기록한다.

```c
/* transform_cl.c — domain_to_disk(), method_to_disk(), attribute_to_disk(), ... */
offset = tf_Metaclass_X.mc_fixed_size + OR_VAR_TABLE_SIZE (tf_Metaclass_X.mc_n_variable);
or_put_offset (buf, offset);
offset += string_disk_size (X->name);   /* string_disk_size 는 가변 길이라 정렬 보장 X */
or_put_offset (buf, offset);
offset += substructure_set_size (...);
or_put_offset (buf, offset);
...
or_put_last_var_offset (buf, offset);
```

`string_disk_size()`, `or_packed_value_size()`, `substructure_set_size()`, `property_list_size()`, `object_set_size()` 등은 *각 컬럼의 실제 disk size* 를 반환하는 함수라 4 의 배수가 아닐 수 있다. 결과적으로 두 번째 이후의 VOT 오프셋이 홀수가 될 수 있다.

`catalog_class.c::catcls_put_or_value_into_buffer()` 도 동일하다. variable column 을 차례로 packing 하며 `buf_p->ptr - buf_p->buffer - header_size` 를 다음 오프셋으로 기록하지만 packing 직전·직후에 4-byte 정렬을 강제하지 않는다.

### 관측된 영향

`createdb` 직후 `cub_vacuum` 또는 일반 vacuum 경로에서 `heap_recdes_check_has_oos()` 가 카탈로그 레코드를 OOS 로 오탐하면서 OOS-flag 와 VOT-scan 결과의 cross-validation 이 mismatch 한다. 작성자 환경 기준으로 `[OOS-CONSISTENCY] MISMATCH` 가 6 건 출력된다. 본 패치 적용 후 0 건으로 떨어지는 것을 확인했다.

---

## Test Build

작성자 로컬 (gcc, Linux, debug build, `./build.sh -m debug`) 기준 빌드 성공. `createdb` 직후 OOS consistency mismatch 6 -> 0 으로 감소.

## Repro

본 이슈에 직접 대응되는 user-visible failure 는 없고, debug 빌드의 stderr 진단 메시지로만 관측된다.

```sh
./build.sh -m debug
# cubrid env 가 활성화된 상태에서
createdb demodb en_US
# (debug build 의 cub_vacuum / cub_server stderr 에서 [OOS-CONSISTENCY] MISMATCH 출력 관측)
```

## Expected Result

debug 빌드 stderr 에 `[OOS-CONSISTENCY] MISMATCH` 가 출력되지 않는다. `heap_recdes_check_has_oos()` 가 카탈로그/root 레코드에 대해 항상 `false` 를 반환한다.

## Actual Result

본 패치 적용 전: `createdb demodb` 직후 `[OOS-CONSISTENCY] MISMATCH` 6 건 관측. 모두 메타클래스/카탈로그 레코드의 홀수 VOT 오프셋이 원인.

## Implementation

### 변경 1 — `transform_cl.c` 의 13개 메타클래스 직렬화기 및 size 함수

대상: `domain`, `metharg`, `methsig`, `method`, `methfile`, `query_spec`, `attribute`, `resolution`, `repattribute`, `representation`, `class`, `root`, `partition`.

각 `*_to_disk()` 함수에서 매 `or_put_offset()` / `or_put_last_var_offset()` 직전에 `offset = DB_ALIGN (offset, 4);` 를 삽입한다. 대응되는 `*_size()` 함수에서 매 가변 컬럼 size 가산 시 `DB_ALIGN (그 size, 4)` 로 감싼다. 또한 `put_varinfo()` 의 초기 offset 계산과 컬럼 size 누적, `put_attributes()` 의 가변 컬럼 writemem 사이 padding 까지 동일한 패턴으로 정렬한다.

### 변경 2 — `catalog_class.c::catcls_put_or_value_into_buffer()`

가변 컬럼 루프 진입 직전과 last-offset 기록 직전에 `buf_p->ptr - buf_p->buffer - header_size` 를 4-byte 경계까지 `or_pad()` 한다.

```c
{
  int current = (int) (buf_p->ptr - buf_p->buffer - header_size);
  int aligned = DB_ALIGN (current, 4);
  if (aligned > current)
    {
      or_pad (buf_p, aligned - current);
    }
}
```

### 변경 3 — `heap_file.c::heap_recdes_check_has_oos()` 의 sanity check

class/root 레코드처럼 VOT 포맷이 아닌 레코드를 VOT 로 해석하면 garbage 가 흘러나오므로, 첫 VOT 엔트리의 cleaned offset(`first & ~OR_VAR_FLAG_MASK`) 이 레코드 길이를 초과하면 `false` 로 조기 반환한다.

## Acceptance Criteria

- [ ] `transform_cl.c` 의 13개 메타클래스 `*_to_disk()` 와 대응 `*_size()` 함수가 모두 4-byte 정렬된 VOT 오프셋만 생성한다.
- [ ] `catcls_put_or_value_into_buffer()` 가 4-byte 정렬된 VOT 오프셋만 생성한다.
- [ ] `heap_recdes_check_has_oos()` 가 첫 VOT 엔트리가 레코드 길이를 넘는 레코드에 대해 항상 `false` 를 반환한다.
- [ ] debug 빌드에서 `createdb demodb en_US` 직후 `[OOS-CONSISTENCY] MISMATCH` 진단 출력이 0 건이다.
- [ ] 기존 카탈로그 디스크 포맷 호환성 회귀 없음 (변경은 새로 기록되는 레코드의 padding 만 늘림).

## Definition of done

- [ ] 위 A/C 충족
- [ ] CI(SQL/shell/medium) 통과
- [ ] OOS unit test 회귀 없음

## Additional Information

- 본 이슈는 PR #6986 (vimkim:oos-vacuum 브랜치) 의 review 피드백에 따라 alignment 부분만 분리한 후속 작업이다.
- `heap_recdes_contains_oos()` 의 cross-validation 진단 강화는 본 이슈와 무관한 OOS-debug 작업이라 분리한다.

## Remarks

- 관련 PR: TBD (이 이슈와 함께 생성 예정)
- 관련 epic: CBRD-26583 (OOS M2)
- 원본 PR: CUBRID/cubrid#6986
