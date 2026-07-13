# [OOS] unloaddb raw record 값 보존 및 Compactdb OOS 연동 정리

## Issue Triage

**이슈 수행 목적**: `unloaddb` 와 Compactdb가 OOS-backed attribute를 각 소비 방식에 맞게 처리하도록 한다. 이미 반영된 raw fetch 수정의 소유권을 바로잡고, Compactdb의 남은 OOS 쓰기 및 처리 예산 문제를 분리한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `xlocator_fetch_all()` 의 Expand는 복구됐지만 검증이 남아 있다. standalone Compactdb는 Expand된 값을 정상 OOS Demotion 경로 없이 직접 갱신하며, server Compactdb는 OOS-aware attribute 계층을 사용하면서도 record 전체를 Expand한 길이로 처리 예산을 계산한다. |
| **TO-BE (목표 상태 / 기대 동작)** | raw `RECDES` 를 OOS-blind decoder로 보내는 경로만 Expand하고, attribute 계층은 OOS Resolve를 사용하며, 물리 compaction은 OOS inline stub을 보존한다. Compactdb가 record를 다시 쓸 때는 PG-style four-record heap target을 적용하는 정상 OOS Demotion 경로를 거친다. |
| **영향** | 설계 의도 훼손 및 export 장애. 회귀 상태에서는 `unloaddb` dump의 큰 값이 `X''` 로 빠졌고, 현재 standalone Compactdb의 강제 rewrite는 logical value를 inline 또는 `REC_BIGONE` 으로 되돌려 OOS 배치와 I/O 이점을 잃을 수 있다. Server mode에서는 expanded `obj->length > max_space_to_process` 인 OOS-backed row가 big object로 분류되어 건너뛰어질 수 있다. |

**이슈 수행 방안**:

- 현재 `xlocator_fetch_all()` Expand 동작을 CS/SA `unloaddb` E2E로 검증한다.
- standalone Compactdb의 read Expand는 유지하되, rewrite는 OOS-aware attribute transformation/Demotion 경로로 통합한다.
- server Compactdb는 stored-form record를 받고 `heap_attrinfo_read_dbvalues()` 에서 attribute별로 Resolve하도록 변경하는 방안을 검토한다. `space_to_process` 의 기준은 stored record length로 하는 것을 권장하나 최종 결정은 `TBD - 합의 미확인` 이다.
- `heap_compact_pages()` 의 물리 compaction은 OOS inline stub을 그대로 보존한다.
- Compactdb 잔여 구현을 별도 이슈로 분리할지 여부는 `TBD - 합의 미확인` 이다.

---

## AI-Generated Context

> 아래는 AI가 코드와 git 이력을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/transaction/locator_sr.c`, `src/loaddb/load_object.c`, `src/executables/compactdb.c`, `src/storage/compactdb_sr.c`, `src/storage/heap_file.c` 가 대상이다. 출시 전 `feat/oos` 동작이며 저장 형식 호환성 변경은 없다.
- **관련 작업**: CBRD-26458/PR #6766, CBRD-26729/PR #7093, CBRD-26818/PR #7337, CBRD-27029/PR #7416과 연결된다.

## Description

`OOS` (Out-of-row Overflow Storage)는 큰 가변 attribute 값을 별도 OOS value chain에 두고 heap record에는 16-byte OOS inline stub만 남긴다. stub은 8-byte head OOS OID와 8-byte full length로 구성된다.

CBRD-26729에서 record-level OOS Expand를 opt-in으로 바꾼 뒤, raw record 소비자가 Expand를 요청하지 않으면 OOS OID가 값처럼 노출될 수 있었다. `unloaddb` 의 `desc_disk_to_obj()` 는 raw object representation을 해석하지만 OOS inline stub을 알지 못한다. 회귀 상태에서 50,008-byte `BIT VARYING` 값이 dump에 `X''` 로 기록된 이유다. 이 실패는 원본 database를 변경하는 손실이 아니라 export/dump 값 손실이다.

Compactdb에는 세 가지 서로 다른 흐름이 있다.

| 흐름 | 실제 역할 | 필요한 OOS 처리 |
|------|-----------|-----------------|
| standalone phase 1 | raw `RECDES` 를 decode해 dangling OID/object reference와 old representation을 정리하고, 변경 시 다시 기록 | read 전에 Expand, write 전에 정상 OOS Demotion |
| server phase 1 | `HEAP_CACHE_ATTRINFO` 로 attribute를 읽고 같은 논리 정리를 수행 | record Expand 없이 attribute별 Resolve |
| physical page compaction | page 안에서 stored record bytes를 이동 | OOS inline stub 보존 |

standalone phase 1은 `sa/CMakeLists.txt` 에 포함되는 `src/executables/compactdb.c` 구현이다. `desc_disk_to_obj()` 가 OOS를 모르므로 읽기에는 Expand가 필요하다. 다만 변경된 object를 `desc_obj_to_disk()` 로 직렬화한 뒤 `heap_update_logical()` 로 직접 쓰면 `heap_attrinfo_determine_disk_layout()` 의 OOS Demotion을 거치지 않는다. logical value는 유지될 수 있지만 새 record가 완전 inline 또는 `REC_BIGONE` 이 되고, SA mode는 기존 record가 소유한 OOS value chain을 정리한다. 따라서 별도 재현 없이 영구 logical value 손실로 단정하지 않고, OOS 배치 정책을 잃는 확정적인 연동 gap으로 본다.

server phase 1의 `src/storage/compactdb_sr.c` 는 `heap_attrinfo_read_dbvalues()` 로 OOS-backed attribute를 Resolve하고, 갱신도 `locator_attribute_info_force()` 를 사용한다. record-level Expand는 중복이다. 더구나 `process_class()` 는 Expand된 `obj->length` 를 `space_to_process` 와 비교하므로, `obj->length > max_space_to_process` 인 경우 heap에는 작은 stub record로 저장된 OOS value도 big object로 분류되어 처리 대상에서 빠진다. 최대 예산은 충분하지만 현재 호출의 남은 예산만 부족하면 다음 호출로 미룬다.

`heap_compact_pages()` 가 호출하는 `spage_compact()` 는 attribute 값을 해석하지 않고 page 안에서 physical record bytes만 재배치한다. 이 경로는 OOS file을 읽거나 갱신하지 않으며 OOS inline stub을 그대로 보존해야 한다.

## Specification Changes

### `RECDES` 소비 정책

| 소비자 | 정책 |
|--------|------|
| raw bytes를 `LC_COPYAREA` 로 보내거나 OOS-blind decoder로 parse | OOS Expand |
| OOS-aware attribute 계층으로 논리 값을 읽음 | OOS Resolve |
| page/slot의 물리 record bytes를 이동 | stored form과 OOS inline stub 보존 |

정책 enum type은 `HEAP_RECDES_CONSUMPTION_POLICY` 를 사용하고, 값은 raw record bytes의 실제 소비 여부를 드러내는 `HEAP_RECDES_CONSUME_RAW_BYTES` / `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` 로 확정한다. 네트워크 전송은 대표적인 raw 소비 사례지만 유일한 사례가 아니므로, transport가 아니라 caller의 소비 계약을 이름에 사용한다.

OOS Demotion 기준은 고정 `DB_PAGESIZE/4` 가 아니다. `heap_oos_inline_target_size()` 가 계산하는 PG-style four-record heap target이며, 현재 16KB I/O page layout에서는 4,060B다. 이 값은 heap page와 네 개 slot의 물리 overhead를 반영하고 heap unfill은 제외한다.

## Implementation

### 수정 이력

```text
a8a192f33  CBRD-26458 / PR #6766
  unloaddb를 위해 record-level Expand 도입

4a6805e37  CBRD-26729 / PR #7093
  Expand를 opt-in으로 변경

1561c3b9c  CBRD-26818 / PR #7337
  xlocator_fetch_all() Expand 복구와 copyarea 처리 보강

309753de6, f59e9b8b2, 81f7dbbf3  CBRD-27029 / PR #7416
  explicit RECDES consumption policy 적용, single-object client fetch 수정
```

### unloaddb와 standalone Compactdb read

```text
xlocator_fetch_all()
  -> heap_next(..., HEAP_RECDES_CONSUME_RAW_BYTES)
  -> expanded RECDES를 LC_COPYAREA에 적재
  -> desc_disk_to_obj()가 raw record parse
```

### standalone Compactdb rewrite

```text
process_object()
  -> disk_update_instance()
     -> desc_obj_to_disk()
     -> heap_update_logical()
        ★ OOS-aware attribute transformation/Demotion을 거치지 않음
```

server Compactdb처럼 `HEAP_CACHE_ATTRINFO` 와 `locator_attribute_info_force()` 를 사용하거나, 동등한 정상 OOS transformation 경로를 사용하도록 맞춰야 한다.

### server Compactdb

```text
xlocator_lock_and_fetch_all()
  -> 현재 expanded RECDES 반환
  -> obj->length로 space_to_process 판정
     ★ logical expanded length가 processing budget을 왜곡할 수 있음
  -> heap_attrinfo_read_dbvalues()
  -> locator_attribute_info_force()
```

`xlocator_lock_and_fetch_all()` 의 다른 직접 caller도 OOS-aware attribute 계층을 사용하는지 확인한 뒤, stored-form fetch로 바꾸거나 `HEAP_RECDES_CONSUMPTION_POLICY` 를 인자로 받도록 한다.

## Acceptance Criteria

- [ ] CS와 SA mode `unloaddb` 에서 OOS-backed `BIT VARYING` 의 dump/reload 값이 원본과 byte-identical하다.
- [ ] multi-chunk OOS value를 `unloaddb` 로 내보내도 빈 값 또는 truncated value가 생기지 않는다.
- [ ] standalone Compactdb가 object를 갱신하지 않는 경우 logical value와 OOS 배치가 유지된다.
- [ ] OOS-backed `BIT VARYING` 과 dangling OID 또는 old representation을 함께 가진 fixture로 standalone Compactdb rewrite를 유도한다. 값의 byte equality와 debug `oos.log` 의 새 `oos_insert` 를 확인한다. Fixture 생성 절차는 `TBD - 재현 절차 확정 필요` 다.
- [ ] `stored length < max_space_to_process < expanded length` 인 row를 server Compactdb로 처리할 때 expansion만으로 `big_objects` 가 증가하지 않고 row가 처리된다.
- [ ] OOS-backed row가 있는 page에서 같은 slot의 stored `RECDES` 를 `spage_compact()` 전후 byte-compare하고, compact 후 SELECT 값도 byte-identical함을 확인한다.

## Definition of done

- [ ] 위 A/C를 모두 충족한다.
- [ ] SQL 및 관련 utility regression test를 통과한다.
- [ ] live JIRA의 관련 이슈와 PR link를 실제 수정 소유권에 맞게 갱신한다.
- [ ] Compactdb 잔여 범위를 별도 이슈로 분리할 경우 상호 링크를 추가한다.

## Remarks

- `BIT VARYING` 을 테스트 데이터로 사용한다. `VARCHAR` 는 압축되어 disk size가 예측과 달라질 수 있다.
- release build에서는 attribute가 실제 OOS-backed 상태인지 SQL만으로 직접 확인하기 어렵다. debug `oos.log` 의 `oos_insert` 기록을 사용하고, CBRD-26871의 관측 기능이 제공되면 그 방식으로 교체한다.
- CBRD-27029의 single-object client fetch와 `S_DOESNT_FIT` grow/retry 검증은 관련 작업이지만 이 이슈의 A/C에는 포함하지 않는다.
- live JIRA 유형은 Sub-task, 상태는 Open이다.
