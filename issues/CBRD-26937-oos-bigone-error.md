# [OOS] heap 레코드의 overflow(bigone) 저장을 금지하고 OOS 로 일원화

## Issue Triage

**이슈 수행 목적**: heap 레코드의 외부 저장 수단을 OOS (Out-of-row Storage — 큰 가변 컬럼 하나를 외부 파일로 분리하는 컬럼 단위 방식) 로 일원화한다. 레코드 통째를 overflow 파일로 내보내는 `REC_BIGONE` (레코드 단위 방식) 은 heap 에서 더는 만들지 않으며, OOS demotion 후에도 레코드가 슬롯 한도를 넘으면 INSERT/UPDATE 를 사용자 에러로 거부한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: heap 은 외부 저장 수단을 두 개 — 컬럼 단위 OOS 와 레코드 단위 `REC_BIGONE` overflow — 동시에 가진다. demotion (`heap_attrinfo_determine_disk_layout`) 이 가변 컬럼을 OOS 로 내보내도 레코드가 슬롯 한도 `heap_Maxslotted_reclength` (`spage_max_record_size()` − `HEAP_HDR_STATS` 크기, 16KB 페이지에서 약 16KB — 한 레코드가 단일 slotted page 에 들어가는 최대 길이) 를 넘으면 `heap_insert_handle_multipage_record` 가 그대로 `REC_BIGONE` 으로 빼낸다.
- **영향**: 설계 의도 훼손 + 데이터 유실 위험. 두 수단이 한 레코드에 공존하면 vacuum 의 `REC_BIGONE` 경로가 overflow 체인만 지우고 그 레코드가 가리키던 OOS 청크는 회수하지 않아 조용히 유실된다 (CBRD-26668 주석에 명시). 현재 이를 막는 코드는 임시 `abort()` (heap_file.c:21466, :21685) 뿐이라 release 서버를 통째로 죽인다.

**이슈 수행 방안**:

- demotion 직후 레코드가 `heap_Maxslotted_reclength` 를 넘으면 `heap_attrinfo_transform_to_disk_internal` 에서 신규 에러 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거부한다. 게이트를 OOS 청크 기록 (`heap_attrinfo_insert_to_oos`) 전에 두어 orphan OOS 레코드를 만들지 않는다.
- 이전 초안의 `has_oos` 조건을 제거한다 — OOS 대상 컬럼이 없어 demotion 할 게 없는 레코드 (큰 고정 컬럼 등) 도 overflow 로 새지 않도록 막는 것이 일원화의 핵심이다. 사용자 인용: "forbid all cases that a heap record goes to overflow page".
- CBRD-26668 의 임시 `abort()` 두 곳을 위 정식 에러 반환으로 대체한다.
- 비 MVCC (카탈로그/root) heap 레코드의 overflow 처리, 그리고 기존 `REC_BIGONE` read/vacuum/recovery 코드의 제거 시점: `TBD - ANALYSIS 단계에서 결정` (아래 Open Questions).

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/heap_file.c` 의 INSERT/UPDATE 공통 경로에 거부 게이트 1 개 + 임시 `abort()` 2 곳 제거, 신규 에러 코드 1 개 (+ en/ko 메시지). 사용자 SQL 문법·시스템 카탈로그·wire protocol 은 불변이나, demotion 후에도 슬롯 한도를 넘는 레코드는 이제 성공(REC_BIGONE) 대신 에러로 끝나는 **동작 변경** 이 있다 — OOS 컬럼이 없는 대형 고정 컬럼 레코드 포함. base 브랜치 `feat/oos` 가 develop 머지 전이라 기존 데이터 마이그레이션 부담은 없다.

---

## Description

heap 은 한 레코드가 페이지에 안 들어갈 때를 대비해 외부 저장 수단을 둔다. 그런데 OOS 도입 이후 그 수단이 두 개가 됐다.

| 수단 | 단위 | 무엇을 외부로 빼는가 | 비고 |
|------|------|----------------------|------|
| OOS | 컬럼 | 큰 가변 컬럼 하나씩 외부 파일로, 인라인엔 16B 토큰(OID 8B + length 8B) 만 남김 | 신규 |
| `REC_BIGONE` overflow | 레코드 | 레코드 전체를 overflow 파일로, home 슬롯엔 forwarding OID 만 남김 | 기존 |

이 둘을 동시에 유지하는 것이 문제다. 둘은 서로의 존재를 모르고 설계됐는데, 한 레코드에서 만나면 vacuum 이 어긋난다. vacuum 의 `REC_BIGONE` 경로는 forwarding OID 가 가리키는 overflow 체인만 지우므로, 그 레코드 본문이 들고 있던 OOS 청크는 아무도 회수하지 않고 외부 파일에 남는다 (조용한 유실). CBRD-26668 작업자가 이를 발견하고 임시 방어선을 깔아 둔 상태다.

```c
/* heap_file.c:21466 (insert) / :21685 (update) — CBRD-26668 임시 코드 */
if (is_mvcc_class && heap_is_big_length (record_size))
  {
    if (has_oos)
      {
        /* ... REVERT BEFORE MERGE ... */
        fprintf (stderr, "HEAP ABORT (OOS+REC_BIGONE insert): record_size=%d\n", record_size);
        abort ();          /* ★ release 서버까지 통째로 죽인다 */
      }
    HEAP_MVCC_SET_HEADER_MAXIMUM_SIZE (&mvcc_rec_header);
  }
```

근본 해법은 방어선을 다듬는 게 아니라 수단을 하나로 합치는 것이다. heap 레코드의 외부 저장은 OOS 한 가지로 하고, `REC_BIGONE` 은 heap 에서 새로 만들지 않는다. 그러면 "두 수단의 상호작용" 이라는 버그 부류 자체가 사라지고, vacuum·recovery·scan 각각에 깔린 `REC_BIGONE` 분기를 유지할 이유도 없어진다.

남는 질문은 하나다. demotion 을 다 해도 레코드가 슬롯 한도 아래로 안 내려가면 어떻게 하나. OOS 대상은 가변 컬럼이면서 값이 인라인 토큰(16B) 보다 큰 것뿐이라, 큰 고정 길이 컬럼(`BIT(n)` 등) 이나 OOS 대상이 아닌 컬럼이 많으면 다 내보내도 한도 위에 남을 수 있다. 예전에는 이런 레코드가 `REC_BIGONE` 으로 빠졌다. 일원화 이후엔 빠질 곳이 없으므로 — 이것이 사용자가 줄여야 할 입력이다 — 결정론적 사용자 에러로 거부한다.

쓰기 경로를 보면 demotion 과 bigone 전환 사이에 게이트가 비어 있다. 그 자리에 거부를 넣는다.

```
INSERT / UPDATE
 heap_attrinfo_transform_to_disk_internal()                 heap_file.c:13008
   └ heap_attrinfo_determine_disk_layout()                  :12183
        가장 큰 가변 컬럼부터 OOS 로 demotion (목표: <= DB_PAGESIZE/4)
   expected_size 확정 (MVCC 최대 헤더 포함)                  :13060
   ★ 신규 게이트: heap_is_big_length(expected_size) → 거부   (이 자리, OOS 기록 전)
   └ heap_attrinfo_insert_to_oos()                          :13062   OOS 파일에 실제 기록
 ...
 heap_insert_handle_multipage_record()                      :21724
   ★ heap_is_big_length(length) → REC_BIGONE 전환            (일원화 후 heap 에선 도달 불가)
```

> **요지**: `REC_BIGONE` 자체가 잘못된 타입은 아니나, OOS 와 함께 heap 레코드의 외부 저장을 이중으로 떠받치는 것이 유지보수 부담이자 유실 버그의 진원이다. 외부 저장을 OOS 로 일원화하면 heap 의 `REC_BIGONE` 생성 경로는 자연히 닫히고, demotion 으로도 못 줄이는 레코드만 사용자 에러로 남는다.

거부 임계값은 demotion 목표치 `DB_PAGESIZE/4` (16KB 페이지에서 4KB — demotion 을 시작하는 트리거이지 한도가 아님) 가 아니라 bigone 전환과 같은 `heap_Maxslotted_reclength` (약 16KB) 다. 그래야 demotion 후 4~16KB 로 정상 저장되던 레코드가 회귀 없이 그대로 들어간다.

기존에 `ER_HEAP_OVERPASS_MAXOBJ_SIZE` (-54) 라는 유사 에러가 정의돼 있으나 어디서도 쓰이지 않고 메시지가 "Internal error … pages" 톤이라 사용자 노출용으로 부적합하다. 그래서 의미가 평행한 신규 코드를 별도로 둔다.

## Specification Changes

사용자 SQL 문법, 시스템 카탈로그, wire protocol 변경 없음. 신규 에러 코드 1 개를 추가하며, demotion 후에도 레코드 크기가 슬롯 한도를 넘으면 INSERT/UPDATE 가 아래 메시지로 거부된다 (이전엔 `REC_BIGONE` 으로 성공하던 경우 포함 — 동작 변경).

| 항목 | 값 |
|------|-----|
| 에러 코드 | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` |
| 인자 | `%1` = demotion 후 추정 레코드 크기 (bytes), `%2` = `heap_Maxslotted_reclength` (bytes) |
| 메시지 (en) | The record cannot be stored: its size (%1$d bytes) exceeds the maximum heap record size (%2$d bytes) even after large variable-length columns were moved to out-of-row storage (OOS). Heap records are not stored in overflow pages; reduce the size of fixed-length or non-OOS-eligible columns. |
| 메시지 (ko) | 레코드 크기(%1$d 바이트)가 최대 heap 레코드 크기(%2$d 바이트)를 초과하여 저장할 수 없습니다. 큰 가변 길이 컬럼은 이미 out-of-row 저장소(OOS)로 분리되었습니다. heap 레코드는 overflow 페이지에 저장되지 않으므로, 고정 길이 컬럼이나 OOS 대상이 아닌 컬럼의 크기를 줄이십시오. |

## Implementation

### 거부 게이트

거부 검사는 insert/update 공통 진입점인 `heap_attrinfo_transform_to_disk_internal` 에 둔다. 이 함수는 `heap_attrinfo_transform_to_disk` 와 `heap_attrinfo_transform_to_disk_excludelob` 양쪽이 호출하는 단일 choke point 라, 한 곳만 막으면 INSERT 와 UPDATE 가 모두 커버된다. 위치는 `expected_size` 가 MVCC 최대 헤더까지 더해 확정된 직후 (`heap_file.c:13060`) 이면서 OOS 청크를 실제로 쓰기 전 (`:13062`) 이라, 거부 시 버려질 orphan OOS 레코드를 애초에 만들지 않는다.

```c
  /* heap_file.c:13060 직후, has_oos 분기(:13062) 직전 */
  if (is_mvcc_class && heap_is_big_length ((int) expected_size))
    {
      /* External storage for heap records is unified on OOS (column unit). REC_BIGONE (record unit)
       * is no longer produced for heap. If the record still exceeds the max slotted length after every
       * OOS-eligible column was demoted, it cannot be stored -- reject with a user-visible error here,
       * before writing any OOS chunk, instead of spilling to an overflow page. */
      er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE, 2, (int) expected_size,
	      heap_Maxslotted_reclength);
      return S_ERROR;
    }
```

이 게이트가 나중의 bigone 판정과 같은 레코드를 거른다. `expected_size` 가 곧 최종 빌드 레코드 길이이기 때문이다 — MVCC 최대 헤더 + VOT (variable offset table, 가변 컬럼 오프셋 표) + bound bit (고정 컬럼 NULL 비트) + demotion 후 남은 페이로드 + 컬럼당 16B OOS 토큰. demotion 은 빠진 컬럼 값을 16B 토큰으로 치환할 뿐이므로, 뒤에서 bigone 을 판정하는 `heap_insert_handle_multipage_record` 가 보는 길이와 동일하다.

이전 초안과의 차이는 `has_oos` 조건을 뗀 것이다. 일원화의 목적이 "heap 레코드가 overflow 로 빠지는 모든 경우" 를 없애는 것이라, OOS 대상이 없어 demotion 자체가 일어나지 않은 레코드도 한도를 넘으면 동일하게 거부해야 한다.

### 임시 abort 제거

CBRD-26668 의 임시 `abort()` 두 곳 (`heap_file.c:21466` insert, `:21685` update) 을 제거한다. 위 게이트가 OOS 기록 전에 이미 같은 레코드를 거부하므로, 이 자리(헤더 조정 단계)는 `is_mvcc_class && heap_is_big_length` 일 때 `HEAP_MVCC_SET_HEADER_MAXIMUM_SIZE` 만 수행하는 기존 형태로 되돌린다.

### 수정 파일

| 파일 | 변경 |
|------|------|
| `src/storage/heap_file.c` | `heap_attrinfo_transform_to_disk_internal` 거부 게이트 추가; insert/update 헤더 조정의 임시 `abort()` 제거 |
| `src/base/error_code.h` | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 추가 (다음 빈 슬롯), `ER_LAST_ERROR` 갱신 |
| `msg/en_US.utf8/cubrid.msg` | `$set 5` 에 신규 메시지 추가 |
| `msg/ko_KR.utf8/cubrid.msg` | 동일 |
| `unit_tests/oos/sql/` | SA_MODE SQL 단위 테스트 (아래) |

에러 코드는 서버 내부에서 코드 + 메시지로 전파되므로 `dbi_compat.h` 와 CCI `base_error_code.h` 는 건드리지 않는다 (CCI 가 심볼로 식별할 필요 없음).

### 테스트

`unit_tests/oos/sql/` 의 기존 gtest 하네스 (SA_MODE 에서 실제 SQL 실행) 를 따른다. 큰 고정 컬럼은 `BIT(n)` 으로 만든다 — `BIT` 는 `BIT VARYING` 과 달리 가변이 아니어서 OOS 로 demotion 되지 않으므로, 옆에 OOS 컬럼을 둬도 인라인 레코드를 크게 유지한다.

| 테스트 | 시나리오 | 기대 |
|--------|----------|------|
| `OosColumnWithBigoneRejected` | 대형 고정 `BIT(n)` + OOS `VARCHAR`, demotion 후 잔여 >16KB 인 INSERT | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`, 행 미저장 (`COUNT = 0`) |
| `NoOosColumnBigoneRejected` | OOS 대상 없는 대형 고정 `BIT(n)` 단독, >16KB INSERT | `has_oos` 제거 검증 — 동일하게 거부 (이전 초안에선 성공하던 케이스) |
| `UpdateIntoBigoneRejected` | 작은 값으로 insert 성공 후, UPDATE 로 >16KB 가 되게 변경 | UPDATE 거부, 행 불변 |
| `InlineUnderLimitSucceeds` | demotion 후 4~16KB 로 남는 OOS 레코드 | 정상 insert. 16KB 임계값 선택을 못박는 회귀 가드 |

`feat/oos` 머지 후 `REC_BIGONE` 으로 새 heap 레코드가 만들어지지 않는지 확인하는 음성 테스트 (negative test) 도 포함한다.

## Open Questions

1. **비 MVCC heap 레코드**: OOS demotion 은 MVCC 사용자 클래스에만 적용된다. 카탈로그/root 클래스 (`mvcc_is_mvcc_disabled_class`) 의 대형 레코드가 `REC_BIGONE` 으로 빠지는 경로를 같이 막을지, 별도로 둘지 결정 필요. 게이트가 `is_mvcc_class` 안에 있어 현재 범위는 MVCC 클래스로 한정된다.
2. **기존 `REC_BIGONE` 코드 제거 시점**: read/vacuum/recovery/update/delete 에 깔린 `REC_BIGONE` 분기를 이 이슈에서 dead-path 로 정리할지, 후속 정리 이슈로 분리할지. 일원화 직후엔 신규 생성만 막고 읽기 호환 코드는 남겨 두는 편이 안전하다.

## Acceptance Criteria

- [ ] demotion 후에도 레코드가 `heap_Maxslotted_reclength` 를 넘으면 INSERT 가 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거부된다 (`OosColumnWithBigoneRejected`)
- [ ] OOS 대상 컬럼이 없어도 한도를 넘으면 동일하게 거부된다 — `has_oos` 무관 (`NoOosColumnBigoneRejected`)
- [ ] UPDATE 로 한도를 넘기는 경우도 거부되고 행이 불변이다 (`UpdateIntoBigoneRejected`)
- [ ] demotion 후 4~16KB 로 남는 레코드는 기존대로 정상 insert 된다 — 회귀 없음 (`InlineUnderLimitSucceeds`)
- [ ] 거부 시 OOS 청크가 기록되지 않는다 (게이트가 `heap_attrinfo_insert_to_oos` 앞)
- [ ] CBRD-26668 의 임시 `abort()` 두 곳이 제거되고 release 빌드에서 크래시 없이 에러만 반환된다
- [ ] `feat/oos` 에서 신규 heap `REC_BIGONE` 이 생성되지 않는다 (음성 테스트)

## Definition of done

- [ ] 위 Acceptance Criteria 전 항목 통과
- [ ] CI 파이프라인 (check, test, build) 통과
- [ ] Open Questions 1, 2 의 결론을 이슈/PR 에 기록
- [ ] QA 매뉴얼에 "heap 레코드 overflow 금지 + 대형 레코드 거부" 케이스 반영

---

## 참고 코드

- `src/storage/heap_file.c:13008` — `heap_attrinfo_transform_to_disk_internal` (거부 게이트 삽입 지점)
- `src/storage/heap_file.c:13045` / `:13060` — `expected_size` 산출 / MVCC 최대 헤더 가산 (게이트는 `:13060` 직후)
- `src/storage/heap_file.c:13062` — `heap_attrinfo_insert_to_oos` 호출 (OOS 청크 기록, 게이트는 이 앞)
- `src/storage/heap_file.c:12183` — `heap_attrinfo_determine_disk_layout` (OOS demotion, `DB_PAGESIZE/4` 목표)
- `src/storage/heap_file.c:1351` — `heap_is_big_length` / `:5156` — `heap_Maxslotted_reclength` 계산
- `src/storage/heap_file.c:21466` / `:21685` — CBRD-26668 임시 `abort()` (제거 대상)
- `src/storage/heap_file.c:21724` — `heap_insert_handle_multipage_record` (`REC_BIGONE` 전환, 일원화 후 heap 도달 불가)

## Remarks

- 부모: CBRD-26583 ([OOS] [EPIC] [M2]). 관련: CBRD-26668 (vacuum-OOS 통합, 임시 abort 의 출처), CBRD-26637 (OOS 에러 핸들링 `er_set` + `ASSERT_ERROR` 통합).
- PR: [#7298](https://github.com/CUBRID/cubrid/pull/7298) (base `feat/oos`) — 이전 `has_oos` 게이트 버전이라 새 개념(일원화, `has_oos` 제거)으로 갱신 필요.
- 개념 전환: 외부 저장을 OOS(컬럼 단위) 로 일원화하고 overflow(레코드 단위) 를 heap 에서 폐지 — 두 수단 병행이 유지보수 부담이자 유실 버그의 원인이라는 판단에 따른다.
