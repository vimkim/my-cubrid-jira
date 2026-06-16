# [OOS] bigone + OOS 공존 시 사용자 에러로 거부

## Issue Triage

**이슈 수행 목적**: OOS (Out-of-row Storage -- heap 의 큰 가변 컬럼을 외부 OOS 파일로 분리해 저장하는 방식) 컬럼을 가진 레코드가 bigone (한 레코드가 heap 페이지에 안 들어가 통째로 overflow 파일에 저장되는 `REC_BIGONE` 타입) 으로 빠지는 조합을, 레코드를 디스크 포맷으로 만들기 전에 사용자 에러로 거부한다. OOS + bigone 공존을 완전히 차단한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `heap_attrinfo_determine_disk_layout` (`heap_file.c:12098`) 가 가장 큰 가변 컬럼부터 하나씩 OOS 로 내보내 레코드를 `DB_PAGESIZE/4` (16KB 페이지 기준 4KB) 이하로 맞추려 한다. 그런데 못 맞춰도 에러 없이 그대로 반환한다. 이후 `heap_insert_handle_multipage_record` (`heap_file.c:21544`) 에서 레코드 길이가 `heap_Maxslotted_reclength` (= `spage_max_record_size() - HEAP_MAX_FIRSTSLOTID_LENGTH`, 16KB 페이지 기준 약 16KB) 를 넘으면 `heap_is_big_length()` 가 참이 되어 `REC_BIGONE` overflow 레코드로 저장된다. 이때 MVCC 헤더의 `OR_MVCC_FLAG_HAS_OOS` 플래그는 그대로 전파되므로, OOS OID 를 품은 채 overflow 레코드가 되는 조합이 조용히 만들어진다.
- **영향**: 설계 의도 훼손. 이 조합을 쓰기 시점에 막는 코드가 없다. read 경로에 사후 진단 `assert` (`heap_file.c:27571`, `27584`, `27597` 등) 가 있으나 모두 레코드가 이미 만들어진 뒤에 걸리고, release 빌드 (`NDEBUG`) 에선 plain `assert` 는 컴파일 제거되며 `assert_release` (`heap_file.c:27544`, `27561`) 는 로그만 남기고 멈추지 않는다. 따라서 사용자는 깨끗한 에러 대신 잘못된 결과나 크래시를 본다. OOS resolve (OOS OID 를 실제 값으로 복원) 와 overflow read 가 동시에 얽히는, 검증되지 않은 경로다.

**이슈 수행 방안**:

- `heap_attrinfo_transform_to_disk_internal` 에서 demotion 직후, OOS 레코드를 실제로 OOS 파일에 쓰기 (`heap_attrinfo_insert_to_oos`) 전에 `has_oos && heap_is_big_length ((int) expected_size)` 를 검사한다. 참이면 `er_set` 으로 신규 에러 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 를 올리고 `S_ERROR` 를 반환한다.
- 거부 임계값은 bigone 임계값 `heap_Maxslotted_reclength` (약 16KB) 다. 사용자 인용: "bigone 임계값 ~16KB". `DB_PAGESIZE/4` (4KB) 가 아니라 16KB 를 쓰므로, OOS 컬럼을 가지면서 4~16KB 로 남는 정상 레코드 (예: 큰 고정 길이 CHAR 컬럼 + OOS 로 빠진 varchar) 는 기존대로 정상 insert 된다 -- 회귀 없음.
- 신규 에러 코드 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` (-1375) 를 `error_code.h` 와 en/ko `cubrid.msg` 에 추가한다. 이 에러는 코드 + 메시지 문자열로 클라이언트에 전파되며 CCI 가 심볼로 식별할 필요가 없으므로, `dbi_compat.h` 와 CCI `base_error_code.h` 는 수정하지 않는다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: OOS OID 를 품은 레코드가 overflow (`REC_BIGONE`) 로 저장되는 조합을 빌드 전에 차단한다.
- **원인 / 배경**: demotion 이 `DB_PAGESIZE/4` 목표를 못 맞춰도 막지 않고, 이후 overflow 경로가 `OR_MVCC_FLAG_HAS_OOS` 를 그대로 전파한다.
- **제안 / 변경**: demotion 직후 `has_oos && heap_is_big_length()` 검사 + 신규 사용자 에러.
- **영향 범위**: `src/storage/heap_file.c` insert/update 공통 경로, 신규 에러 코드 1 개. 사용자 SQL 시맨틱과 wire protocol 변경 없음. 정상 OOS 레코드 (< 16KB) 동작 불변.

---

## Description

OOS 는 큰 가변 컬럼을 heap 레코드에서 분리해 OOS 파일로 보내, heap 레코드를 작게 유지하는 기능이다. demotion 로직 (`heap_attrinfo_determine_disk_layout`) 은 레코드가 `DB_PAGESIZE/4` 를 넘으면 가장 큰 가변 컬럼부터 OOS 로 내보내고, `DB_PAGESIZE/4` 이하가 되면 멈춘다.

문제는 demotion 으로도 `DB_PAGESIZE/4` 이하로 못 줄이는 경우다. OOS 대상은 가변 컬럼이면서 값이 `OR_OOS_INLINE_SIZE` (인라인 OOS 토큰 = OID 8B + length 8B = 16B) 보다 큰 것뿐이다. 따라서 고정 길이 컬럼 (CHAR 등) 이 크거나, 16B 이하 작은 가변 컬럼이 많으면 demotion 을 다 해도 레코드가 임계값 위에 남는다. 이 레코드가 `heap_Maxslotted_reclength` 까지 넘으면 overflow (`REC_BIGONE`) 로 저장되는데, `OR_MVCC_FLAG_HAS_OOS` 플래그가 살아 있어 OOS + bigone 이 공존한다.

이 이슈는 레코드를 디스크 포맷으로 빌드하기 전에 이 조합을 감지해, 결정론적이고 사용자에게 보이는 에러로 거부한다. read 경로 assert 의 release 동작 한계는 위 Issue Triage 의 영향 항목에 정리돼 있다.

`REC_BIGONE` 자체는 OOS 와 무관하게 정상 지원되는 타입이다 (OOS 컬럼이 없는 큰 레코드). 따라서 이 거부는 `has_oos` 가 참인 경우에만 적용하고, OOS 없는 일반 bigone 은 건드리지 않는다.

기존에 `ER_HEAP_OVERPASS_MAXOBJ_SIZE` (-54) 라는 유사 에러가 정의돼 있으나 (1) 어디서도 사용되지 않고 (2) 메시지가 "Internal error ... pages" 톤이라 사용자 노출용으로 부적합하다. 그래서 의미가 평행한 신규 코드 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 를 별도로 둔다.

## Specification Changes

사용자 SQL 시맨틱, 시스템 카탈로그, wire protocol 변경 없음.

신규 에러 코드 1 개 추가. 사용자는 OOS 컬럼을 가진 레코드가 demotion 후에도 최대 레코드 크기를 넘으면 아래 메시지를 받고 insert/update 가 거부된다.

| 항목 | 값 |
|------|-----|
| 에러 코드 | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` = -1375 |
| 메시지 (en) | The record cannot be stored because its size (%1$d bytes) still exceeds the maximum record size (%2$d bytes) even after moving large variable-length columns to out-of-row storage (OOS). Reduce the size of fixed-length or non-eligible columns. |
| 메시지 (ko) | 큰 가변 길이 컬럼을 out-of-row 저장소(OOS)로 옮긴 후에도 레코드 크기(%1$d 바이트)가 최대 레코드 크기(%2$d 바이트)를 초과하여 저장할 수 없습니다. 고정 길이 컬럼이나 OOS 대상이 아닌 컬럼의 크기를 줄이십시오. |
| 인자 | %1 = demotion 후 추정 레코드 크기, %2 = `heap_Maxslotted_reclength` |

`feat/oos` 가 develop 머지 전이므로 마이그레이션 부담은 없다. `ER_LAST_ERROR` 는 -1375 에서 -1376 으로 갱신한다.

## Implementation

거부 검사는 insert/update 공통 진입점인 `heap_attrinfo_transform_to_disk_internal` 에 둔다. 이 함수는 `heap_attrinfo_transform_to_disk` 와 `heap_attrinfo_transform_to_disk_excludelob` 양쪽에서 호출되는 단일 choke point 라, 한 곳만 막으면 insert 와 update 가 모두 커버된다.

검사 위치는 demotion 으로 크기/플래그가 확정된 직후이면서, OOS 레코드를 실제로 OOS 파일에 쓰기 전이다. 이렇게 해야 거부 시 버려질 orphan OOS 레코드를 애초에 만들지 않는다.

```
heap_attrinfo_transform_to_disk_internal()
  determine_disk_layout()            큰 가변 컬럼을 OOS 로 demotion, expected_size/has_oos 산출
  expected_size += MVCC 헤더 보정
  >> if (has_oos && heap_is_big_length(expected_size))   <- 신규 거부 게이트 (이 줄이 추가됨)
        er_set(ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE); return S_ERROR
  if (has_oos) heap_attrinfo_insert_to_oos()             OOS 파일에 실제 기록
  build record buffer (header + columns)
```

`expected_size` 는 demotion 직후 산출한 레코드 크기다. 최종 빌드 레코드와 같은 구성 요소 -- MVCC 최대 헤더 + VOT (variable offset table, 가변 컬럼의 오프셋을 담는 표) + bound bit (고정 컬럼의 NULL 여부 비트) + demotion 후 남은 페이로드 + 컬럼당 16B OOS 토큰 -- 로 계산된다. `heap_attrinfo_get_record_payload_size` 가 컬럼별 디스크 크기 (`tp_domain_disk_size` / `pr_data_writeval_disk_size`) 를 그대로 합산하고, demotion 은 빠진 컬럼 값을 16B 토큰으로 치환하므로, `expected_size` 는 bigone 판정 (`heap_insert_handle_multipage_record`) 이 참조하는 최종 레코드 길이와 같은 값이다. 따라서 demotion 지점의 이 검사 하나로 bigone 판정과 동일하게 걸러지며, OOS 레코드를 쓰기 전에 한 번만 검사하므로 거부 시 orphan OOS 레코드도 남지 않는다.

```c
  /* OOS + bigone coexistence is forbidden. heap_attrinfo_determine_disk_layout already demoted every
   * OOS-eligible variable column. If the inline record still exceeds the maximum slotted record length,
   * it would have to be stored as a multipage (REC_BIGONE) overflow record while also carrying OOS OIDs.
   * That combination is unsupported, so reject it here with a user-visible error -- before writing any OOS
   * record -- instead of silently building it and tripping debug-only asserts on the read path. */
  if (has_oos && heap_is_big_length ((int) expected_size))
    {
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE, 2, (int) expected_size,
	      heap_Maxslotted_reclength);
      return S_ERROR;
    }
```

수정 파일:

| 파일 | 변경 |
|------|------|
| `src/base/error_code.h` | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` (-1375) 추가, `ER_LAST_ERROR` -> -1376 |
| `msg/en_US.utf8/cubrid.msg` | `$set 5` 에 1375 메시지 추가, placeholder 1375 -> 1376 |
| `msg/ko_KR.utf8/cubrid.msg` | 동일 |
| `src/storage/heap_file.c` | `heap_attrinfo_transform_to_disk_internal` 에 거부 게이트 추가 |
| `unit_tests/oos/sql/test_oos_sql_bigone.cpp` | SA_MODE SQL 단위 테스트 3 종 (신규) |
| `unit_tests/oos/sql/CMakeLists.txt` | `test_oos_sql_bigone` 를 OOS_DB fixture 에 등록 |

### 테스트

`unit_tests/oos/sql/` 의 기존 gtest 하네스 (SA_MODE 에서 실제 SQL 실행) 를 따라 3 종을 추가했다. 큰 고정 컬럼은 `BIT(n)` 으로 만든다 -- `BIT` 는 `BIT VARYING` 과 달리 가변이 아니어서 OOS 로 demotion 되지 않으므로, 옆에 OOS 컬럼을 두어도 인라인 레코드를 크게 유지한다.

| 테스트 | 시나리오 | 기대 |
|--------|----------|------|
| `OosColumnWithBigoneRejected` | `BIT(140000)` (17500B 고정) + `VARCHAR` (OOS 로 demotion) | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 반환, 행 미저장 (`COUNT = 0`) |
| `BigoneWithoutOosColumnSucceeds` | `BIT(140000)` 단독 (OOS 컬럼 없음) | 일반 `REC_BIGONE` 으로 정상 insert (`has_oos` 게이트 미발동) |
| `OosColumnInlineBetween4kAnd16kSucceeds` | `BIT(100000)` (12500B 고정) + OOS `VARCHAR` | 인라인 잔여 ~12.5KB (`DB_PAGESIZE/4` 와 `heap_Maxslotted_reclength` 사이) -> 정상 insert. 16KB 임계값 선택을 못박는 회귀 가드 |
| `UpdateIntoOosBigoneRejected` | `b` 를 NULL 로 insert (일반 bigone, 성공) 후 `b` 를 1000B 로 UPDATE | UPDATE 가 `b` 를 OOS 로 demotion -> 잔여 >16KB -> `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 반환, 행 불변 (`b` 여전히 NULL). UPDATE 경로 커버 |

`ctest -R test_oos_sql_bigone` 로 4 종 모두 통과 확인 (debug_gcc 빌드).

## Acceptance Criteria

- [x] OOS 컬럼을 demotion 한 뒤에도 레코드가 `heap_Maxslotted_reclength` 를 넘으면 INSERT 가 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거부된다 (`OosColumnWithBigoneRejected`)
- [x] OOS 컬럼이 있으나 demotion 후 4~16KB 로 남는 레코드는 기존대로 정상 insert 된다 -- 회귀 없음 (`OosColumnInlineBetween4kAnd16kSucceeds`)
- [x] OOS 컬럼이 없는 일반 bigone (`REC_BIGONE`) 레코드는 영향받지 않는다 (`BigoneWithoutOosColumnSucceeds`)
- [x] 거부 시점에 행이 저장되지 않는다 (`COUNT = 0` 확인). 게이트가 `heap_attrinfo_insert_to_oos` 앞에 있어 orphan OOS 레코드는 구조적으로 생기지 않으나, OOS 파일 슬롯 수준 검증은 미수행
- [x] UPDATE 경로 거부 -- NULL 로 insert 후 OOS 값으로 UPDATE 시 거부, 행 불변 (`UpdateIntoOosBigoneRejected`)
- [ ] release 빌드 (`NDEBUG`) 런타임 -- 게이트에 `NDEBUG` 가드가 없어 release-safe 이지만 release 런타임 확인은 미수행

## Definition of done

- [ ] 위 Acceptance Criteria 전 항목 통과
- [ ] CI 파이프라인 (check, test, build) 통과
- [ ] QA 매뉴얼 테스트에 OOS + 대형 고정 컬럼 거부 케이스 반영

---

## Remarks

- 부모: CBRD-26583 ([OOS] [EPIC] [M2]).
- 관련: CBRD-26637 (OOS 에러 핸들링 `er_set` + `ASSERT_ERROR` 통합) 와 같은 방향의 후속 작업.
- 런타임 거부 동작은 `unit_tests/oos/sql/test_oos_sql_bigone.cpp` 의 SA_MODE 단위 테스트 4 종 (INSERT/UPDATE 거부 + 비-OOS bigone/중간 크기 OOS 회귀 가드) 으로 검증했다 (debug_gcc, `ctest` 통과). release 런타임과 CTP shell 시나리오는 CBRD-26659 에서 보강한다.

## 참고 코드

- `src/storage/heap_file.c:12098` -- `heap_attrinfo_determine_disk_layout` (OOS demotion, `DB_PAGESIZE/4` 목표)
- `src/storage/heap_file.c:12892` -- `heap_attrinfo_transform_to_disk_internal` (거부 게이트 삽입 지점)
- `src/storage/heap_file.c:1351` -- `heap_is_big_length` / `heap_file.c:5157` -- `heap_Maxslotted_reclength` 계산
- `src/storage/heap_file.c:21544` -- `heap_insert_handle_multipage_record` (`REC_BIGONE` 전환 지점)
