# [OOS][CI] 신규 도입 test_sql_by_cci의 feature/oos-merge 실패 57건 트래킹

**한 줄 요약**: gha-ci에 새로 도입된 `test_sql_by_cci` 스위트가 `feature/oos-merge` 대상 PR마다 같은 57건을 실패시키는 것을 PR #8434 CI 분석에서 확인하여, 이 실패를 개별 PR이 아닌 `feature/oos-merge` 브랜치의 과제로 추적하고 원인별로 정리하는 하위 작업이다.

## Issue Triage

**이슈 수행 목적**: `feature/oos-merge`에서 `test_sql_by_cci` 실패 57건의 원인(엔진 동작 변경, CCI 출력 형식 차이, 답안 파일 drift 등)을 사례 그룹별로 판별하고, 각 그룹을 수정·답안 갱신·별도 이슈 중 하나로 정리하여 이 스위트가 `feature/oos-merge` PR의 회귀를 가려낼 수 있게 한다.

**이슈 수행 이유**: PR [#8434](https://github.com/CUBRID/cubrid/pull/8434)의 CI [run 42603737999](https://github.com/CUBRID/cubrid/actions/runs/42603737999)에서 `test_sql_by_cci`가 17,630건 중 57건 실패했다(오류 0건). PR #8434의 커밋을 포함하지 않는 다른 `feature/oos-merge` PR [#8348](https://github.com/CUBRID/cubrid/pull/8348)의 [run 42578641410](https://github.com/CUBRID/cubrid/actions/runs/42578641410)도 같은 57건을 바이트 단위로 동일한 diff로 실패했다. 따라서 이 실패는 특정 PR이 아니라 `feature/oos-merge` 자체에 속한다. 지금은 어느 이슈도 이 실패를 맡고 있지 않다.

**영향**: `feature/oos-merge`에 PR을 올리는 개발자와 리뷰어는 매번 같은 57건 실패를 보게 되고, PR마다 "이 실패가 내 변경 때문인가"를 다시 분석해야 한다. 이미 실패한 57건에 가려 PR이 새로 만든 `test_sql_by_cci` 실패를 놓칠 위험도 있다. 현재 `test_sql_by_cci`는 안정적인 required gha-ci context에 포함되지 않아 병합을 막지는 않는다. 57건 중 OOS 크기 값이나 vacuum을 사용하는 사례는 없지만, 각 그룹의 원인 커밋은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`test_sql_by_cci`는 `test_sql`과 같은 SQL 테스트케이스를 JDBC 대신 CCI 드라이버로 실행하고, `.answer_cci` 답안 파일과 비교하는 gha-ci 스위트다. 같은 run에서 `test_sql`(JDBC), `test_medium`, `test_shell`과 빌드는 모두 통과했고 `test_sql_by_cci`만 실패했다. 실패 shard는 01(6), 03(9), 04(1), 05(3), 06(3), 07(14), 09(21)이다.

`feature/oos-merge`에서 관측한 결과는 다음과 같다.

| PR | head | run | 결과 |
|---|---|---|---|
| #8434 | `8e139f4db` | [42603737999](https://github.com/CUBRID/cubrid/actions/runs/42603737999) | 57건 실패. collector로 검증한 목록 |
| #8434 이전 head | `0034bc2fb`, `26e6d1d6f` | [42562225722](https://github.com/CUBRID/cubrid/actions/runs/42562225722), [42585563930](https://github.com/CUBRID/cubrid/actions/runs/42585563930) | 같은 57건. job log에서 추출 |
| #8348 | `00b421e32` | [42578641410](https://github.com/CUBRID/cubrid/actions/runs/42578641410) | 같은 57건, diff 57건 모두 동일. collector로 검증 |
| #8416 | — | 42573078376 | 같은 57건과 해당 PR 고유 4건. job log에서 추출 |

관측한 모든 run에서 실패 목록이 같았다. 관측 범위가 2026-11-09 하루의 4개 run이라 flaky 여부는 판단하지 않았다.

### 실패 그룹

diff 형태로 57건을 세 그룹으로 나눴다. 그룹별 원인은 추론이며 확정되지 않았다.

| 그룹 | 건수 | 관측 | 예시 |
|---|---|---|---|
| E: 오류 코드 또는 결과 차이 | 7 | 오류 코드나 결과 값 자체가 답안과 다르다 | `cbrd_27504.sql` `Error:-621` → `Error:-176`; `1101.sql` `Error:-528` → `Error:-526`; `_09_percent_type` 두 사례가 값 대신 `-889`(precision·scale 초과); `cbrd_27668.sql` `true` → `18`; `cbrd_23665.sql` count `150000` → `100000`; `rtrim_002.sql` 멀티바이트 행 공백 1개 |
| V: CCI 값 표현 차이 | 45 | 같은 값을 답안과 다른 형식으로 출력한다 | `0.1` → `0.100000000000000`; `2.00` → `2.0`; `5.0` → `5.0000000000000000`; AVG 9번째 자리 `111.209500504` → `111.209500122`; `2024-01-02 10:00:01.0` → `2024-01-02 10:00:01` |
| P: plan·profile 출력 차이 | 5 | 실행 계획이나 trace 출력이 다르다 | `hash_agg_query_profile.sql`, `cbrd_26431.sql` `hash: partial` → `hash: true`; `join_orderby_skip.sql` `hybrid` → `memory`; `cbrd_27397.sql` trace block 추가; `cbrd_25447.sql` `parallel workers` 줄 추가 |

분석 보고서는 오류 코드나 결과가 바뀐 그룹 E를 먼저 보라고 권한다. 표현 차이보다 실제 동작 변경일 가능성이 크기 때문이다. 그룹 E의 `-889` 두 건은 그룹 V의 NUMERIC precision 변화와 같은 계열로 보인다.

그룹 V의 후보로는 집계 결과 domain(AVG, SUM, MEDIAN, PERCENTILE), host 변수·상수 domain 변경(`cbrd_27510` 계열), PL/CSQL `%TYPE`의 NUMERIC precision 처리가 거론됐다. 엔진이 보고하는 type·scale·precision이 달라졌는지, CCI 클라이언트의 형식화가 다른지, `.answer_cci` 답안을 다시 만들어야 하는지는 확인하지 않았다. 그룹 P는 hash 집계·hash join 결정이나 trace 형식 차이, 또는 JDBC와 CCI runner의 메모리 파라미터 차이가 후보다.

### 기준선의 한계

- 정확한 merge base `95ff126a8`에는 `test_sql_by_cci` 실행 기록이 없어 공식 기준선이 없다. 위 결론은 다른 PR과의 비교에 근거한다.
- 테스트 이력 도구(Chronicle)는 `test_sql_by_cci`를 색인하지 않아 사례별 이력이 없다.
- 참고로 `develop` PR [#8403](https://github.com/CUBRID/cubrid/pull/8403)의 [run 42751409301](https://github.com/CUBRID/cubrid/actions/runs/42751409301)은 35건 실패했고, 그중 17건이 이 57건과 겹친다. `develop`과 `feature/oos-merge`는 엔진과 테스트케이스가 갈라져 있으므로 이 비교로 실패를 분류하지 않는다.

### ANALYSIS 확인 사항

- `feature/oos-merge` 최신 tip에서 `test_sql_by_cci`를 실행하면 같은 57건이 나오는가. 이 결과가 빠진 기준선을 대신한다.
- 그룹 E 7건 각각이 엔진 동작 변경인가, 테스트케이스·답안 drift인가. 도입 커밋은 무엇인가.
- 그룹 V는 엔진 domain 변경, CCI 형식화, 답안 미갱신 중 어디에 속하는가. 답안 재생성이 맞다면 담당 기능(`cbrd_27510`, 집계 domain 작업)의 소유자가 동의하는가.
- 그룹 P는 `test_sql`과 `test_sql_by_cci` runner 설정 차이로 설명되는가.
- `develop`과 겹치는 17건은 `develop`에서 별도로 다뤄지고 있는가.

### 완료 기준

- 57건 각각이 원인 그룹과 처리 방식(엔진 수정, 답안 갱신, 별도 이슈, 기존 이슈 연결) 중 하나에 연결된다.
- 처리 후 `feature/oos-merge` tip의 `test_sql_by_cci` 실행에서 남은 실패가 모두 추적 중인 이슈에 연결된다.

## References

- 상위 이슈: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) OOS TODO
- 분석 보고서: [PR #8434 test_sql_by_cci CI 분석](https://github.com/vimkim/my-cubrid-docs/blob/d009ff1a2759fb237e81c2684443b558bf474e5e/cbrd-27781/ci-analysis-sql-by-cci.md) — 57건 전체 목록, 그룹별 diff 근거, 한계
- 분석 대상: PR #8434 head `8e139f4dbb2635058032d0b9dafd5f624c726754`, base `feature/oos-merge` `95ff126a8464179a2fab3092b6f56468528ab954`, 테스트케이스 `tc/pr-8434` `e61878fb79591bb367f672074ac4c36c366a7122`
