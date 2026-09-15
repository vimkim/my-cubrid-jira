# [LOADDB] Server-side loaddb의 파티션 범위 위반 행 저장

## Issue Triage

**이슈 수행 목적**: server-side loaddb가 대상 파티션에 속하지 않는 행을 거부하고 실패 상태를 반환하도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| AS-IS (현재 동작 / 배경) | `i < 10`인 파티션에 `1, 100`을 load하면 범위 밖 값까지 성공 커밋한다. |
| TO-BE (목표 상태 / 기대 동작) | 파티션 오류를 반환하고, 중간 커밋 없는 해당 실패 배치의 행을 남기지 않는다. |
| 영향 | 설계 의도 훼손 — 파티션 정의를 위반한 데이터가 저장되며 기존 회귀 테스트도 이 결과를 성공으로 기대해 검출하지 못한다. |

**이슈 수행 방안**: 앞서 승인한 TC 기대값 정정과 재실행을 완료했다(사용자 인용: "yes"). 오류 반환, 실패 직후 행 수, 후속 정상 load 결과를 검사하는 패치를 확보했다. 엔진의 구체적인 수정 위치와 방식은 `TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI가 재현 결과와 소스를 확인해 작성한 상세 자료다. 구현·리뷰 시 참고한다.

### 변경 범위

확인한 범위는 Linux의 client-server 방식 `loaddb -C`와 range 파티션이다. 관련 엔진 모듈은 `src/loaddb/`이며, TC 변경은 `partition_tbls.sh`와 Linux/Windows answer 두 파일이다. 다른 파티션 방식, standalone 실행, Windows 런타임의 영향은 확인하지 않았다.

## Description

`unloaddb`가 만든 object 파일은 `%class`로 행을 적재할 테이블을 지정한다. 여기에는 부모 테이블뿐 아니라 `t__p__p0`처럼 실제 행을 보관하는 개별 파티션도 들어간다. 기존 test2는 정상 데이터를 unload한 뒤 object 파일 끝에 잘못된 행을 덧붙여 오류를 유도한다.

이번 확인에서는 전체 출력 차이와 별개로 부모 테이블과 개별 파티션을 각각 조회했다. 비교 대상으로 실행한 SQL INSERT는 동일한 값을 거부했다. 이 차이를 통해 단순히 오류 문구가 빠진 경우와 실제 저장 결과가 잘못된 경우를 구분했다.

서버 로더는 일반 SQL INSERT와 별도의 삽입 경로를 사용한다. [load_server_loader.cpp의 일괄 삽입 호출](https://github.com/CUBRID/CUBRID/blob/ba88e4700a89526b015bcda9628a1c43b3a52176/src/loaddb/load_server_loader.cpp#L802)은 확인했으나, 이번 조사에서 검증이 빠지는 정확한 지점을 추적하지는 않았다. 근본 원인은 `TBD`이다.

로더가 성공 커밋한 상황이므로, 실패 배치가 비어 있어야 한다는 검사가 실패했다고 해서 rollback 구현 자체의 결함으로 단정하지 않는다.

## Test Build

| 항목 | 값 |
|---|---|
| CUBRID 버전 | `11.5.0.2575-ba88e47`, 64-bit debug build |
| 엔진 기준 | `develop` / `ba88e4700a89526b015bcda9628a1c43b3a52176` |
| 운영체제 | Rocky Linux 9.6, x86_64 |
| 빌드·실행 | GCC debug 빌드·설치 후 실행, 별도 설치 복사본과 DB 사용 |
| 실행 격리 | user/PID/network/IPC/UTS namespace |
| TC 기준 | `cubrid-testcases-private-ex` develop `48250d60cf8cece13abaff0f1b29982c59a256c0` |
| CCI | `ef5470ffae4aa934425145e393fefc81899c84a7` — 기존 submodule 상태로, 엔진의 pinned revision과 다름 |
| JDBC | `20aeb347b4d82ae74d89fe263141b044b52eb5b9` |

엔진 소스는 수정하지 않았다. 실제 실행한 서버와 복사 전 바이너리의 SHA-256이 일치함을 확인했다.

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

## Actual Result

| 검사 | 실제값 |
|---|---|
| 오류 입력 load | 종료 코드 0, `Total 2 object(s) inserted, 0 object(s) failed.` |
| 부모와 개별 파티션 조회 | 각각 `1`, `100` |
| 후속 정상 load | 종료 코드 0, 최종 저장값 `1`, `1`, `100` |
| SQL INSERT 비교 | 종료 코드 1, `Appropriate partition does not exist` |

## Additional Information

### 회귀 테스트 수정 및 결과

대상은 `shell/_35_cherry/issue_21654_server_side_loaddb/partition_tbls/cases/partition_tbls.sh`이다.

| 검증 | 원본 TC | 수정 TC |
|---|---|---|
| CTP 실행 / 실패 / skip | 1 / 0 / 0 | 1 / 1 / 0 |
| test2 오류 상태·오류 문구·빈 배치 검사 | 없음 | 실패 |
| 후속 정상 load 명령 | 검사 없음 | 성공 |
| 후속 load 이후 정확한 한 행 검사 | 없음 | 실패 |
| test1/test3 정상 출력 비교 | 통과 | 통과 |
| 마지막 스키마·10,000행 비교 | 통과 | 통과 |

CTP(회귀 테스트 실행 도구)의 testcase 자동 갱신과 재시도는 비활성화했다. launcher 종료 코드만으로 판정하지 않고 선택한 TC의 실행 수와 최종 assertion을 확인했다. 수정본은 9개 검사 중 3개 통과, 6개 실패이다. `bash -n`, `git diff --check`, Standards/Spec 검토를 완료했다. Windows answer에서도 test2 블록만 제거했으며 Windows 실행은 하지 않았다.

[원본 오류 유도 코드](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/48250d60cf8cece13abaff0f1b29982c59a256c0/shell/_35_cherry/issue_21654_server_side_loaddb/partition_tbls/cases/partition_tbls.sh#L47)와 [기존 성공 기대값](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/48250d60cf8cece13abaff0f1b29982c59a256c0/shell/_35_cherry/issue_21654_server_side_loaddb/partition_tbls/cases/bug_bts_11093.answer#L43)을 함께 정정해야 한다. TC 패치는 로컬에 작성되어 있으며 아직 커밋·push하지 않았다.

### 보존 자료와 미확인 범위

원본·수정 CTP 로그, 최소 재현 명령별 종료 코드·실제 저장값, 실행 바이너리 hash, TC patch를 보존했다. 작성자 로컬 자료는 다음 경로에 있으며 이 이슈의 재현 절차는 해당 경로에 의존하지 않는다.

- 보고서: `/home/vimkim/gh/my-cubrid-docs/partition-loader/develop-partition-tc-ba88e470_codex.md`
- 증거·패치: `/home/vimkim/gh/my-cubrid-docs/partition-loader/develop-partition-tc-ba88e470_codex/`

부모 테이블을 `%class t (i)`로 직접 지정한 보조 실험은 성공 출력과 조회 행 수가 일치하지 않았다. 해당 경로의 저장 위치·원인은 미확인이라 이 이슈의 직접 재현 범위에 포함하지 않는다. 오류 범위를 넓히려면 별도 분석이 필요하다.
