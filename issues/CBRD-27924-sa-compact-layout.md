# [OOS] SA compact의 representation 재작성에 OOS 배치 정책 적용

**한 줄 요약**: SA compact가 lazy default를 포함한 현재 representation으로 행을 재작성할 때 일반 UPDATE·CS compact와 같은 OOS 배치 정책을 적용하도록 수정한다.

## Issue Triage

**이슈 수행 목적**: SA compact의 실제 행 재작성에서도 OOS 대상 값을 정상적으로 분리하고 논리 값과 소유권을 보존한다.

**이슈 수행 이유**: Engine `e3589ae42d42b04eb020e1ae43e165b01d31b12a`에서 같은 lazy-default fixture를 SA compact로 재작성하면 5544B inline 행이 되지만, 일반 UPDATE와 CS compact는 2576B의 HAS_OOS 행을 만든다. SA writer가 attribute-layer OOS 배치 결정을 우회하는 경로와 실제 representation 변경을 함께 확인했다.

**영향**: 유지보수 유틸리티가 큰 가변 컬럼을 다시 쓸 때 저장 배치가 일반 DML·CS compact와 달라지고 heap 행이 커진다. 관측 fixture의 전체 논리 값은 보존됐다. 이 관측으로 값 손실이나 모든 compact 경로의 결함을 주장하지 않는다.

**이슈 수행 방안**: SA 재작성 경로에 정상 OOS 배치 변환과 그 크기 판정을 적용한다. OOS로 옮길 값이 없어도 한 페이지를 넘는 행은 `REC_BIGONE`으로 쓰지 않는다. 구체적인 API, 거부한 행의 처리 방식과 구현 범위는 ANALYSIS 단계에서 정한다. 기존 `gap_compact_sa_cs`의 물리 기대값을 유지한다.

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
- [ ] 아래 3000B payload와 21000B lazy default fixture에서도 정상 OOS 배치를 적용한다. 20KB를 넘는 재작성 입력을 기존 heap overflow로 우회 저장하지 않으며 전체 값과 owner를 검증한다.
- [ ] OOS 대상 값이 없는 큰 행(예: 큰 고정 길이 컬럼이나 `FORCE_INLINE` 값만으로 한 페이지를 넘는 행)도 SA compact가 `REC_BIGONE`으로 쓰지 않는다. 그 행의 처리(compact 실패, 해당 객체 건너뛰기와 보고 등)를 정하고 검증한다.
- [ ] heap 계층에서 multipage(`REC_BIGONE`) 데이터를 쓰는 insert·update 분기에 debug assert를 둔다. 대상은 `heap_insert_handle_multipage_record`, `heap_update_home`, `heap_update_relocation`, `heap_update_bigone` 의 큰 레코드 분기다. 조건은 `OID_ISNULL (&context->class_oid) || oid_is_system_class (&context->class_oid)` 이다. delete 두 분기(`heap_delete_home`, `heap_delete_relocation`)는 규칙 이전에 저장된 행이 정상적으로 도달할 수 있으므로 제외한다. debug 빌드에서 unit·SQL·shell 회귀와 `gap_compact_sa_cs` 가 assert 없이 통과함을 확인한다.

- [ ] 수정 commit·검증 결과·잔여 제한을 CBRD-26659에 연결한다.

## 범위 추가 (2026-11-09)

[CBRD-27259](https://jira.cubrid.org/browse/CBRD-27259)([PR #8416](https://github.com/CUBRID/cubrid/pull/8416))에서 명세를 바꿨다. 이전에는 OOS 값이 없는 행의 `REC_BIGONE`을 허용했지만, 이제 `heap_attrinfo_transform_to_disk_internal`을 거치는 비시스템 클래스 행은 `REC_BIGONE`이 될 크기면 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`로 거부한다. 크기에는 MVCC 헤더 최대치가 들어간다. heap 계층에는 검사가 없어서, SA compact처럼 이 함수를 거치지 않고 `heap_update_logical`을 직접 부르는 경로는 여전히 `REC_BIGONE`을 만든다([OOS 명세](https://github.com/vimkim/cubrid-oos-context/blob/faee27e/OOS-CONTEXT.md#bigone-rejection-cbrd-26937-cbrd-27259)). 그래서 이 이슈는 OOS 분리뿐 아니라 이 크기 판정까지 SA compact에 적용해야 한다.

## 범위 추가 (2026-11-11)

[PR #8416 리뷰](https://github.com/CUBRID/cubrid/pull/8416#discussion_r4536816674)에서 heap 계층의 `REC_BIGONE` 분기에 "시스템 클래스 행만 허용"하는 debug assert를 요청했다. 거부 판정은 행 배치 함수 한 곳에만 있어서, 그 함수를 거치지 않는 새 writer가 생기면 원칙이 조용히 깨진다. assert를 이 이슈의 수정 전에 넣으면 debug 빌드의 SA compact TC가 assert에 걸리므로, SA compact 수정과 함께 넣는다. SA compact가 갱신하는 행은 대개 `REC_HOME` 이라 `heap_update_home` 의 큰 레코드 분기(`heap_ovf_insert`)를 지난다. 그래서 리뷰에서 제안한 세 분기 외에 이 분기도 대상에 넣는다.

## Additional verification

2026-11-04에 20KB를 넘는 실제 RECDES의 저장 경로를 추가 검사했다. **이 고정 revision의 SA compact는 OOS로 분리하지 않고 heap overflow에 저장한다.** 입력은 3000B `BIT VARYING` payload와 lazy ADD한 21000B `BIT VARYING` default다. SQL 문자열이나 선언 길이 대신 실제 직렬화 결과와 저장 형태를 관측했다.

| 관측 | SA compact | 같은 행의 일반 UPDATE | 별도 동일 fixture의 CS compact |
| --- | --- | --- | --- |
| 현재 representation | 2 | 2 | 2 |
| heap home slot 유형 | `REC_BIGONE`, 5 | `REC_HOME`, 2 | `REC_HOME`, 2 |
| home slot 저장 길이 | 8B, overflow 참조 | 3076B | 3076B |
| record flags | 7, HAS_OOS 없음 | 13, HAS_OOS 있음 | 13, HAS_OOS 있음 |
| OOS file·chunk | 없음, 0개 | 있음, 2개 | 있음, 2개 |
| 전체 값 대조 | 3000B·21000B 일치 | 3000B·21000B 일치 | 3000B·21000B 일치 |

SA debugger 관측에서 `desc_obj_to_disk`의 반환 길이와 `heap_update_logical` 입력은 모두 **24052B**였다. 당시 최대 slotted record 길이는 16236B였다. 이후 `overflow_insert`에 24068B가 전달됐고 `file_type`은 `FILE_MULTIPAGE_OBJECT_HEAP`이었다. 호출 stack에는 `heap_update_home` → `heap_ovf_insert` → `overflow_insert`가 있었다. Home slot의 8B는 전체 행 길이가 아니라 overflow 참조 크기다. OOS file 부재도 SHOW로 확인했다.

이 결과는 [SA writer](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/executables/compactdb.c#L656)의 직접 heap 갱신과 [큰 home record의 overflow 전환](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/heap_file.c#L25061) 경로를 실제 관측으로 연결한다. 일반 UPDATE의 [OOS·bigone 공존 거부](https://github.com/CUBRID/cubrid/blob/e3589ae42d42b04eb020e1ae43e165b01d31b12a/src/storage/heap_file.c#L14230)는 attribute 변환 단계에 있다. 이번 SA 행에는 HAS_OOS가 없으므로, 이번 결과를 OOS와 bigone의 동시 저장이나 해당 거부 조건의 실패로 해석하지 않는다.

검사는 같은 Engine·TC 기준의 optdebug 빌드와 16KB DB page에서 별도 진단 fixture로 수행했다. Native 진단 1건은 PASS했고 소유 프로세스·관측 namespace 잔여는 0이다. 앞선 두 시도는 debugger 실행 대상과 도구 인자 설정 실패로 보존했다. 진단 PASS는 원래 `gap_compact_sa_cs`의 FAIL을 통과로 바꾸지 않으며, 엔진 수리는 아직 하지 않았다. 최신 feature head나 다른 page size의 결과로 일반화하지 않는다.

## Related Work

[진단 보고서](https://github.com/vimkim/my-cubrid-docs/blob/0c5c05f713ca1953725743b865c7d3c14bd1272f/cbrd-26659/reclaim-compact-diagnosis.md)를 근거로 한다. Resolved 상태의 [CBRD-26948](https://jira.cubrid.org/browse/CBRD-26948)에 남은 SA rewrite gap을 이번 재현으로 구체화한 후속이다. [CBRD-27424](https://jira.cubrid.org/browse/CBRD-27424)는 standalone loader·workspace force 경로를 다루며 이번 compact 수리와 구분한다.
