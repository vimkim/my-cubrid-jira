# [LOADDB] Server-side loaddb의 파티션 범위 위반 행 저장

## Issue Triage

**이슈 수행 목적**: server-side loaddb가 대상 파티션에 속하지 않는 행을 거부하고 실패 상태를 반환하도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| AS-IS (현재 동작 / 배경) | `i < 10`인 파티션에 `1, 100`을 load하면 범위 밖 값까지 성공 커밋한다. |
| TO-BE (목표 상태 / 기대 동작) | 파티션 오류를 반환하고, 중간 커밋 없는 해당 실패 배치의 행을 남기지 않는다. |
| 영향 | 설계 의도 훼손 — 파티션 정의를 위반한 데이터가 저장되며 기존 회귀 테스트도 이 결과를 성공으로 기대해 검출하지 못한다. |

**이슈 수행 방안**: 근본 원인을 확인하고 엔진 수정을 완료했다. 수정 후 재현 스크립트에서 AS-IS/TO-BE를 직접 검증했고(아래 `Verified Result`), 회귀 TC는 수정 전 엔진에서 실패·수정 후 엔진에서 9/9 통과함을 확인했다. 엔진 PR: [CUBRID/CUBRID#7982](https://github.com/CUBRID/cubrid/pull/7982) (draft). TC 변경은 `cubrid-testcases-private-ex` 동반 PR로 관리한다.

---

## AI-Generated Context

> 아래는 AI가 재현 결과와 소스를 확인해 작성한 상세 자료다. 구현·리뷰 시 참고한다.

### 변경 범위

확인한 범위는 Linux의 client-server 방식 `loaddb -C`와 range 파티션이다. 엔진 수정은 `src/loaddb/load_server_loader.cpp` · `load_server_loader.hpp`와 `src/transaction/lock_manager.c`이며, TC 변경은 `partition_tbls.sh`와 Linux/Windows answer 두 파일이다. 다른 파티션 방식, standalone 실행, Windows 런타임의 영향은 확인하지 않았다. `%class`로 부모 partitioned 테이블 자체를 지정하는 경로는 이번 수정 대상이 아니며 기존 동작을 유지한다(별도 분석 필요).

## Description

`unloaddb`가 만든 object 파일은 `%class`로 행을 적재할 테이블을 지정한다. 여기에는 부모 테이블뿐 아니라 `t__p__p0`처럼 실제 행을 보관하는 개별 파티션도 들어간다. 기존 test2는 정상 데이터를 unload한 뒤 object 파일 끝에 잘못된 행을 덧붙여 오류를 유도한다.

이번 확인에서는 전체 출력 차이와 별개로 부모 테이블과 개별 파티션을 각각 조회했다. 비교 대상으로 실행한 SQL INSERT는 동일한 값을 거부했다. 이 차이를 통해 단순히 오류 문구가 빠진 경우와 실제 저장 결과가 잘못된 경우를 구분했다.

### 근본 원인 (확정)

서버 로더는 일반 SQL INSERT와 별도의 삽입 경로를 사용한다. `server_object_loader::flush_records`가 `pruning_type`(삽입 시 파티션 라우팅·검증 방식)을 `DB_NOT_PARTITIONED_CLASS`(=0)로 고정해 넘겼다. 그 결과 `locator_insert_force`의 파티션 검증 분기(`pruning_type != DB_NOT_PARTITIONED_CLASS`)가 통째로 건너뛰어지고, 행은 `%class`가 지정한 힙에 검증 없이 그대로 들어갔다. 로더가 성공 커밋했으므로 rollback 구현 자체의 결함은 아니다 — 애초에 오류가 발생하지 않아 rollback이 트리거되지 않았다.

### 수정 요약

- `load_server_loader`: `get_class_pruning_type()`를 추가해 `%class` 대상이 실제 파티션이면 `DB_PARTITION_CLASS`로 판정하고, 배치마다 계산한 `m_pruning_type`을 `locator_insert_force`/`locator_multi_insert_force`에 넘긴다. 이제 범위 밖 행은 `ER_PARTITION_NOT_EXIST`, 다른 파티션에 속한 행은 `ER_INVALID_DATA_FOR_PARTITION`로 거부되고 실패 배치는 abort로 롤백된다. 비파티션·부모 테이블 대상은 기존 동작을 유지한다.
- `lock_manager`: 검증을 켜면 파티션 성공 경로가 `lock_subclass`를 호출해 loaddb no-lock assert(`assert (thread_p->type != TT_LOADDB)`)를 건드린다. `lock_subclass`에 `lock_object`와 동일한 `TT_LOADDB` 우회를 추가했다(이미 보유한 BU 락이 subclass를 덮음). `TT_LOADDB`로 한정되어 일반 트랜잭션에는 영향이 없다.

## Test Build

| 항목 | 값 |
|---|---|
| 최초 조사 빌드 | `11.5.0.2575-ba88e47`, 64-bit debug build, 엔진 소스 미수정 |
| 수정·검증 빌드 | `develop` 리베이스 후 `109f16a`, 64-bit debug build, 엔진 3개 파일 수정 |
| 운영체제 | Rocky Linux 9.6, x86_64 |
| TC 기준 | `cubrid-testcases-private-ex` develop `48250d60cf8cece13abaff0f1b29982c59a256c0` + 로컬 TC 패치 |

AS-IS/TO-BE는 동일한 debug 빌드에서 수정을 되돌린 상태(AS-IS)와 적용한 상태(TO-BE)로 각각 재현해 비교했다.

## Repro

```bash
set -eu
repro_dir=$(mktemp -d /tmp/cbrd27441.XXXXXX)
db_name=cbrd27441_$$
cd "$repro_dir"

cubrid createdb --db-volume-size=20M --log-volume-size=20M "$db_name" en_US.utf8
trap 'cubrid server stop "$db_name"; cubrid deletedb "$db_name"' EXIT
cubrid server start "$db_name"

csql -u dba -c 'create table t(i int) partition by range(i) (partition p0 values less than (10));' "$db_name"

cat > invalid.objects <<'DATA'
%class t__p__p0 (i)
1
100
DATA

load_status=0
cubrid loaddb -C -v -u dba -d invalid.objects "$db_name" > invalid.output 2>&1 || load_status=$?
printf 'invalid load exit=%s\n' "$load_status"
cat invalid.output
csql -u dba -t -N -c 'select i from t order by i;' "$db_name"
csql -u dba -t -N -c 'select i from t__p__p0 order by i;' "$db_name"

cat > valid.objects <<'DATA'
%class t__p__p0 (i)
1
DATA

valid_status=0
cubrid loaddb -C -v -u dba -d valid.objects "$db_name" > valid.output 2>&1 || valid_status=$?
printf 'valid load exit=%s\n' "$valid_status"
cat valid.output
csql -u dba -t -N -c 'select i from t order by i;' "$db_name"

sql_status=0
csql -u dba -c 'insert into t values (100);' "$db_name" > sql.output 2>&1 || sql_status=$?
printf 'SQL INSERT exit=%s\n' "$sql_status"
cat sql.output
```

## Expected Result

| 검사 | 기대값 |
|---|---|
| 오류 입력 load | 종료 코드가 0이 아니며 `Appropriate partition does not exist` 오류 반환 |
| 오류 입력 직후 조회 | 부모와 개별 파티션 모두 0행 |
| 후속 정상 load | 종료 코드 0, 최종 저장값 `1` 한 행 |
| SQL INSERT 비교 | 파티션 오류 반환 |

## Actual Result (AS-IS, 수정 전)

| 검사 | 실제값 |
|---|---|
| 오류 입력 load | 종료 코드 0, `Total 2 object(s) inserted, 0 object(s) failed.` |
| 부모와 개별 파티션 조회 | 각각 `1`, `100` |
| 후속 정상 load | 종료 코드 0, 최종 저장값 `1`, `1`, `100` |
| SQL INSERT 비교 | 종료 코드 1, `Appropriate partition does not exist` |

수정 전 엔진에서 위 repro 스크립트를 실행한 실제 출력(로컬 경로 배너 제거). 빈 줄 뒤 숫자 줄은 순서대로 오류 load 직후 `select i from t`, `select i from t__p__p0`, 정상 load 후 `select i from t` 결과다.

```text
invalid load exit=0

Start object loading.
t__p__p0 2 instances committed
Total 2 object(s) inserted, 0 object(s) failed.

*** Updating class statistics ***
Class dba.t__p__p0

*** Closing the database ***
1
100

1
100

valid load exit=0

Start object loading.
t__p__p0 1 instances committed
Total 1 object(s) inserted, 0 object(s) failed.

*** Closing the database ***
1
1
100

SQL INSERT exit=1

In the command from line 1,

ERROR: Appropriate partition does not exist.
```

## Verified Result (TO-BE, 수정 후)

수정 후 엔진(`109f16a`)에서 동일 스크립트를 실행한 실제 출력. 모든 `Expected Result` 항목을 충족한다.

| 검사 | 실제값 (수정 후) | 기대 충족 |
|---|---|---|
| 오류 입력 load | 종료 코드 3, `Line 3:Appropriate partition does not exist.`, `Total 0 object(s) inserted, 1 object(s) failed.` | O |
| 오류 입력 직후 조회 | 부모·개별 파티션 모두 0행 | O |
| 후속 정상 load | 종료 코드 0, 최종 저장값 `1` 한 행 | O |
| SQL INSERT 비교 | 종료 코드 1, `Appropriate partition does not exist` | O |

```text
invalid load exit=3

Start object loading.
Line 3:Appropriate partition does not exist.
Total 0 object(s) inserted, 1 object(s) failed.
valid load exit=0

Start object loading.
t__p__p0 1 instances committed
Total 1 object(s) inserted, 0 object(s) failed.

*** Updating class statistics ***
Class dba.t__p__p0

*** Closing the database ***
1

SQL INSERT exit=1

In the command from line 1,

ERROR: Appropriate partition does not exist.
```

## Additional Information

### 회귀 테스트 수정 및 결과

대상은 `shell/_35_cherry/issue_21654_server_side_loaddb/partition_tbls/cases/partition_tbls.sh`이다. test2를 오류 상태·오류 문구·실패 배치 빈 행·후속 정상 load·정확한 한 행 검사로 재작성하고, 두 answer 파일(Linux/Windows)에서 기존 성공 기대 블록을 제거했다.

| 검증 | 원본 TC | 수정 TC |
|---|---|---|
| test2 오류 상태·오류 문구·빈 배치 검사 | 없음 | 있음 |
| 후속 정상 load 및 정확한 한 행 검사 | 없음 | 있음 |
| test1/test3 정상 출력, 마지막 스키마·10,000행 비교 | 통과 | 통과 |

수정한 TC의 assertion 결과:

- 수정 전 엔진: 9개 검사 중 3개 통과, 6개 실패 — TC가 버그를 정확히 검출함을 확인.
- 수정 후 엔진: 9개 검사 9개 모두 통과(CTP `Total Execution Case:1`, `Total Fail Case:0`).

CTP의 testcase 자동 갱신·재시도는 비활성화하고 launcher 종료 코드만으로 판정하지 않았다. `bash -n`, `git diff --check`, Standards/Spec 2축 코드 리뷰를 완료했다(모두 승인, 차단 지적 없음).

### 후속·미확인 범위

- 성능: 현재 구현은 행마다 파티션 컨텍스트를 다시 로드한다(상위 클래스 조회 포함). 대량 파티션 적재 오버헤드를 줄이려면 배치 동안 `PRUNING_CONTEXT`를 유지해 넘기는 최적화가 필요하며, 로더의 scancache 관리와 상호작용하므로 별도 작업으로 분리한다.
- 부모 테이블을 `%class t (i)`로 직접 지정한 보조 실험은 성공 출력과 조회 행 수가 일치하지 않았다. 이 경로의 저장 위치·원인은 미확인이라 이번 수정 범위에 포함하지 않는다.
- 상세 자료: `my-cubrid-docs`의 `cbrd-27441/CBRD-27441-validate-partition-range-server-loaddb_109f16a_claude.md`(엔진 PR 상세 설명 + AS-IS/TO-BE 재현 출력).
