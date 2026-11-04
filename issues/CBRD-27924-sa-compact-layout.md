# [OOS] SA compact의 representation 재작성에 OOS 배치 정책 적용

**한 줄 요약**: SA compact가 lazy default를 포함한 현재 representation으로 행을 재작성할 때 일반 UPDATE·CS compact와 같은 OOS 배치 정책을 적용하도록 수정한다.

## Issue Triage

**이슈 수행 목적**: SA compact의 실제 행 재작성에서도 OOS 대상 값을 정상적으로 분리하고 논리 값과 소유권을 보존한다.

**이슈 수행 이유**: Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`에서 같은 lazy-default fixture를 SA compact로 재작성하면 5544B inline 행이 되지만, 일반 UPDATE와 CS compact는 2576B의 HAS_OOS 행을 만든다. SA writer가 attribute-layer OOS 배치 결정을 우회하는 경로와 실제 representation 변경을 함께 확인했다.

**영향**: 유지보수 유틸리티가 큰 가변 컬럼을 다시 쓸 때 저장 배치가 일반 DML·CS compact와 달라지고 heap 행이 커진다. 관측 fixture의 전체 논리 값은 보존됐다. 이 관측으로 값 손실이나 모든 compact 경로의 결함을 주장하지 않는다.

**이슈 수행 방안**: SA 재작성 경로에 정상 OOS 배치 변환을 적용한다. 구체적인 API와 구현 범위는 ANALYSIS 단계에서 정한다. 기존 `gap_compact_sa_cs`의 물리 기대값을 유지한다.

---

## AI-Generated Context

## Description

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 수리 하위 작업이며, [CBRD-26659](https://jira.cubrid.org/browse/CBRD-26659)의 실패 후속이다. 2026-11-04 담당자 결정은 SA compact의 정책 우회를 엔진 수리 대상으로 처리하는 것이다. 이전 진단 보고서에 남은 “엔진 수리 또는 TC 기대값 변경” 선택지는 이 결정으로 정리한다.

증거는 Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`, TC `01df2600ac75180812451462b5c044cfa56b732a` 기준이다. 최신 수정 대상 revision에서의 재현 여부는 수리 착수 시 확인한다.

## Repro

1. 3000B `BIT VARYING` payload를 가진 행을 만든다.
2. `add_column_update_hard_default=no`에서 2500B `BIT VARYING` default column을 lazy ADD한다.
3. 저장 representation·길이·flag를 기록하고 `cubrid compactdb -S -v gapdb dba.gap_rows`를 실행한다.
4. 같은 OID의 물리 행, 전체 값, HAS_OOS와 실제 OOS owner를 대조한다. 같은 값을 할당하는 일반 UPDATE와 별도 동일 fixture의 CS compact도 비교한다.

| 동작 | Representation | 저장 길이 | Flags | HAS_OOS·owner |
| --- | --- | --- | --- | --- |
| lazy ADD 뒤 | 1 | 3040B | 1 | 없음 |
| SA compact | 2 | 5544B | 0 | 없음 |
| 일반 UPDATE | 2 | 2576B | 13 | 있음 |
| 별도 fixture의 CS compact | 2 | 2576B | 13 | 있음 |

SA에서는 같은 OID의 representation과 길이가 바뀌어 실제 재작성임을 확인했다. 원래 SA TC는 FAIL이며 CS 진단 PASS로 대체하지 않는다.

## Analysis

[SA writer](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/executables/compactdb.c#L655)는 `desc_obj_to_disk` 뒤 `heap_update_logical`을 직접 호출한다. [일반 직렬화](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/loaddb/load_object.c#L490)는 attribute-layer OOS planner를 거치지 않는다. [CS rewrite](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/compactdb_sr.c#L257)와 [일반 DML](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/heap_file.c#L14194)의 경로를 비교한다.

## Acceptance Criteria

- [ ] 최신 수정 대상 revision과 수정 전 재현 결과를 고정한다.
- [ ] SA compact의 실제 representation 재작성에 정상 OOS 배치 정책을 적용한다.
- [ ] 원래 `gap_compact_sa_cs`를 기대값 완화 없이 실행하고 전체 값·물리 행·OOS owner를 검증한다. SA·CS·일반 UPDATE 대조를 남긴다.
- [ ] 기존 OOS stub에서 시작하는 rewrite와 필요한 Expand·소유권 처리를 별도로 검증한다. 현재 lazy-default fixture만으로 이 범위를 통과 처리하지 않는다.
- [ ] 수정 commit·검증 결과·잔여 제한을 CBRD-26659에 연결한다.

## Related Work

[진단 보고서](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/reclaim-compact-diagnosis.md)를 근거로 한다. Resolved 상태의 [CBRD-26948](https://jira.cubrid.org/browse/CBRD-26948)에 남은 SA rewrite gap을 이번 재현으로 구체화한 후속이다. [CBRD-27424](https://jira.cubrid.org/browse/CBRD-27424)는 standalone loader·workspace force 경로를 다루며 이번 compact 수리와 구분한다.
