# [misc] midxkey, copyarea, workspace 테스트 생성

## Issue Triage

**이슈 수행 목적**: 복합 인덱스 키 생성에서 OOS 임시 값의 수명과 COPY 의미를 검증하고, 현재 지원하는 copyarea 및 workspace 입력 경로의 회귀 테스트를 보완한다.

**이슈 수행 이유**: PR #8299의 기존 리뷰에서 midxkey OOS COPY를 제거한 변형이 테스트를 통과했다고 보고되었다. 최신 head의 소스와 테스트를 다시 확인해 이 수명 계약을 대상으로 한 보완 작업이 필요하다고 판단했다. 사용자의 요청에 따라 copyarea 및 workspace 경로의 테스트 보완도 같은 misc 이슈로 묶는다.

**영향**: 잘못된 COPY 또는 입력 경로 판정이 들어와도 테스트가 이를 검출하지 못할 위험이 있다. 현재 엔진의 잘못된 SQL 결과나 비정상 종료를 새로 재현한 것은 아니다. 기존 테스트가 다루는 동작과 추가로 보호할 동작을 구분한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 테스트 범위와 구현 방안을 결정한다.

---

## AI-Generated Context

> 아래는 독립 subagent의 소스 및 JIRA 검토를 종합한 맥락이다. 기존 리뷰의 mutation 결과와 이번 정적 검토를 구분한다. 이번 작업에서 새 테스트나 변형 엔진을 실행하지 않았다.

## Description

### 무엇이 문제인가

복합 인덱스 키를 만들 때 `heap_midxkey_get_value()`는 OOS 값을 임시 버퍼에 읽은 뒤 `DB_VALUE`로 변환한다. 작은 값은 이 함수의 stack scratch를 사용하고, 더 큰 값은 할당한 버퍼를 사용할 수 있다. 이 임시 저장 공간의 수명이 끝난 뒤에도 호출자가 값을 사용할 수 있어야 한다.

최신 검토 head에서는 `oos_owned_buffer`를 타입 reader의 COPY 인수로 전달한다. 현재 코드는 이 계약을 지키려는 구현이다. 이를 false로 바꿨을 때 압축하지 않은 VARCHAR reader가 원본 바이트를 빌리면, 반환한 값이 수명이 끝난 scratch나 해제된 버퍼를 가리킬 수 있다.

기존 리뷰는 midxkey의 COPY를 false로 바꾼 변형이 당시 테스트를 통과했다고 기록했다. 이후 추가된 scalar 읽기와 pending 값의 수명 테스트는 다른 호출 경로를 다루므로, midxkey 경로의 계약을 직접 고정했는지 별도로 확인해야 한다. 최신 head에서 같은 변형을 다시 실행한 결과는 아직 없다.

copyarea와 workspace는 구분되는 입력 개념이다. 공통 `locator_finalize_oos_record()`는 어느 쪽 입력이든 필요한 OOS 준비를 수행한다. 기존 테스트에는 두 플래그가 다른 조합의 bypass 및 실패 처리가 이미 있다. 이 작업에서는 그 테스트를 재사용하고, 실제 지원 경로에서 필요한 성공 처리와 owner 수명 검증의 추가 범위를 정한다.

초기 후보는 두 플래그가 다른 UPDATE 경로의 테스트였다. 그러나 현재 private `locator_update_force()`의 호출처 네 곳은 `(true, true)` 또는 `(false, false)`를 전달한다. 현재 생산하지 않는 UPDATE 인수 조합을 가정해 새 테스트를 요구하지 않는다. 별도 UPDATE 결함 이슈 대신 지원되는 copyarea 및 workspace 동작의 테스트 보완을 이 이슈에 포함한다.

### 왜 문제인가

엔진 개발자는 OOS 읽기와 인덱스 처리 코드를 변경한 뒤, 테스트를 통해 임시 버퍼 수명이 유지되는지 확인해야 한다. 반환 직후 우연히 남아 있는 stack 바이트만 읽는 테스트는 COPY가 제거돼도 성공할 수 있다. 압축된 문자열은 reader가 별도 메모리를 만들 수 있어, 압축되지 않은 값의 COPY 누락을 가릴 수 있다.

입력 경로도 실제 준비 및 저장 동작으로 구분해야 한다. 플래그를 서로 바꿔 전달하거나 준비 대상을 누락하는 변경이 관찰 가능한 결과를 바꾸는지 검증하면, 이후 경로 변경 시 테스트의 판별력을 확인할 수 있다. 현재 SQL 장애나 운영 발생 빈도를 주장하는 이슈는 아니다.

### 왜 해결해야 하는가

OOS 변경은 저장 위치와 값의 소유권을 여러 계층에 걸쳐 바꾼다. 현재 구현이 맞더라도 해당 계약을 고정하는 테스트가 없으면 이후 수정에서 같은 오류를 놓칠 수 있다. 기능 결함을 가정하는 대신, 현재 지원하는 입력과 값 수명을 보호하는 작은 테스트 작업으로 범위를 한정한다.

## Triage Request

[OOS TODO CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978)의 하위 작업으로 확인하고 테스트 보완의 ANALYSIS를 요청한다. 담당자는 사용자의 요청에 따라 `vimkim`으로 지정한다. [CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)의 midxkey COPY 후보와 copyarea 및 workspace 테스트 후보를 이 이슈에서 함께 추적한다.

## Specification Changes

SQL 의미, OOS 저장 형식 및 지원하는 입력 경로를 유지한다. 신규 UPDATE 플래그 조합을 기능으로 추가하지 않는다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 검토 대상은 `heap_midxkey_get_value()`, `locator_finalize_oos_record()` 및 `unit_tests/oos/sql`의 관련 테스트다. 기존 테스트로 충족하는 항목을 먼저 확인하고, 추가할 동작 검증을 정한다.

## Acceptance Criteria

- 압축하지 않은 OOS 문자열이 실제 midxkey 생성 경로를 통과함을 확인하고, 임시 저장 공간의 수명이 끝난 뒤 생성된 key의 값이 올바른지 판별한다.
- 정상 코드에서는 통과하고 해당 midxkey COPY만 제거한 변형에서는 실패하는 테스트를 제시한다. 우연한 stack 바이트 잔존에 의존하지 않도록 실패 조건을 통제한다.
- 실제 인덱스 크기 제한 안에서 도달할 수 있는 버퍼 경로를 확인한다. scratch와 할당 버퍼 중 도달 여부가 확인되지 않은 경우는 한계로 기록한다.
- 현재 지원하는 copyarea 및 workspace 입력에서 필요한 OOS 준비, owner 수명 및 저장 결과를 검증한다. 기존 bypass 및 실패 테스트가 이미 보호하는 범위는 구분한다.
- 유효한 일반 inline 값과 정상 NULL 처리의 결과도 유지한다.

## Definition of done

추가 또는 보완한 테스트를 정상 코드와 의도한 변형에 각각 실행하고, 대상 분기에 도달했는지와 실패 이유를 기록한다. 관련 OOS SQL 테스트의 실행 결과를 남긴다. 구현되지 않은 UPDATE 입력을 테스트할 필요가 생기면 그 기능 요구를 별도로 명시한다.

## Additional Information

- 검토 head는 PR #8299의 `5837393ffb9d69bccb93271d63b0e38b884e0ed4`, base는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다.
- [midxkey helper의 scratch 및 COPY 처리](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/storage/heap_file.c#L11749)와 [공통 OOS 입력 처리](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/transaction/locator_sr.c#L4921)를 확인했다.
- [기존 copyarea 및 workspace 테스트](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/unit_tests/oos/sql/test_oos_sql_deferred_write.cpp#L280)를 소스로 확인했다. 이는 이번에 테스트를 실행했다는 의미가 아니다.
- [기존 리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md)와 [공개 review harness](https://github.com/vimkim/cubrid/tree/CBRD-27785-review-harness), 커밋 `7472ed577850c13be1aed915691a35b6dec23b6b`가 과거 검토의 출처다.
- 기존 이슈 검색에서 [CBRD-26769](http://jira.cubrid.org/browse/CBRD-26769)는 OOS 오류 전파, [CBRD-26547](http://jira.cubrid.org/browse/CBRD-26547)은 covered index 값 처리, [CBRD-26565](http://jira.cubrid.org/browse/CBRD-26565)는 key 버퍼 크기를 다뤘다. 이번 테스트의 수명 계약과 범위가 다르다.
- [CBRD-27424](http://jira.cubrid.org/browse/CBRD-27424)와 [CBRD-27089](http://jira.cubrid.org/browse/CBRD-27089)는 지원되는 workspace 및 목적지별 deferred write 동작과 관련된다. 두 UPDATE 플래그가 다른 현재 호출처를 제시하는 이슈는 아니다.
