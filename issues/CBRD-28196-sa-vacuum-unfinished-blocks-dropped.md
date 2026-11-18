# [VACUUM] standalone 세션이 vacuum을 끝내지 못하고 종료하면 남은 vacuum 작업을 버린다

**한 줄 요약**: OOS 브랜치의 CBRD-28194 수정 중 develop의 standalone vacuum 경로를 검토하다 발견했다. develop은 standalone 세션이 vacuum을 끝내지 못한 채 종료할 때 남은 vacuum 작업을 완료된 것처럼 버린다. 생략, 중단, 작업 오류 모두 해당한다. 이 이슈는 그 작업을 다음 기동까지 보존하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: standalone(SA) 세션이 vacuum을 끝내지 못하고 종료하더라도 남은 vacuum 작업이 보존되어, 다음 서버나 SA 세션이 이어서 처리하게 한다.

**이슈 수행 이유**: develop debug 빌드에서 vacuum 작업이 남은 DB를 `csql -S --skip-vacuum`으로 열고 닫으면, 종료 중에 `vacuum_data_empty_update_last_blockid ()`의 `assert (vacuum_is_empty ())`로 csql이 비정상 종료한다(exit 134, core). SA 종료 경로(`vacuum_sa_reflect_last_blockid ()`)는 vacuum data가 비어 있다고 전제한다. 비어 있지 않아도 vacuum data 페이지를 초기화하고 마지막 log block까지 처리된 것으로 기록한다. vacuum 생략뿐 아니라 SA vacuum의 중단과 작업 오류도 같은 결과로 이어진다(아래 Description).

**영향**: debug 빌드에서는 SA 세션이 종료할 때마다 assert로 죽는다. 그래서 vacuum 문제를 피하려고 `--skip-vacuum`을 쓰는 개발자와 QA가 그 DB로 작업을 이어갈 수 없다. release 빌드는 실행하지 않았다. 코드상 release에서는 남은 block의 vacuum이 영구히 빠진다. 지운 행의 공간이 회수되지 않고, 인덱스의 MVCC 정보도 정리되지 않는다. 발생하려면 SA 세션이 시작될 때 vacuum 작업이 남아 있어야 하고, 세션은 vacuum을 생략하거나, 중단되거나, 작업 오류를 내야 한다. 실제 운영에서 얼마나 자주 생기는지는 모른다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경

SA 모드에서는 별도의 vacuum 스레드가 없다. SA 서버를 띄울 때 `boot_restart_server ()`가 `xvacuum ()`을 불러 남은 vacuum 작업을 한 번에 처리한다(`src/transaction/boot_sr.c:2668`). 아직 끝나지 않은 log block(partial block)도 마지막에 처리한다. `csql -S --skip-vacuum`은 이 단계를 건너뛴다(`boot_sr.c:3237-3242`). SA 세션이 끝날 때는 `vacuum_sa_reflect_last_blockid ()`(`boot_sr.c:3138`)가 "모든 vacuum이 끝났다"는 전제로 vacuum data를 정리한다.

아래 줄 번호는 develop `2e67e1d948`의 `src/query/vacuum.c` 기준이다. 실측한 develop `5b38db9`과 이 파일, `boot_sr.c`, `csql_launcher.c`의 내용이 같다.

### 문제 경로

1. **vacuum 생략(실측)**: `--skip-vacuum`이면 `xvacuum ()`이 돌지 않는다. 종료 시 `vacuum_sa_reflect_last_blockid ()`(7811)는 vacuum data를 확인하지 않는다. `log_Gl.hdr.vacuum_last_blockid`를 마지막 완료 block으로 올리고(7837-7838), `vacuum_data_empty_update_last_blockid ()`(7839)를 부른다. 이 함수는 debug에서 `assert (vacuum_is_empty ())`(7847)로 죽는다. release에서는 첫 vacuum data 페이지를 새로 초기화한다(`vacuum_init_data_page_with_last_blockid ()`, 7855). 남은 block 항목은 지워지고, 다음 기동은 그 block들을 이미 처리된 것으로 본다(코드 추론).
2. **SA vacuum 중단(코드)**: `xvacuum ()`은 사용자 중단을 받으면 완료하지 않은 채 `NO_ERROR`를 반환한다(1028-1032). 종료 시 1번과 같은 정리가 남은 block을 지운다.
3. **SA vacuum 작업 오류(코드)**: `vacuum_sa_run_job ()`은 `vacuum_process_log_block ()`의 반환값을 버린다(962).
   - 완료된 block의 작업이 실패하면, debug에서는 `vacuum_finished_block_vacuum ()`의 `assert (er_errid () == ER_INTERRUPTED)`(3774)에서 죽는다. release에서는 그 block을 다시 처리 대상으로 표시하지만 커서가 이미 지나갔다. `xvacuum ()`은 vacuum이 끝났다고 기록하고(RVVAC_COMPLETE 1087, `is_vacuum_complete` 1104), 종료 시 1번의 정리가 그 block을 지운다.
   - partial block의 작업이 실패해도, `xvacuum ()`은 작업 전에 `does_block_need_vacuum`을 끄고(1076) 작업 뒤 log header의 vacuum 정보를 초기화한다(1096). 그래서 그 block에서 처리하지 못한 레코드는 다시 처리되지 않는다.

### 검토했으나 develop에 없는 문제

OOS 브랜치는 "SA vacuum이 partial block 처리 중 실패하면, 이후 서버가 그 block을 완료 block으로 발행해 중단 표시 없이 처리한다"는 경우를 막으려고 표시(`interrupted_partial_blockid`)를 추가했다. 그러나 그 표시가 일반 재시작에도 붙어 CBRD-28194가 되었다. develop에서는 이 경우가 생기지 않는다. 위 3번처럼 실패한 partial block을 다시 발행하지 않고 버리기 때문이다. develop의 결함은 재처리가 아니라 작업 유실이다.

### 근거(실측)

| 엔진 | 시나리오 | 결과 |
|---|---|---|
| develop 5b38db9 (debug) | vacuum 작업이 남은 DB에서 `csql -S --skip-vacuum` | exit 134, `vacuum.c:7847: vacuum_data_empty_update_last_blockid: Assertion 'vacuum_is_empty ()' failed`, csql core |
| feature/oos-merge 기반 CBRD-28194 수정본 2c38bef (debug) | 같음 | exit 0 |

`cubrid vacuumdb -C --dump`로 서버 종료 직전에 vacuum 작업이 남은 것을 확인했다("First log page ID referenced = 403", 지운 테이블의 `Num_recs` 2572). OOS 브랜치는 SA 세션이 vacuum을 끝내지 못했으면 `vacuum_sa_reflect_last_blockid ()`에서 vacuum data를 보존하고 돌아온다.

### Repro

develop debug 빌드에서 서버 모드로 실행한다.

```sh
cubrid createdb x --db-volume-size=20M --log-volume-size=20M en_US
cubrid server start x
csql -u dba -c "create table t (a char(1000)); insert into t select lpad(rownum, 1000, 'T') from db_class a, db_class b, db_class c limit 20000;" x
# 오래된 snapshot을 잡아 vacuum이 DELETE를 끝내지 못하게 한다
( printf ';autocommit off\nselect count(*) from db_root;\n'; sleep 40 ) | csql -u dba --isolation-level=4 x &
sleep 3
csql -u dba -c "delete from t;" x
cubrid vacuumdb -C --dump x        # vacuum 작업이 남았는지 확인
cubrid server stop x
wait
csql -S --skip-vacuum -u dba -c "select 1 from db_root" x
echo $?                            # develop debug: 134 (assert)
```

### Expected Result

SA 세션이 정상 종료하고, 남은 vacuum 작업이 다음 기동에서 처리된다.

### Actual Result

debug에서는 csql이 종료 중 assert로 죽는다. release는 확인하지 않았으며, 코드상 남은 vacuum 작업이 기록 없이 사라진다.

### OOS 브랜치와의 관계

`feature/oos-merge`에는 이 경로를 고친 변경이 있다. PR #7990이 develop에 머지되면 함께 들어간다.

- `9c60e09ee`: SA vacuum이 작업 오류를 반환하고, 그 block을 완료로 기록하지 않으며, 실패한 partial block의 `does_block_need_vacuum`을 되살린다.
- `ff4dc0691a`의 SA_MODE 분기: `vacuum_sa_reflect_last_blockid ()`가 끝나지 않은 vacuum data를 보존한다.

이 변경들은 PR #7990 리뷰의 Greptile 지적에서 시작했다. vacuum 중 메모리 부족이 오류로 반환되어 재시도될 수 있어야 한다는 지적이다([discussion_r4374506877](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4374506877)). 같은 커밋 `ff4dc0691a`의 재시작 표시는 CBRD-28194에서 제거한다.

### ANALYSIS 확인 사항

- PR #7990 머지로 해결된 것으로 볼지, develop(과 지원 중인 release 브랜치)에 따로 반영할지 정한다.
- `9c60e09ee` 이후에는 실패한 partial block이 이후 세션에서 일반 block으로 다시 발행된다. SA partial 실행은 이미 중단 모드로 동작한다(`was_interrupted = data->was_interrupted () || sa_mode_partial_block`, 3358). 그래서 heap 페이지의 vacuum 상태를 ONCE에서 NONE으로 바꾸거나 처리할 레코드가 남은 페이지를 해제하지 않으므로, 다시 처리해도 안전하다고 추론한다(코드 추론, 실측 아님). 이 추론이 틀려 표시가 필요하다면, 그 표시는 log header처럼 재시작을 넘어 유지되어야 한다. 또한 실패한 SA partial 실행과 일반 재시작을 구별해야 한다. 메모리 변수를 `does_block_need_vacuum`에서 다시 만드는 방식은 둘을 구별하지 못한다(CBRD-28194).
- release 빌드에서 1-3번의 결과(남은 block 유실)를 실측한다.

### 관련 이슈

- [CBRD-28194](https://jira.cubrid.org/browse/CBRD-28194): OOS의 SA partial block 표시가 일반 재시작에도 붙어 heap 페이지가 반납되지 않는 결함.
- [CBRD-27966](https://jira.cubrid.org/browse/CBRD-27966): `vacuum_disable` 동안의 MVCC 로그 대부분이 vacuum되지 않는 결함. 남은 레코드와 checkdb assert의 결과가 비슷하지만 원인은 다르다.
- [CBRD-28118](https://jira.cubrid.org/browse/CBRD-28118): `emergency_patchlog -r`이 vacuum data를 비우지 않아 다음 기동에서 assert가 나는 결함. vacuum data와 log header의 정합성 문제라는 점에서 관련된다.
