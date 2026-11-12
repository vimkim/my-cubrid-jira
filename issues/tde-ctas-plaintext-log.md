# [TDE] CREATE TABLE ... ENCRYPT AS SELECT가 넣은 행과 index key가 평문 로그로 남는다

**한 줄 요약**: [PR #8454](https://github.com/CUBRID/cubrid/pull/8454)(CBRD-27937) 리뷰 중 실행으로 확인한 문제다. `CREATE TABLE ... ENCRYPT AS SELECT` 로 만든 암호화 테이블의 행과 index key가 로그 볼륨에 평문으로 남는다. 이 경로의 로그도 암호화되도록 고친다.

## Issue Triage

**이슈 수행 목적**: CTAS로 만든 암호화 테이블에 들어가는 행과 index key를 담은 로그를 다른 암호화 테이블의 로그처럼 암호화하여, 활성 로그와 보관 로그에 평문이 남지 않게 한다.

**이슈 수행 이유**: CTAS는 SELECT 결과를 새 테이블에 먼저 삽입하고, 테이블의 heap 파일과 index 파일에 TDE 알고리즘을 적용하는 일은 그 뒤에 한다. 삽입하는 동안에는 두 파일이 아직 암호화 대상이 아니므로, 삽입 로그가 암호화 표시 없이 기록된다. develop과 PR #8454 head 빌드에서 2,000행 CTAS 뒤 로그 볼륨에서 행 수만큼의 평문 마커를 반복해서 찾았다. 같은 테이블을 먼저 만들고 `INSERT ... SELECT` 로 채우면 마커는 나오지 않는다.

**영향**: TDE는 데이터 볼륨이나 로그 파일이 유출되어도 키 없이는 암호화 테이블의 내용을 읽을 수 없게 하는 기능이다. 매뉴얼도 암호화 테이블과 관련된 모든 로그를 활성 로그와 보관 로그에서 암호화한다고 설명한다. 이 결함으로 CTAS로 만든 테이블의 초기 데이터 전체가 로그 파일에 평문으로 남아, 로그 파일을 읽을 수 있는 사람이 그 값을 볼 수 있다. CTAS는 기존 테이블에서 암호화 테이블로 데이터를 옮길 때 흔히 쓰는 방법이라, 민감한 데이터를 암호화 테이블로 옮기는 바로 그 작업이 평문을 남긴다. 운영 환경에서의 사용 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`do_create_entity ()` 는 CTAS의 SELECT 결과를 새 테이블에 넣는 [`execute_create_select_query ()`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/query/execute_schema.c#L10263-L10267) 를 먼저 호출한다. 클래스의 heap 파일과 index 파일에 TDE 알고리즘을 설정하는 [`file_apply_tde_to_class_files ()`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/query/execute_schema.c#L10308-L10311) 는 그 뒤에 호출한다.

로그 레코드는 대상 page가 TDE page일 때만 암호화 대상으로 표시된다. 삽입이 일어나는 동안에는 heap page와 B-tree page에 TDE 표시가 없으므로, 행 전체를 담은 heap 삽입 로그와 key를 담은 B-tree 로그가 모두 평문으로 기록된다. 실험에서 primary key가 있는 CTAS의 마커 수가 행 수의 약 세 배인 것은 heap 레코드와 index key가 함께 남기 때문으로 보인다. 이 해석은 로그 레코드 단위로 확인하지 않았다.

로그 암호화는 레코드가 아니라 로그 page 단위로 적용된다. 그래서 같은 로그 page에 암호화 대상 레코드가 함께 있으면 평문이 가려지고, 마커 수는 실행마다 조금씩 다르다. CTAS가 끝나면 `db_class.tde_algorithm` 은 `AES` 로 보이므로, 사용자는 테이블이 처음부터 암호화되었다고 생각하게 된다.

CBRD-27937과 PR #8454는 `LOG_MAY_CONTAIN_USER_DATA` 목록에서 빠진 recovery index를 추가한다. 이 문제는 그 목록과 상관없이, 파일에 TDE가 적용되기 전에 로그가 기록되는 순서 때문에 생긴다. 그래서 PR #8454를 적용해도 남는다.

## Test Build

- CUBRID `develop` `2b1db6ca296db20d6bc86eba9f7f69e1866ae10e` (`11.5.0.2855-2b1db6c`), Linux 64bit debug 빌드
- [PR #8454](https://github.com/CUBRID/cubrid/pull/8454) head `3ee2faece234768fe158986b4ff7e7960ac6c999` (`11.5.0.2856-3ee2fae`), Linux 64bit debug 빌드
- 기본 파라미터와 16KB page를 썼고 HA는 사용하지 않았다. release 빌드와 다른 릴리스 브랜치는 시험하지 않았다.

## Repro

준비 사항은 다음과 같다.

- CUBRID 환경 변수(`CUBRID`, `CUBRID_DATABASES`, `PATH`, `LD_LIBRARY_PATH`)가 설정되어 있다.
- `tdectas` 라는 데이터베이스가 없다.

방법은 다음과 같다. 테이블마다 다른 ASCII 마커를 값의 앞부분에 넣고, 활성 로그(`tdectas_lgat`)와 보관 로그(`tdectas_lgar*`)에서 마커가 나온 횟수를 센다. `plain_ins` 는 같은 암호화 테이블을 먼저 만들고 `INSERT ... SELECT` 로 채우는 대조군이다. 마지막 `flush_t` INSERT는 앞선 로그를 디스크로 flush하는 커밋이다.

아래 스크립트를 `tde-ctas-log-leak-repro.sh` 로 저장하고 `bash tde-ctas-log-leak-repro.sh /path/to/workdir` 로 실행한다.

```bash
#!/usr/bin/env bash
set -euo pipefail

DB=tdectas
WORK=$(realpath -m "${1:-./tdectas-work}")
mkdir -p "$WORK/db"
cd "$WORK/db"

count() { cat "${DB}_lgat" "${DB}_lgar"[0-9]* 2>/dev/null | grep -a -o "$1" | wc -l || true; }

cubrid createdb --db-volume-size=20M --log-volume-size=20M "$DB" en_US.utf8 < /dev/null > "$WORK/createdb.out" 2>&1
cubrid server start "$DB" < /dev/null > "$WORK/server-start.out" 2>&1

csql -u dba "$DB" > "$WORK/csql.out" 2>&1 <<'SQL'
create table ctas_pk (s varchar(200) primary key) encrypt
  as select 'CTASPKMARK' || lpad(rownum, 6, '0') as s from db_class a, db_class b, db_class c limit 2000;
create table ctas_noidx (s varchar(200)) encrypt
  as select 'CTASNOIDXMARK' || lpad(rownum, 6, '0') as s from db_class a, db_class b, db_class c limit 2000;
create table plain_ins (s varchar(200) primary key) encrypt;
insert into plain_ins select 'INSSELMARK' || lpad(rownum, 6, '0') from db_class a, db_class b, db_class c limit 2000;
create table flush_t (a int);
insert into flush_t values (1);
SQL

csql -u dba "$DB" -l -c "select class_name, tde_algorithm from db_class where class_name in ('ctas_pk', 'ctas_noidx', 'plain_ins')" \
  | grep -E 'class_name|tde_algorithm'
echo "CTAS with primary key  CTASPKMARK:    $(count CTASPKMARK)"
echo "CTAS without index     CTASNOIDXMARK: $(count CTASNOIDXMARK)"
echo "CREATE + INSERT SELECT INSSELMARK:    $(count INSSELMARK)"

cubrid server stop "$DB" < /dev/null > /dev/null 2>&1
cubrid deletedb "$DB"
```

## Expected Result

세 테이블 모두 `tde_algorithm` 이 `AES` 이고, 세 마커 모두 로그 볼륨에서 0회 나온다.

## Actual Result

세 테이블 모두 `tde_algorithm` 은 `AES` 였다. 마커 수는 다음과 같다(2,000행).

| 경우 | develop `2b1db6c` | PR #8454 head `3ee2fae` |
|---|---|---|
| CTAS, primary key 있음 (`CTASPKMARK`) | 5,870 / 6,013 | 6,013 / 6,008 |
| CTAS, index 없음 (`CTASNOIDXMARK`) | 1,955 / 1,862 | 1,954 / 1,955 |
| `CREATE TABLE ... ENCRYPT` 후 `INSERT ... SELECT` (`INSSELMARK`) | 0 / 0 | 0 / 0 |

각 칸의 두 숫자는 위 스크립트를 두 번 실행한 결과다.

## Additional Information

ANALYSIS에서 확인할 사항은 다음과 같다.

- CTAS 중 heap page나 B-tree page가 `file_apply_tde_to_class_files ()` 전에 데이터 볼륨이나 double write buffer로 flush되면, 데이터 볼륨에도 평문 page가 남는지 확인한다. 이번 실험은 로그 볼륨만 검사했다. 데이터 볼륨에 평문이 기록되는 다른 경로는 CBRD-27780에서 다룬다.
- `CREATE TABLE ... ENCRYPT AS SELECT` 외에 파일에 TDE가 적용되기 전에 사용자 데이터를 기록하는 경로가 있는지 확인한다. 예를 들어 partition을 만들며 데이터를 옮기는 DDL이 있다.
- 관련 이슈: CBRD-27937(vacuum과 B-tree 삭제 로그의 TDE 목록 누락), CBRD-27942(B-tree 삭제 로그 key, CBRD-27937의 duplicate). 이 이슈는 두 이슈와 원인이 다르다.
