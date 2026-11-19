# [System Parameter] 서버가 클라이언트의 시스템 파라미터 변경 요청을 변경 가능 여부·범위·DBA 권한 검사 없이 적용한다

**한 줄 요약**: PR #8632(CBRD-28062, `oos_trigger_threshold` 파라미터 추가)의 리뷰에서 소스로 확인한 기존 결함이다. 시스템 파라미터 변경의 검사(사용자가 바꿀 수 있는 파라미터인지, 값이 범위 안인지, DBA인지)는 클라이언트에만 있고, 서버는 받은 값을 그대로 적용한다. 이 이슈는 서버가 변경 요청을 스스로 검증하도록 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 서버가 클라이언트에게서 받은 시스템 파라미터 변경을, 정상 클라이언트가 하는 것과 같은 규칙(실행 중 변경 허용 여부, 값 범위, DBA 권한)으로 검사하고, 규칙에 어긋나면 거부한다.

**이슈 수행 이유**: `SET SYSTEM PARAMETERS` 나 csql `;set` 으로 서버 파라미터를 바꾸면, 클라이언트가 먼저 세 가지를 검사한 뒤 `NET_SERVER_PRM_SET_PARAMETERS` 요청을 보낸다. 서버의 처리 함수는 요청을 풀어 그대로 `sysprm_set_value ()` 로 적용한다. 서버가 보는 것은 파라미터가 서버용이나 세션용인지뿐이다. 이 요청에는 권한 속성(`CHECK_AUTHORIZATION`)도 없다. 그래서 정상 클라이언트를 거치지 않고 요청을 직접 보내는 클라이언트는 실행 중 바꿀 수 없는 정적 파라미터를 포함해 서버 파라미터를 범위 밖 값으로 바꿀 수 있다. 소스 판독으로 확인했고(develop `1ecb2e7f37`), 실행으로 재현하지는 않았다.

**영향**: 조작된 클라이언트가 서버에 접속할 수 있으면, 서버의 파라미터 값이 운영자가 설정하지 않은 값, 그리고 부팅 때 검사를 통과할 수 없는 값이 될 수 있다. 값을 쓸 때마다 다시 읽는 파라미터는 바로 동작이 바뀐다. 예를 들어 `feature/oos-merge` 에 들어갈 `oos_trigger_threshold`(CBRD-28062)는 행 저장 형태를 정할 때마다 읽힌다. 이 값의 범위 검사는 부팅 때 `heap_manager_initialize ()` 한 곳에만 있으므로, 실행 중에 바뀐 값은 검사를 거치지 않는다. 표준 클라이언트(csql, 브로커, JDBC 등)를 쓰는 사용자에게는 생기지 않는다. 실제로 이 경로를 쓰는 조작 클라이언트나 공격 사례는 알려진 것이 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 정상 경로: 검사는 클라이언트에만 있다

develop `1ecb2e7f37` 기준이다. `feature/oos-merge` 와 PR #8632 head `44dab49185` 에도 같은 코드가 있다(줄 번호만 다르다).

| 검사 | 위치 (클라이언트) |
|---|---|
| 실행 중 바꿀 수 있는 파라미터인가(`PRM_USER_CHANGE`) | `sysprm_validate_change_parameters ()`, [system_parameter.c:7739](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L7739) |
| 값이 범위 안인가(`prm_check_range ()`) | `sysprm_generate_new_value ()`, [system_parameter.c:9082](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L9082) 이하 |
| 서버 파라미터를 바꾸는 사용자가 DBA 그룹인가 | `db_set_system_parameters ()`, [db_admin.c:3261](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/compat/db_admin.c#L3261) |

### 서버 경로: 받은 값을 그대로 적용한다

- 요청 표에서 `NET_SERVER_PRM_SET_PARAMETERS` 는 처리 함수만 등록하고 `action_attribute` 를 두지 않는다([network_sr.c:564-565](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/communication/network_sr.c#L564-L565)). 그래서 서버의 DBA 검사가 적용되지 않는다.
- `sprm_server_change_parameters ()`([network_interface_sr.cpp:8617](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/communication/network_interface_sr.cpp#L8617))는 `sysprm_unpack_assign_values ()` 로 요청을 풀고 `xsysprm_change_server_parameters ()` 를 부른다.
- `xsysprm_change_server_parameters ()` 는 `sysprm_change_parameter_values (assignments, true, true)` 만 부른다([system_parameter.c:8642](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L8642)).
- `sysprm_change_parameter_values ()`([system_parameter.c:7904-7930](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L7904-L7930))는 서버에서 파라미터가 서버용이나 세션용인지만 보고 `sysprm_set_value ()` 로 적용한다. 함수 주석도 "새 값이 유효한지 검사하지 않으므로 먼저 검증하라"고 적고 있다.
- 같은 풀기 함수는 클라이언트가 보낸 파라미터 번호의 범위도 확인하지 않고 `GET_PRM (prm_id)` 로 파라미터 정의를 읽는다([system_parameter.c:12064](https://github.com/CUBRID/cubrid/blob/1ecb2e7f3753e4f9fb4b79b5a421d8dbcc769c08/src/base/system_parameter.c#L12064)). 범위 밖 번호는 파라미터 표 밖을 읽는다(소스 판독).

### 영향을 받는 파라미터의 예

- 실행 중 다시 읽는 파라미터는 바뀐 값이 바로 쓰인다.
- 정적 파라미터 중 쓸 때마다 읽는 것도 있다. `oos_trigger_threshold`(PR #8632, `feature/oos-merge` 대상)는 `heap_oos_inline_target_size ()` 가 행 저장 형태를 정할 때마다 읽는다. 허용 범위(페이지 크기별 자동 목표값 이상, 한 페이지 레코드 최대 크기 이하)는 부팅 때만 검사한다. PR #8632 리뷰에서는 이 값이 바뀌면 이미 OOS로 옮겨진 `_db_serial` 행이 제자리에서 다시 커질 수 있다는 것도 확인했다(CBRD-28073 참고). 실행 중에 이 경로로 값을 바꾸는 시험은 하지 않았다.
- 부팅 때 한 번만 읽는 파라미터는 서버 메모리의 값만 바뀌고 동작에는 영향이 없을 수 있다. 파라미터별 영향은 확인하지 않았다.

### 관련 이슈

- CBRD-28264는 `network_interface_sr.cpp` 의 요청 처리 함수들이 클라이언트 값을 검증하지 않는 문제를 모은 이슈다. 권한 속성이 없는 요청(3-7)과 세션 파라미터 자료형(C1)을 다루지만, 이 요청(`NET_SERVER_PRM_SET_PARAMETERS`)은 목록에 없다. 같은 종류의 문제이므로 해결 방향을 함께 정할 수 있다.
- CBRD-28136: 관리자·복제 클라이언트 유형이 비밀번호 증명 없이 사용자를 등록하는 문제다. 서버의 DBA 검사를 이 요청에 붙이더라도, 이 문제가 남아 있으면 조작 클라이언트를 막는 효과가 제한된다.
- CBRD-28062: 이 결함을 찾은 PR #8632의 이슈다.

### ANALYSIS에서 확인할 것

- 서버에서 할 검사의 범위: 클라이언트의 세 검사를 서버에서 다시 할지, 서버 파라미터 변경 요청에 `CHECK_AUTHORIZATION` 을 붙일지. CBRD-28264 3-7은 `CHECK_AUTHORIZATION` 이 등록된 사용자 이름에 기대므로 조작 클라이언트에게 큰 장벽이 아니라고 적었다.
- 정상 클라이언트가 검사 뒤에 의도적으로 보내는 값(예: `PRM_TEST_CHANGE_ONLY` 를 test mode에서 바꾸는 경우)을 서버 검사가 막지 않는지.
- 실제 조작 요청으로 정적 파라미터가 바뀌는지 실행으로 확인한다.
