# [OOS] R-16 테스트 페이지의 남은 공간을 조회하는 helper 중복을 제거한다

**한 줄 요약**: 상위 이슈 CBRD-27881의 R-16 후보를 별도 하위 작업으로 추적하고, PR #8485가 구현한 페이지 공간 조회 helper 공유의 범위와 검증 결과를 기록한다.

## Issue Triage

**이슈 수행 목적**: OOS 단위 테스트 유지보수자가 페이지의 남은 공간을 조회하는 helper를 한 곳에서 관리하도록 한다.

**이슈 수행 이유**: 같은 helper가 단독 실행(SA) 테스트 2개 파일과 서버(SERVER) 테스트 3개 파일에 복사돼 있다. 각 파일은 같은 페이지 조회 규칙을 따르므로, 규칙을 수정할 때 다섯 복사본을 함께 고치고 대조해야 한다.

**영향**: 테스트 유지보수자는 helper 복사본과 호출부 26곳의 동작을 함께 확인해야 한다. 중복을 제거하면 페이지 고정과 반환 규칙을 고칠 위치가 한 곳으로 줄어든다.

**이슈 수행 방안**: R-16에서 정한 대로 기존 `test_oos_utils.hpp`에 helper를 모으고 thread pointer를 명시적으로 전달한다. 구현과 관련 Debug 검증은 PR #8485에 있으며, 이 하위 작업은 해당 변경의 리뷰와 병합을 추적한다.

---

## AI-Generated Context

## Description

상위 이슈는 [CBRD-27881](https://jira.cubrid.org/browse/CBRD-27881)이다. 이 하위 작업은 [R-16 후보](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#r-16)의 페이지 공간 조회 중복만 다룬다.

기존 [CBRD-27883](https://jira.cubrid.org/browse/CBRD-27883)은 두 fixture 헤더의 공용 helper를 새 헤더로 모은 [PR #8368](https://github.com/CUBRID/cubrid/pull/8368)로 완료됐다. 이번 변경은 그 공용 헤더를 사용해 테스트 파일 다섯 곳에 남은 `get_free_space_of_oid_page` 중복을 제거한다.

구현은 [draft PR #8485](https://github.com/CUBRID/cubrid/pull/8485)에 있다. 분석 기준은 `feature/oos-merge`의 `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, 검증한 구현은 `b8d6d6d606daaf301d42269c67b0bc83b4bddcc7`이다.

## Acceptance Criteria

- 테스트 파일의 중복 정의 5개를 제거하고 기존 공용 헤더의 helper 하나를 호출한다.
- 호출 26곳에서 같은 thread pointer와 OID를 전달하며 기존 assertion을 보존한다.
- 페이지 조회 조건, 읽기 latch, 실패 시 `-1` 반환과 페이지 반환 시점을 보존한다. 엔진의 저장·복구 동작은 변경하지 않는다.

## Verification

2026-11-11에 위 구현 커밋의 GCC Debug 빌드·설치와 프로젝트 코드스타일 검사가 통과했다. 소스 token 대조로 helper 본문과 호출부의 나머지 코드가 같음을 확인했다.

`test_oos_delete`, `test_oos_bestspace`, `test_oos_delete_server`, `test_oos_mock_vacuum_server`, `test_oos_vacuum_server`와 DB 준비·정리 fixture 2개가 CTest에서 7/7 통과했다. 전체 SQL·medium·shell 회귀와 release·sanitizer 검증은 실행하지 않았다. 구현과 이 하위 작업의 등록은 엔진 PR 병합 완료를 뜻하지 않는다.
