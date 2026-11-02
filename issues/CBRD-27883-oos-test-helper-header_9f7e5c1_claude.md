# [OOS] OOS 단위 테스트의 중복 helper를 한 header로 모으고 쓰이지 않는 SQL 테스트 helper를 제거한다

## Issue Triage

**이슈 수행 목적**: OOS 단위 테스트의 공용 helper를 한 곳에서 관리해, helper를 고칠 때 두 복사본을 함께 고치지 않아도 되게 한다.

**이슈 수행 이유**: `namespace test_oos_utils`의 helper 9개가 `test_oos_common.hpp`와 `test_oos_server_common.hpp`에 따로 들어 있다. 두 복사본은 이미 함수 순서, 중괄호, 주석이 서로 달라졌다. `test_oos_sql_common.hpp`의 `exec_sql_commit`과 `run_vacuum`은 호출하는 곳이 없다.

**영향**: 테스트 동작은 바뀌지 않는다. GitHub CI는 OOS 단위 테스트를 빌드하지 않으므로, 두 복사본이 서로 어긋나도 CI가 알려 주지 않는다.

**이슈 수행 방안**: helper를 새 `test_oos_utils.hpp`로 옮기고 두 공용 header가 include하게 한다. 쓰이지 않는 SQL 테스트 helper를 지운다. 구현은 PR https://github.com/CUBRID/cubrid/pull/8368 이다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 두 번째 단위이다.
- 검증: 두 복사본을 token 단위로 비교했고, `return {};` 주변 중괄호만 달랐다. OOS 관련 ctest 44개가 변경 전후 모두 통과했다. 바뀐 header를 쓰는 테스트 파일 28개를 ccache 없이 다시 컴파일했다.
