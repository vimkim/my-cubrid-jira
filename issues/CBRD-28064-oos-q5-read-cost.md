# [OOS] [TODO] OOS 값 읽기의 값당 CPU 비용 감소

**한 줄 요약**: PR #7990 성능 수락 기준 AC-P3에서 develop의 overflow 행이 OOS로 바뀐 테이블의 모든 컬럼 읽기(Q5)가 −6.05%로 잠정 2% 목표 밖에 남았다. 이에 대응하여 OOS 값 하나를 읽을 때 드는 복사, page fix, 할당 비용을 줄이는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: OOS에 저장된 값을 읽는 CPU 비용을 줄여, develop에서 overflow로 저장되던 큰 행의 모든 컬럼 읽기가 develop 대비 −2% 안(서버 `instructions:u`)에 들어오게 한다. 판정은 CBRD-27788과 같은 io_bench 입력과 조건으로 다시 측정한다.

**이슈 수행 이유**: OOS 스펙에서 한 페이지를 넘는 행은 overflow로 저장할 수 없고 큰 값을 OOS로 보내야 한다. 그래서 이 경로는 임계값 파라미터(CBRD-28062)로 피할 수 없다. 22KB 행의 모든 컬럼을 읽는 Q5는 develop보다 CPU 명령어를 6.05% 더 썼다(CBRD-27788, 측정). 프로파일에서 늘어난 비용은 질의 자체의 일이 아니라 OOS 값을 꺼내는 과정에 있었다.

**영향**: 한 페이지를 넘는 행을 전체로 읽는 사용자는 OOS 통합 뒤 같은 질의에 CPU를 약 6% 더 쓴다(명령어 수, 데이터가 모두 메모리에 있는 상태). 이 비용은 행이 가진 OOS 값의 수에 비례할 것으로 본다(추정). 실제 서비스의 처리량과 응답 시간에 미치는 영향은 측정하지 않았다. PR #7990 리뷰에서 공개해야 할 손해 항목으로 남아 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 프로파일 근거와 후보 방향은 아래에 정리했다.

---

## AI-Generated Context

> 아래는 2026-11-12에 측정한 프로파일과 `feature/oos-merge` `67220b7e2`의 코드를 읽고 정리한 맥락이다. 측정값, 코드에서 확인한 사실, 측정하지 않은 가설을 구분한다. CUBRID 코드는 바꾸지 않았다.

## Description

### 측정 (CBRD-27788, 2026-11-12)

- **비교 대상.** develop merge-base `2dd94e32`와 `feature/oos-merge` `67220b7e2`다. io_bench overflow 입력은 22KB 행이며, head는 행마다 값 4개를 OOS로 보낸다.
- **Q5(모든 컬럼 읽기).** develop 23,367.6M 명령어 대비 head −6.07%(warm), −6.05%(재시작만)다. 변화율 = (develop − head) / develop이고, 나빠지면 −다.
- 상세는 [CBRD-27788 "후속 측정 결과 (2026-11-12)"](https://jira.cubrid.org/browse/CBRD-27788)와 [재측정 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-ac-p2-p3-remeasure_67220b7_claude.md)에 있다.

### 프로파일 (2026-11-12)

`perf record -e instructions:u -c 4000037 -g`로 warm 상태의 Q5를 한 번씩 기록했다. 샘플은 develop 5,829개, head 6,193개(+364, +6.24%)로 `perf stat` 결과와 맞는다. 샘플 하나는 약 400만 명령어다. 질의 자체의 일인 `varbit_compare`는 5,507 → 5,490으로 그대로였다.

head에서 늘어난 샘플을 직접 호출자 기준으로 나누면 다음과 같다.

| 항목 | 늘어난 샘플 | 내용 |
| --- | ---: | --- |
| 값 복사 두 번 | 약 97 | `oos_read_many` 45(OOS 페이지 → 임시 버퍼), `mr_data_readval_varbit` 52(임시 버퍼 → DB_VALUE). develop은 `overflow_get` 10 |
| page fix와 할당 해제 확인 | 약 73 | `disk_is_page_sector_reserved_with_debug_crash` 48, `pgbuf_fix_if_not_deallocated` 25 |
| 행·값마다 malloc/free | 약 41 | `hl_lea_alloc` 28, `recdes_free_data_area` 9, `pr_clear_value` 4 |
| OOS 레코드 처리 | 약 71 | `heap_recdes_get_var_offset_pair` 33, `heap_oos_read_grouped_payloads` 16, `oos_read_many` 13, `heap_oos_free_grouped_payloads` 9 |

이 결과는 PR #7990 리뷰어가 제시한 "값마다 page fix 세 번과 복사 두 번" 가설([CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785) Reviewer Report)과 일치한다.

### 코드 경로 (`67220b7e2`, 코드 읽기)

행에 OOS 값이 둘 이상이면 [`heap_attrinfo_read_dbvalues_with_oos_prefetch`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L12151)가 값을 한꺼번에 미리 읽은 뒤 DB_VALUE로 바꾼다. 값 하나마다 다음 일이 생긴다.

1. **임시 버퍼 할당.** [`heap_oos_read_grouped_payloads`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_oos.cpp#L791)가 값 길이만큼 `recdes_allocate_data_area`로 버퍼를 잡는다.
2. **할당 해제 확인.** [`oos_fix_page_if_oos`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/oos_file.cpp#L2550)는 `pgbuf_fix_if_not_deallocated`를 쓴다. 이 함수는 OOS 페이지를 fix하기 전에 [`disk_is_page_sector_reserved`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/page_buffer.c#L16172)로 sector가 아직 예약되어 있는지 확인하며, 이때 volume header 페이지와 sector table 페이지를 fix한다. 코드 주석도 "호출마다 캐시된 volume 페이지 fix 두 번"이라고 적는다. 같은 OOS 페이지에 head chunk가 있는 값들은 [`oos_read_many`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/oos_file.cpp#L2843)가 한 번의 fix로 묶어 읽는다.
3. **첫 번째 복사.** `oos_read_many`가 OOS 페이지의 chunk를 임시 버퍼로 복사한다.
4. **두 번째 복사.** [`heap_attrvalue_read`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L12065)는 미리 읽은 값에 `copy_raw = true`를 주므로, `mr_data_readval_varbit`가 임시 버퍼를 DB_VALUE로 다시 복사한다.
5. **임시 버퍼 해제.** DB_VALUE를 만든 뒤 [`heap_oos_free_grouped_payloads`](https://github.com/CUBRID/cubrid/blob/67220b7e230ff1587ba5940001d72e10477a1fc4/src/storage/heap_file.c#L12163)가 버퍼를 모두 해제한다.

develop의 overflow 경로는 `overflow_get`으로 행 전체를 한 번 복사한다(프로파일 기준 10 샘플).

## Options for Analysis

아래는 코드 경로에서 나온 후보이며, 아무것도 측정하지 않았다. 효과 크기는 위 표의 해당 항목을 넘을 수 없다.

| 후보 | 기대 효과 | 한계와 위험 | ANALYSIS 확인 사항 |
| --- | --- | --- | --- |
| A. 한 번만 복사: OOS chunk를 DB_VALUE가 소유할 버퍼로 바로 읽거나, 임시 버퍼의 소유권을 DB_VALUE로 넘긴다 | 두 번째 복사(약 52 샘플)와 해제 비용 일부 | 타입마다 DB_VALUE의 메모리 소유 규칙이 다르다. 압축 문자열, LOB locator, collation 처리처럼 readval이 변환하는 타입은 그대로 넘길 수 없다 | 타입별 readval이 원본 바이트를 그대로 쓰는지, `need_clear`와 해제 경로가 맞는지 |
| B. 할당 해제 확인을 줄인다: 행이나 OOS 파일 단위로 한 번만 확인하거나, 읽기 경로에서는 확인을 생략한다 | sector 확인의 volume 페이지 fix(약 73 샘플 중 대부분) | 이 확인은 vacuum이 회수한 페이지를 읽지 않게 하는 안전장치다. 줄이면 해제된 페이지를 가리키는 참조의 판별과 debug 빌드의 페이지 검증에 영향이 있다 | MVCC snapshot 아래의 읽기에서 OOS 페이지가 해제될 수 있는 경우가 있는지, 확인 단위를 넓혀도 안전한지. snapshot 없는 reader와 회수가 겹치는지는 [CBRD-27981](https://jira.cubrid.org/browse/CBRD-27981)에서 조사 중이다 |
| C. 버퍼 재사용: 행·값마다 malloc/free 대신 scan 동안 버퍼를 재사용한다 | malloc/free(약 41 샘플) | 값 크기가 다양하면 버퍼 크기 관리가 필요하다. A와 함께 하면 효과가 겹친다 | A를 택하면 C가 남기는 이득이 있는지 |

세 후보는 서로 다른 항목을 줄이므로 함께 적용할 수 있다. A와 B가 늘어난 샘플의 약 3분의 1씩을 차지해 우선 검토 대상이다(측정값 기준 추정). OOS 레코드 처리(약 71 샘플)는 이 후보들로 줄지 않는다.

## Acceptance Criteria

- CBRD-27788과 같은 io_bench overflow 입력(22KB 행, 행마다 OOS 값 4개)과 조건으로 Q5를 다시 측정해, develop 대비 −2% 안(서버 `instructions:u` 중앙값)에 들어온다.
- 같은 측정에서 작은 컬럼 조회(Q1~Q3)와 큰 값 하나 읽기(Q4)가 나빠지지 않는다.
- 변경 전후 프로파일로 줄어든 항목이 위 표의 어느 항목인지 보인다.
- 할당 해제 확인을 바꾸면, vacuum이 회수한 OOS 페이지를 읽는 경우의 기존 테스트가 통과한다.

## Out of Scope

- 파일 캐시를 비운 뒤 큰 값 읽기의 지역성과 지연([CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791)). 이 이슈는 데이터가 메모리에 있을 때의 CPU 비용만 다룬다.
- OOS로 보내는 임계값([CBRD-28062](https://jira.cubrid.org/browse/CBRD-28062)). 임계값은 4~16KB 행의 저장 위치를 바꾸지만, 한 페이지를 넘는 행은 어떤 설정에서도 OOS를 쓴다.

## Related

- 상위: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) `[OOS] [EPIC] TODO`
- 측정: [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788), 리뷰어 가설과 AC 경위: [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)
- 임계값: [CBRD-28062](https://jira.cubrid.org/browse/CBRD-28062), 읽기 지역성: [CBRD-27791](https://jira.cubrid.org/browse/CBRD-27791)
- OOS reader와 회수의 겹침: [CBRD-27981](https://jira.cubrid.org/browse/CBRD-27981), SQL trace의 OOS 읽기 비용 구분: [CBRD-28011](https://jira.cubrid.org/browse/CBRD-28011)
- 리뷰어 병합 기준: [PR #7990 10/28 댓글](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6461744209)
