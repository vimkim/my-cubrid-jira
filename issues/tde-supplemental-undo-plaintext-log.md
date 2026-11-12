# [TDE] supplemental_log를 켜면 암호화 테이블에서 DELETE한 행이 평문 로그로 남는다

**한 줄 요약**: [PR #8454](https://github.com/CUBRID/cubrid/pull/8454)(CBRD-27937) 리뷰 중 실행으로 확인한 문제다. CDC를 위해 `supplemental_log` 를 켜면, 암호화 테이블에서 DELETE한 행 전체가 supplemental undo 로그에 평문으로 남는다. 이 로그도 암호화 테이블의 다른 로그처럼 암호화되도록 고친다.

## Issue Triage

**이슈 수행 목적**: `supplemental_log` 가 켜져 있어도 암호화 테이블의 행을 담은 supplemental 로그를 암호화하여, 활성 로그와 보관 로그에 평문이 남지 않게 한다.

**이슈 수행 이유**: `supplemental_log` 가 0보다 크면 서버는 CDC가 변경 전 값을 읽을 수 있도록 DELETE한 행의 이미지를 별도 supplemental 로그(`LOG_SUPPLEMENT_UNDO_RECORD`)로 남긴다. 이 로그는 recovery index 없이 기록되고 암호화 표시를 받지 않으므로, 테이블이 암호화되어 있어도 평문으로 남는다. develop과 PR #8454 head 빌드에서 `supplemental_log=1` 일 때 암호화 테이블의 2,000행을 DELETE하면 로그 볼륨에서 행 수에 가까운 평문 마커가 나왔다. `supplemental_log=0` 이면 같은 작업에서 마커가 나오지 않는다.

**영향**: TDE는 데이터 볼륨이나 로그 파일이 유출되어도 키 없이는 암호화 테이블의 내용을 읽을 수 없게 하는 기능이다. 매뉴얼도 암호화 테이블과 관련된 모든 로그를 활성 로그와 보관 로그에서 암호화한다고 설명한다. CDC를 쓰는 운영자는 이 결함 때문에 암호화 테이블에서 지운 행의 값이 로그 파일에 평문으로 남는다는 사실을 알 수 없다. 영향 범위는 `supplemental_log` 를 켠 데이터베이스로 한정된다. 그런 운영 환경이 얼마나 되는지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

heap 레코드를 삭제할 때 `check_supplemental_log ()` 가 참이면, heap은 [`log_append_supplemental_undo_record ()`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/transaction/log_manager.c#L5027-L5050) 로 삭제 전 레코드를 기록한다. 호출하는 곳은 다음 세 군데다.

- 일반 행 삭제: [`heap_file.c:23586`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/storage/heap_file.c#L23586)
- relocation된 행: [`heap_file.c:23162`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/storage/heap_file.c#L23162)
- overflow 행: [`heap_file.c:22679`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/storage/heap_file.c#L22679)

이 함수는 레코드 유형과 본문을 [`log_append_supplemental_info ()`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/transaction/log_manager.c#L4917-L4970) 에 넘기고, 이 함수는 `RV_NOT_DEFINED` 로 log node를 만들어 그대로 append한다. 다른 사용자 데이터 로그는 `LOG_MAY_CONTAIN_USER_DATA` 와 page의 TDE 표시를 확인한 뒤 `prior_set_tde_encrypted ()` 를 호출하지만, 이 경로에는 그런 확인이 없다. `check_supplemental_log ()` 도 테이블의 TDE 여부를 보지 않는다.

복제 로그는 클래스의 TDE 알고리즘을 [`heap_get_class_tde_algorithm ()`](https://github.com/CUBRID/cubrid/blob/2b1db6ca296db20d6bc86eba9f7f69e1866ae10e/src/transaction/replication.c#L383) 으로 읽어 암호화 여부를 정한다. supplemental 로그도 같은 정보를 쓸 수 있을 것으로 보이지만, 해결 방식은 ANALYSIS에서 정한다.

로그 암호화는 레코드가 아니라 로그 page 단위로 적용된다. 그래서 같은 로그 page에 암호화 대상 레코드가 함께 있으면 평문이 가려지고, 마커 수는 실행마다 다르다. 실험의 DELETE는 index가 없는 테이블에서 실행했다. 이 경우 같은 page에 함께 기록되는 heap 삭제 로그(`RVHF_MVCC_DELETE_REC_HOME`)는 MVCCID만 담고 암호화되지 않으므로, 평문이 거의 가려지지 않는다.

CBRD-27937과 PR #8454는 `LOG_MAY_CONTAIN_USER_DATA` 목록에서 빠진 recovery index를 추가한다. supplemental 로그는 recovery index를 쓰지 않으므로, PR #8454를 적용해도 이 문제는 남는다.

## Test Build

- CUBRID `develop` `2b1db6ca296db20d6bc86eba9f7f69e1866ae10e` (`11.5.0.2855-2b1db6c`), Linux 64bit debug 빌드
- [PR #8454](https://github.com/CUBRID/cubrid/pull/8454) head `3ee2faece234768fe158986b4ff7e7960ac6c999` (`11.5.0.2856-3ee2fae`), Linux 64bit debug 빌드
- 16KB page를 썼고 HA는 사용하지 않았다. `supplemental_log` 외의 파라미터는 기본값이다. release 빌드와 다른 릴리스 브랜치, CDC 클라이언트 연결은 시험하지 않았다.

## Repro

준비 사항은 다음과 같다.

- CUBRID 환경 변수(`CUBRID`, `CUBRID_DATABASES`, `PATH`, `LD_LIBRARY_PATH`)가 설정되어 있다.
- `tdesupp0`, `tdesupp1` 이라는 데이터베이스가 없다.
- 스크립트는 `CUBRID_CONF_FILE`(없으면 `$CUBRID/conf/cubrid.conf`)을 복사한 뒤 `supplemental_log` 만 바꾼 설정 파일을 만들어, 경우마다 `CUBRID_CONF_FILE` 로 지정한다.

방법은 다음과 같다. 같은 작업을 `supplemental_log=0`(대조군)과 `supplemental_log=1` 로 한 번씩 실행한다. 암호화 테이블에 마커를 넣은 2,000행을 INSERT한 뒤 한 번, 모두 DELETE한 뒤 한 번, 활성 로그와 보관 로그에서 마커가 나온 횟수를 센다. 각 측정 직전의 `flush_t` INSERT는 앞선 로그를 디스크로 flush하는 커밋이다.

아래 스크립트를 `tde-supplemental-log-leak-repro.sh` 로 저장하고 `bash tde-supplemental-log-leak-repro.sh /path/to/workdir` 로 실행한다.

```bash
#!/usr/bin/env bash
set -euo pipefail

WORK=$(realpath -m "${1:-./tdesupp-work}")
CONF_SRC=${CUBRID_CONF_FILE:-$CUBRID/conf/cubrid.conf}

count() { cat "$1/$2_lgat" "$1/$2_lgar"[0-9]* 2>/dev/null | grep -a -o "$3" | wc -l || true; }

run_case() {
  local db=$1 supplemental=$2 dir="$WORK/$1"
  mkdir -p "$dir"
  { cat "$CONF_SRC"; printf '\n[common]\nsupplemental_log=%s\n' "$supplemental"; } > "$WORK/$db.conf"
  export CUBRID_CONF_FILE="$WORK/$db.conf"
  (cd "$dir" && cubrid createdb --db-volume-size=20M --log-volume-size=20M "$db" en_US.utf8 < /dev/null > "$WORK/$db-createdb.out" 2>&1)
  cubrid server start "$db" < /dev/null > "$WORK/$db-server-start.out" 2>&1
  csql -u dba "$db" > "$WORK/$db-csql.out" 2>&1 <<'SQL'
create table s (id int, v varchar(200)) encrypt;
insert into s select rownum, 'SUPPMARK' || lpad(rownum, 6, '0') from db_class a, db_class b, db_class c limit 2000;
create table flush_t (a int);
insert into flush_t values (1);
SQL
  local after_insert after_delete
  after_insert=$(count "$dir" "$db" SUPPMARK)
  csql -u dba "$db" -c "delete from s" > /dev/null
  csql -u dba "$db" -c "insert into flush_t values (2)" > /dev/null
  after_delete=$(count "$dir" "$db" SUPPMARK)
  echo "supplemental_log=$supplemental: after INSERT $after_insert, after DELETE $after_delete"
  cubrid server stop "$db" < /dev/null > /dev/null 2>&1
  cubrid deletedb "$db"
}

run_case tdesupp0 0
run_case tdesupp1 1
```

## Expected Result

두 경우 모두 INSERT 뒤와 DELETE 뒤에 마커가 0회 나온다.

## Actual Result

| 경우 | develop `2b1db6c` | PR #8454 head `3ee2fae` |
|---|---|---|
| `supplemental_log=0`, INSERT 뒤 / DELETE 뒤 | 0 / 0 | 0 / 0 |
| `supplemental_log=1`, INSERT 뒤 / DELETE 뒤 | 0 / 1,555 | 0 / 1,253 |

같은 2,000행 DELETE를 쓴 별도 probe에서는 DELETE 뒤 마커가 develop 1,626회, PR #8454 head 1,297회였다.

## Additional Information

ANALYSIS에서 확인할 사항은 다음과 같다.

- `supplemental_log` 가 켜졌을 때 UPDATE와 relocation, overflow 행 삭제 경로에서도 같은 평문이 남는지 확인한다. 이번 실험은 index가 없는 테이블의 일반 행 DELETE만 시험했다.
- DDL 문장을 담는 `LOG_SUPPLEMENT_DDL` 과 HA 복제의 문장 로그도 암호화되지 않는다. 이 문장에 들어간 리터럴 값을 같은 범위에서 다룰지 결정한다. CREATE/ALTER USER 비밀번호가 이 로그에 평문으로 남는 문제는 CBRD-27986에서 다룬다.
- CDC가 supplemental 로그를 읽을 때 로그 page를 복호화하는지 확인한다. 엔진 리뷰의 소스 추적에서는 CDC가 복호화하는 `logpb_fetch_page ()` 를 쓰므로 암호화해도 호환된다고 보았지만, 실행으로 확인하지는 않았다.
- 관련 이슈: CBRD-27937(vacuum과 B-tree 삭제 로그의 TDE 목록 누락), CBRD-27942(B-tree 삭제 로그 key, CBRD-27937의 duplicate). 이 이슈는 두 이슈와 원인이 다르다.
