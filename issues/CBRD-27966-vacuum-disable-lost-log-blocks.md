# [VACUUM] vacuum_disable=yes 동안의 MVCC 로그가 마지막 log block만 남아, vacuum을 다시 켜면 그 이전 레코드가 영영 vacuum되지 않고 checkdb가 assert로 서버를 죽인다

**한 줄 요약**: OOS 대체 설계(Sidecar)의 테스트 중 발견한 develop 결함으로, `vacuum_disable=yes`로 서버를 돌리는 동안 생긴 MVCC 로그 중 마지막 log block(기본 31 페이지)만 vacuum 대상으로 남는다. 그래서 vacuum을 다시 켜도 그 이전 block의 삭제·삽입 레코드는 회수되지 않고, 다음 `checkdb`가 debug 빌드에서 `vacuum_check_not_vacuumed_rec_header ()`의 `assert (false)`로 서버를 종료시킨다.

## Issue Triage

**이슈 수행 목적**: vacuum을 잠시 끄고 작업한 뒤 다시 켜면, 꺼져 있던 동안의 MVCC 변경도 모두 vacuum되어 공간이 회수되고 checkdb가 정상 종료하게 한다.

**이슈 수행 이유**: develop `e64a04a79` debug 빌드에서 2만 행을 지우는 동안만 `vacuum_disable=yes`로 두었다가 되돌리면, `cubrid vacuumdb -S`를 돌린 뒤에도 heap에 죽은 레코드 18,597개가 남고 `cubrid checkdb -C`가 서버를 assert로 죽인다(같은 결과를 두 번 확인했다). 지운 양이 log block 하나 안에 들어가면(500행) 재현되지 않는다.

**영향**: `vacuum_disable`은 숨겨진(`PRM_HIDDEN`) 디버그용 파라미터이므로 주로 vacuum을 끄고 시험하는 개발자와 QA가 영향을 받는다. 꺼져 있던 동안 지운 레코드의 공간이 DB를 다시 만들 때까지 회수되지 않고, debug 빌드에서는 이후 checkdb가 매번 서버를 죽이므로 같은 DB로 검증을 이어갈 수 없다. release 빌드는 실행해 보지 않았다. 코드상 release에서는 assert 대신 checkdb가 오류(`DISK_INVALID`)를 보고할 것으로 추정한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

vacuum은 로그를 `vacuum_log_block_npages`(기본 31) 페이지 단위의 block으로 나눠 처리한다. 로그를 쓰는 쪽은 MVCC 로그 레코드마다 log header에 현재 block의 정보(`mvcc_op_log_lsa`, `oldest_visible_mvccid`, `newest_block_mvccid`, `does_block_need_vacuum`)를 갱신하고(`prior_update_header_mvcc_info ()`, `src/transaction/log_append.cpp`), 다음 block으로 넘어가면 `vacuum_produce_log_block_data ()`로 그 block을 vacuum data에 넘긴 뒤 header를 비운다(`prior_lsa_next_record_internal ()`, 1397-1405행).

`vacuum_disable=yes`이면 이 인계가 일어나지 않는다. 그러나 header 갱신은 계속된다.

- `vacuum_get_log_blockid ()`가 항상 `VACUUM_NULL_LOG_BLOCKID`를 돌려준다(`src/query/vacuum.c` 5729행). 그래서 1400행의 block 경계 비교가 늘 같다고 판단해 `vacuum_produce_log_block_data ()`를 부르지 않는다.
- 부르더라도 `vacuum_produce_log_block_data ()`는 첫 줄에서 그냥 돌아간다(2918행).
- 그 결과 log header는 꺼져 있던 기간 전체의 MVCC 로그를 하나의 block처럼 들고 있다. `mvcc_op_log_lsa`는 마지막 MVCC 레코드를 가리킨다.

vacuum을 다시 켜고 재시작하면 이 header 정보 하나가 vacuum job 하나가 된다(`vacuum_data_entry (const log_header &)`, 8171행). job은 `start_lsa`(= 마지막 MVCC 레코드)에서 `prev_mvcc_op_log_lsa`를 따라 거꾸로 가되, 그 레코드가 속한 block의 첫 페이지를 넘으면 멈춘다(`vacuum_process_log_block ()`, 3361행 `log_lsa.pageid >= first_block_pageid`). 따라서 마지막 31 페이지 안의 레코드만 vacuum되고 그보다 앞선 MVCC 로그는 어떤 job에도 속하지 않는다. job이 끝나면 `oldest_unvacuumed_mvccid`가 그 MVCCID들보다 커진다. checkdb는 이 값보다 오래된 삭제·삽입 정보가 남은 레코드를 "vacuum되었어야 하는데 남은 레코드"로 보고 `assert (false)`를 부른다(7472행).

확인한 사실과 추정을 구분하면 다음과 같다.

- 측정: 아래 Repro를 develop `e64a04a79` debug 빌드에서 두 번 실행해 두 번 모두 checkdb 종료 코드 254, 아래 에러 로그, 서버 abort를 보았다. abort한 서버는 master가 다시 띄운다.
- 측정: 3단계의 `vacuumdb -S`를 `vacuum_disable=yes`를 지우기 전에 돌려도(이때는 0.2-0.4초에 끝난다) checkdb가 같은 assert로 죽는다(2회 실행).
- 측정: 짧은 행(약 10 B) 1,000개 중 500개만 지우면 checkdb가 정상 종료한다. 꺼져 있던 동안의 로그가 한 block 안에 들어가기 때문으로 추정한다.
- 측정: DB를 만들 때부터 `vacuum_disable=yes`로 2만 행을 넣고 지운 뒤, `vacuumdb -S` 없이 vacuum만 켜고 서버를 띄우면 `count(*)`는 0인데 `show heap capacity`의 `Num_recs`가 19,537로 남는다. 약 460행(1 KB 행 기준 약 31 페이지 분량)만 회수된 것이다. 서버를 띄운 직후의 checkdb는 통과했고, 트랜잭션 하나를 실행하고 30초 기다린 뒤의 checkdb는 `insert_id=4, delete_id=missing`인 레코드에서 같은 assert로 죽었다. 따라서 `vacuumdb -S`는 원인이 아니고, checkdb가 실패하는 시점은 vacuum이 `oldest_unvacuumed_mvccid`를 올린 뒤다.
- 추정: vacuum이 꺼져 있던 동안 쓴 마지막 block 이전의 MVCC 로그는 위 코드 경로 때문에 vacuum data에 들어가지 않는다. 회수된 레코드 수가 block 하나 분량과 맞는다는 점이 근거다. 로그를 직접 덤프해 확인하지는 않았다.
- 확인(코드 읽기): `origin/develop` 최신 `21c6e635d`에도 위 2918행, 3361행, 5729행이 그대로 있고, `e64a04a79` 이후 `vacuum.c`, `vacuum.h`, `log_append.cpp`를 바꾼 커밋은 없다.
- 미확인: release 빌드의 동작.

## Test Build

- CUBRID 11.5.0 (11.5.0.2802-e64a04a) (64bit debug build for Linux)

## Repro

debug 빌드 설치본에서 `CUBRID`, `CUBRID_DATABASES` 환경을 설정하고, 비어 있는 포트를 `cubrid_port_id`로 쓴다. `$CUBRID/conf/cubrid.conf`의 `[common]` 마지막 줄에 `vacuum_disable`을 넣었다 뺀다.

```sh
CONF=$CUBRID/conf/cubrid.conf
cubrid createdb --db-volume-size=64M --log-volume-size=64M vtdb en_US.utf8

# 1. vacuum을 켠 채 2만 행을 넣고 vacuum을 끝낸다.
cubrid server start vtdb
cat > load.sql <<'EOF'
create table t (id int primary key, v varchar(2000));
insert into t select rownum, repeat('x', 1000) || rownum from db_class c1, db_class c2, db_class c3 limit 20000;
commit;
EOF
csql -u dba vtdb -i load.sql
cubrid server stop vtdb
cubrid vacuumdb -S vtdb

# 2. vacuum을 끄고 모든 행을 지운다(로그가 여러 block에 걸친다).
echo "vacuum_disable=yes" >> "$CONF"
cubrid server start vtdb
printf "delete from t;\ncommit;\n" > del.sql
csql -u dba vtdb -i del.sql
cubrid server stop vtdb

# 3. vacuum을 다시 켜고 SA vacuum을 돌린 뒤 checkdb를 실행한다.
sed -i '/^vacuum_disable=yes$/d' "$CONF"
cubrid vacuumdb -S vtdb
cubrid server start vtdb
csql -u dba vtdb -l -c "show heap capacity of t;" | grep Num_recs
cubrid checkdb -C vtdb
echo "rc=$?"
```

스택을 보려면 checkdb 직전에 서버에 gdb를 붙인다.

```sh
gdb -batch -p "$(pgrep -f '^cub_server vtdb$')" \
    -ex 'handle SIGPIPE SIGUSR1 SIGUSR2 nostop noprint pass' -ex continue -ex 'bt 15' &
sleep 5; cubrid checkdb -C vtdb
```

## Expected Result

`vacuumdb -S` 뒤 `Num_recs`가 0이고, `checkdb -C`가 종료 코드 0으로 끝난다.

## Actual Result

`Num_recs`가 18,597(두 번째 실행 18,598)로 남고, `cubrid checkdb -C`가 종료 코드 254로 끝난다. 서버 에러 로그는 다음과 같다.

```text
Time: 11/05/26 21:53:57.719 - DEBUG *** file src/query/vacuum.c, line 7379
Found not vacuumed HEAP record with oid=1|705|1, class_oid=0|206|3, insert_id=missing, delete_id=6, oldest_mvcc_id=7
```

`$CUBRID/log/coredump/`에 `cub_server_<시각>.coredump` 파일이 생기고 서버는 abort한다. gdb로 본 스택은 다음과 같다.

```text
Thread 19 "transaction" received signal SIGABRT, Aborted.
#4  __assert_fail () from /lib64/libc.so.6
#5  vacuum_check_not_vacuumed_rec_header (..., btree_node_type=-1) at src/query/vacuum.c:7472
#6  vacuum_check_not_vacuumed_recdes (..., btree_node_type=-1) at src/query/vacuum.c:7406
#7  heap_chkreloc_next (...) at src/storage/heap_file.c:16527
#8  heap_check_all_pages_by_heapchain (...) at src/storage/heap_file.c:15568
#9  heap_check_all_pages (...) at src/storage/heap_file.c:15682
#10 heap_check_heap_file (...) at src/storage/heap_file.c:15775
#11 heap_check_all_heaps (...) at src/storage/heap_file.c:15826
#12 xboot_check_db_consistency (..., check_flag=63, ...) at src/transaction/boot_sr.c:3828
#13 sboot_check_db_consistency (...) at src/communication/network_interface_sr.cpp:4293
#14 net_server_request (...) at src/communication/network_sr.c:928
```

## Additional Information

- 관련 이슈: [CBRD-25602](http://jira.cubrid.org/browse/CBRD-25602), [CBRD-24085](http://jira.cubrid.org/browse/CBRD-24085), [CBRD-23994](http://jira.cubrid.org/browse/CBRD-23994). 모두 `vacuum_disable` 상태의 다른 assert·crash를 고친 이슈다. 이번 증상과 같은 이슈는 찾지 못했다.
- ANALYSIS 확인 사항: `vacuum_disable=yes` 동안 쓴 MVCC 로그를 다시 켤 때 vacuum해야 하는지(꺼져 있던 동안에도 block을 vacuum data에 쌓거나, 재시작 때 잃은 범위를 복구하는 방법), 아니면 그 기간의 레코드를 vacuum 대상에서 빼는 것이 이 디버그 파라미터의 의도인지 정한다. 후자라면 `oldest_unvacuumed_mvccid`를 넘겨서는 안 되고 checkdb도 그 레코드를 오류로 보지 않아야 한다.
- 관련 관찰: `vacuumdb -S`는 `sysprm_set_force (PRM_ID_DISABLE_VACUUM, "no")`(`src/executables/util_cs.c` 4212행)로 vacuum을 켜려 하지만, `cubrid.conf`에 `vacuum_disable=yes`가 있으면 0.2-0.4초에 끝난다. `db_restart ()`가 `cubrid.conf`를 다시 읽어 강제 값을 덮어써 실제로 vacuum하지 않는 것으로 추정한다. 이번 결함의 원인은 아니며 따로 확인하지 않았다.
