# [OOS][CI] 신규 도입 test_sql_by_cci의 feature/oos-merge 실패 57건 트래킹

**한 줄 요약**: `feature/oos-merge`에서만 실패하던 `test_sql_by_cci` 57건을 추적하던 하위 작업이다. 이 브랜치에 develop을 merge한 뒤 다시 실행해 보니, 남은 실패는 모두 develop에서도 똑같이 실패하는 것이었고 OOS 때문에 생긴 실패는 없었다. 이 결과를 기록한다.

## Issue Triage

**이슈 수행 목적**: `feature/oos-merge`의 CI 실패 가운데 OOS 변경 때문에 생긴 것과 develop에서 함께 넘어온 것을 나눈다. 이를 근거로 PR #7990(`feature/oos-merge` → develop)의 CI 결과를 판단할 수 있게 한다.

**이슈 수행 이유**: gha-ci에 `test_sql_by_cci`가 새로 들어온 뒤, `feature/oos-merge` 대상 PR마다 같은 57건이 실패했다(PR #8434 [run 42603737999](https://github.com/CUBRID/cubrid/actions/runs/42603737999) 등). 2026-11-10에 엔진과 testcase 저장소 두 개에 develop을 두 차례 merge하고 PR #7990에서 `/run all`을 실행했다. 그 결과 develop run에서는 보이지 않고 OOS에서만 보이는 엔진 실패는 0건이다.

**영향**: 대상은 OOS 개발자와 PR #7990 리뷰어다. 남은 실패는 develop과 같은 출력으로 실패하므로, PR #7990 병합을 판단할 때 OOS 결함 근거로 보지 않아도 된다. 다만 이 실패들은 develop 자체의 미해결 실패로 남는다. 기준선은 develop 대상 PR run이며, develop push run과는 비교하지 않았다.

**이슈 수행 방안**: develop 동기화로 57건을 해소했다. 남은 실패는 develop 공통 실패로 분류하고, develop 쪽 처리는 `test_sql_by_cci` 도입 작업(CUBRIDQA-1709 계열)과 각 testcase 담당 이슈에 맡긴다. 이 이슈는 `feature/oos-merge`가 develop에 병합될 때까지 열어 두고, develop을 merge할 때마다 OOS에서만 생기는 실패가 있는지 확인한다.

---

## AI-Generated Context

## Description

`test_sql_by_cci`는 `test_sql`과 같은 SQL testcase를 CCI 드라이버로 실행한다. `.answer_cci` 파일이 있으면 그 파일과, 없으면 `.answer`와 결과를 비교한다. 이 suite는 develop에서도 30~50건씩 실패한다. 그래서 `feature/oos-merge`의 실패에서 develop 공통 실패를 먼저 빼야 OOS 작업의 범위가 보인다.

### 처음 57건의 원인

PR #8434 [run 42562225722](https://github.com/CUBRID/cubrid/actions/runs/42562225722)의 실패 57건을 develop 대상 PR run 6개와 비교했다. 모두 `feature/oos-merge`가 develop보다 뒤처져서 생긴 실패였다.

| 분류 | 건수 | 원인 | 해소 방법 |
|---|---|---|---|
| develop에서도 실패 | 29 | develop 공통 실패 | 이 이슈의 범위가 아니다 |
| testcase answer가 오래됨 | 18 | develop testcase commit `ab02108cd`(CBRD-27510 cci answer 수정)가 testcase branch에 없었다 | develop testcase merge |
| 엔진 결과가 develop과 다름 | 10 | develop 엔진 변경이 `feature/oos-merge`에 없었다 | develop 엔진 merge |

### develop 동기화

| 저장소 | `feature/oos-merge` 이전 | 1차 후 | 2차 후 |
|---|---|---|---|
| CUBRID/cubrid | `95ff126a8` | `dcf38cb0a` | `50619ce53` (develop `2dd94e32a` merge) |
| CUBRID/cubrid-testcases | `70db22a1c` | `36412f7e8` | `b53a7984c` |
| CUBRID/cubrid-testcases-private-ex | `75a02020e` | `5c440ce44` | `8ef4f6278` |

merge에서 생긴 OOS 쪽 변경은 다음 두 가지다.

- develop이 error code -1387..-1394를 새로 써서 OOS error code를 -1395..-1401로 옮겼다. 이 번호가 들어 있는 sql answer 2개와 shell answer 5개도 함께 고쳤다.
- develop의 page batch 실행(CBRD-27361)은 heap record의 bytes에서 column 값을 바로 읽는다. 그래서 OOS 값이 있는 record에서는 잘못된 값을 읽었다. `dcf38cb0a`부터는 이런 record를 row 단위 경로로 처리한다. 이 문제는 `test_sql_by_cci`가 아니라 OOS 단위 테스트(`test_oos_sql_workspace_bytes`)에서 발견했다.

### 동기화 후 결과

1차 동기화 후 PR #7990에서 `/run sql_by_cci`를 실행했다([run 42763653366](https://github.com/CUBRID/cubrid/actions/runs/42763653366), 엔진 `dcf38cb0a`). 실패는 34건이고, 모두 develop run의 실패와 diff가 같다. 처음 57건 중 OOS에서만 실패하던 28건은 모두 통과했다.

2차 동기화 후 PR #7990에서 `/run all`을 실행했다([run 42785110884](https://github.com/CUBRID/cubrid/actions/runs/42785110884), 엔진 `50619ce53`).

| suite | 실패 | develop과 같은 실패 | OOS에서만 실패 |
|---|---|---|---|
| `test_medium` | 0 | 0 | 0 |
| `test_sql` | 2 | 2 | 0 |
| `test_sql_by_cci` | 38 | 38 | 0 |
| `test_shell` | 4 | 1 | 3 (answer 미갱신, 고친 뒤 재실행에서 0) |

- 비교 기준은 같은 날 develop 대상 PR run 3개다. [42807018862](https://github.com/CUBRID/cubrid/actions/runs/42807018862)(#8409), [42790013637](https://github.com/CUBRID/cubrid/actions/runs/42790013637)(#8356), [42784848562](https://github.com/CUBRID/cubrid/actions/runs/42784848562)(#8168)이다. `test_sql_by_cci`는 develop 대상 PR run 7개(#8019, #8424 등)를 더 썼다.
- 실패한 case마다 JUnit XML diff에서 `+` 줄 집합과 `-` 줄 집합을 뽑아 develop run의 같은 case와 비교했다. 줄 안의 공백은 하나로 줄였다. `test_sql` 2건과 `test_sql_by_cci` 38건 모두 develop run 하나 이상과 diff가 같다.
- `test_shell`의 `cbrd_27571.sh`는 develop run 2개(#8409, #8168)에서도 같은 단계에서 실패한다. 서버 재시작이 `log_append_compensate_internal`의 `Assertion 'false'`로 멈춘다. 다른 것은 assertion의 줄 번호(develop 3202, OOS 3214)뿐이다.
- `test_shell`에서 OOS에서만 실패한 3건(`bug_bts_9836`, `bug_bts_14120`, `bug_bts_15529`)은 `call_stack_dump_activation_list` 기본값의 출력만 다르다. 엔진은 새 OOS code `-1395,-1397,-1398`을 출력하는데, answer에는 이전 번호 `-1387,-1389,-1390`이 남아 있었다. private-ex `8ef4f6278`이 answer 5개를 고쳤다. 그 뒤 PR #7990의 `/run shell`([run 42819814597](https://github.com/CUBRID/cubrid/actions/runs/42819814597))에서 세 case 모두 통과했고, 실패는 `cbrd_27571.sh` 1건만 남았다.

### 판단

OOS 엔진이 고쳐야 할 `test_sql_by_cci`·`test_sql`·`test_shell`·`test_medium` 실패는 없다. 처음 57건은 develop 미동기화 때문에 생겼고, 동기화로 해소되었다. 남은 실패 41건(`test_sql` 2, `test_sql_by_cci` 38, `test_shell` 1)은 develop에서도 같은 출력으로 실패한다.

### 계속 추적

develop을 merge할 때마다 같은 종류의 실패가 다시 생길 수 있다. 이번에 두 번 생긴 것은 다음과 같다.

- develop이 error code를 새로 써서 OOS error code 번호가 밀리면, 그 번호가 들어 있는 sql·shell answer도 바꿔야 한다. 1차·2차 동기화에서 모두 생겼다.
- develop의 새 실행 경로가 heap record bytes를 직접 읽으면 OOS 값을 잘못 읽을 수 있다. page batch(CBRD-27361)에서 생겼다.

PR #7990에서 run을 돌릴 때마다 [oos-ci-compare.py](https://github.com/vimkim/my-cubrid-docs/blob/f8e725f/cbrd-oos-sql-by-cci/tools/oos-ci-compare.py)로 같은 날의 develop 대상 PR run과 비교한다. 실패한 case를 `same`(develop과 diff가 같음), `differs`(develop에서도 실패하지만 diff가 다름), `oos-only`로 나눈다. `differs`나 `oos-only`가 나오면 원인을 확인하고 이 이슈에 결과를 남긴다. `oos-only`가 OOS 엔진 결함이면 별도 이슈로 나눈다.

### 한계

- 기준선은 develop 대상 PR run이며, develop push run과는 비교하지 않았다. 각 PR의 변경이 일부 case에 영향을 줄 수 있어 run 여러 개를 함께 썼다.
- 엔진 결과가 develop과 달랐던 10건이 develop의 어느 commit으로 해소되었는지는 bisect로 확인하지 않았다.
- `test_sql`은 debug build, `test_sql_by_cci`는 release build로 실행한다.
- develop은 계속 바뀐다. 2026-11-10 기준으로 `feature/oos-merge`는 develop보다 1 commit(`e30370dc0`, CBRD-27938) 뒤에 있다.

## References

- 상위 이슈: [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) OOS TODO
- 관련 이슈: [CBRD-27403](https://jira.cubrid.org/browse/CBRD-27403). 이전 develop merge 때 같은 방식으로 OOS error code 번호를 바꾸고 answer를 갱신했다.
- 분석 보고서: [cbrd-oos-sql-by-cci/report.md](https://github.com/vimkim/my-cubrid-docs/blob/f8e725f/cbrd-oos-sql-by-cci/report.md). 실패 case 목록, develop 동기화 결과, 2차 동기화와 전체 run 결과가 있다.
- 처음 분석: [PR #8434 test_sql_by_cci CI 분석](https://github.com/vimkim/my-cubrid-docs/blob/d009ff1a2759fb237e81c2684443b558bf474e5e/cbrd-27781/ci-analysis-sql-by-cci.md)
- 최종 확인 대상: PR [#7990](https://github.com/CUBRID/cubrid/pull/7990) head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, testcase `tc/pr-7990`(`b53a7984c`, private-ex `8ef4f6278`)
