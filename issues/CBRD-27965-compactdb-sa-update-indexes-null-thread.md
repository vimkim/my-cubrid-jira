# [compactdb] SA 모드 compactdb가 인덱스가 있는 테이블의 이전 표현 행을 갱신할 때 debug 빌드가 SIGSEGV로 종료된다

**한 줄 요약**: OOS 대체 설계(Sidecar)의 테스트 중 발견한 develop 결함으로, SA 모드 `cubrid compactdb`가 인덱스가 있는 테이블에서 이전 표현(representation)의 행을 갱신하면 `update_indexes ()`가 thread entry 대신 NULL을 넘겨 debug 빌드의 `cub_admin`이 SIGSEGV로 죽는다. [CBRD-24426](http://jira.cubrid.org/browse/CBRD-24426)이 같은 함수의 `heap_update_logical ()` 호출만 고치고 바로 앞의 인덱스 갱신 경로를 남긴 것이다.

## Issue Triage

**이슈 수행 목적**: SA 모드 compactdb가 인덱스가 있는 테이블에서도 debug 빌드에서 죽지 않고 끝나게 한다.

**이슈 수행 이유**: develop debug 빌드에서 PK 하나가 있는 테이블에 컬럼을 추가한 뒤 `cubrid compactdb -S`를 실행하면 매번 `cubthread::entry::get_pgbuf_tracker (this=0x0)`에서 SIGSEGV가 난다. 인덱스가 없으면 같은 절차가 정상 종료한다. CBRD-24426의 회귀 테스트는 인덱스가 없는 테이블만 쓰므로 이 경로를 검사하지 않는다.

**영향**: debug 빌드로 compactdb를 검증하는 개발자와 QA가 영향을 받는다. 인덱스가 있는 테이블은 흔하므로 debug 빌드에서는 SA compactdb를 사실상 쓸 수 없다. release 빌드는 실행해 보지 않았다. 코드상 release에는 NULL을 역참조하는 tracker 코드가 없어 죽지 않을 것으로 추정한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

compactdb는 각 행을 읽어 현재 표현으로 다시 쓴다. 표현이 바뀐 행(예: `ALTER TABLE ... ADD COLUMN` 이전에 들어간 행)은 `process_object ()`가 `disk_update_instance ()`로 넘긴다. 클래스에 인덱스가 있으면 `disk_update_instance ()`는 heap을 갱신하기 전에 `update_indexes ()`를 부른다.

`disk_update_instance ()`는 CBRD-24426 이후 `thread_p`를 받지만 `update_indexes ()`에는 넘기지 않는다. `update_indexes ()`는 `thread_p` 인자가 없고 안의 서버 함수 호출 다섯 곳에 모두 NULL을 넘긴다(develop `21c6e635d` 기준, `src/executables/compactdb.c`). 이번에 죽는 곳은 783행이다.

- 781행: `heap_init_get_context (NULL, ...)`
- 783행: `heap_get_last_version (NULL, &context)`
- 793행: `locator_update_index (NULL, rec, &oldrec, ...)`
- 801-802행: `heap_clean_get_context (NULL, ...)`, `heap_scancache_end (NULL, ...)`

page buffer 내부 함수 다수(`pgbuf_get_holder ()`, `pgbuf_find_thrd_holder ()`, `pgbuf_find_current_wait_msecs ()`)는 NULL `thread_p`를 `thread_get_thread_entry_info ()`로 바꾼다. 그러나 debug 빌드의 `pgbuf_fix_debug ()`는 `thread_p->get_pgbuf_tracker ().increment (...)`(`src/storage/page_buffer.c` 2491행)에서 NULL을 그대로 역참조한다. debug 빌드의 페이지 검증(`pgbuf_is_valid_page ()`)이 볼륨 헤더를 fix하면서 이 지점에 먼저 도달한다.

CBRD-24426(2022, 커밋 `0be008268`)은 같은 증상(`get_pgbuf_tracker (this=0x0)`)을 `disk_update_instance ()`의 `heap_update_logical (NULL, ...)`에서 고쳤다. 그 재현 테이블(`create table ... as select`)과 회귀 테스트(`shell/_06_issues/_22_2h/cbrd_24426`, `create table t1 (col1 int)`)에는 인덱스가 없어 `update_indexes ()`가 불리지 않았다.

확인한 사실과 추정을 구분하면 다음과 같다.

- 측정: develop `e64a04a79` debug 빌드와 `30043f4` debug 빌드에서 아래 Repro가 매번 재현된다(각각 2회, 1회 실행).
- 측정: 같은 절차에서 `primary key`만 빼면 compactdb가 종료 코드 0으로 끝난다.
- 측정: 크래시 직전까지 SA 에러 로그에는 오류가 없다. 마지막 줄은 `Server status is UP.`이다.
- 확인(코드 읽기): `origin/develop` 최신 `21c6e635d`에도 783행과 793행의 NULL 호출이 그대로 있다. `30043f4` 이후 `compactdb.c`를 바꾼 커밋은 없다.
- 추정: release 빌드는 tracker 코드가 없어 죽지 않는다. 실행해 확인하지 않았다.

## Test Build

- CUBRID 11.5.0 (11.5.0.2802-e64a04a) (64bit debug build for Linux)
- CUBRID 11.5.0 (11.5.0.2635-30043f4) (64bit debug build for Linux)

## Repro

debug 빌드 설치본에서 `CUBRID`, `CUBRID_DATABASES` 환경을 설정한 뒤 실행한다. 서버나 broker는 필요 없다.

```sh
cubrid createdb --db-volume-size=64M --log-volume-size=64M r824 en_US.utf8

cat > repro.sql <<'EOF'
create table t (a int primary key, b varchar(20));
insert into t select rownum, 'x' from db_class c1, db_class c2 limit 10;
alter table t add column c int;
commit;
EOF
csql -S -u dba -i repro.sql r824

cubrid compactdb -S r824 dba.t
echo "rc=$?"
```

스택을 보려면 마지막 명령을 다음처럼 실행한다.

```sh
gdb -batch -ex run -ex bt --args "$CUBRID/bin/cub_admin" compactdb -S r824 dba.t
```

## Expected Result

compactdb가 10개 행을 새 표현으로 갱신하고 종료 코드 0으로 끝난다.

## Actual Result

`cubrid compactdb`가 아무 메시지 없이 종료 코드 254로 끝난다. `cub_admin`은 SIGSEGV로 죽는다.

```text
Program received signal SIGSEGV, Segmentation fault.
#0  cubthread::entry::get_pgbuf_tracker (this=0x0) at src/thread/thread_entry.hpp:372
#1  pgbuf_fix_debug (thread_p=0x0, ..., fetch_mode=OLD_PAGE, request_mode=PGBUF_LATCH_READ, ..., caller_func="disk_get_volheader_internal") at src/storage/page_buffer.c
#2  disk_get_volheader_internal (thread_p=0x0, volid=1, ...) at src/storage/disk_manager.c
#3  disk_is_page_sector_reserved_with_debug_crash (thread_p=0x0, volid=1, pageid=705, debug_crash=true) at src/storage/disk_manager.c:4228
#4  pgbuf_is_valid_page (thread_p=0x0, ...) at src/storage/page_buffer.c:11256
#5  pgbuf_fix_debug (thread_p=0x0, ..., caller_func="heap_prepare_object_page") at src/storage/page_buffer.c
#6  pgbuf_ordered_fix_debug (thread_p=0x0, ...) at src/storage/page_buffer.c
#7  heap_prepare_object_page (thread_p=0x0, ...) at src/storage/heap_file.c:27279
#8  heap_prepare_get_context (thread_p=0x0, ...) at src/storage/heap_file.c:7177
#9  heap_get_last_version (thread_p=0x0, ...) at src/storage/heap_file.c:27214
#10 update_indexes (class_oid=..., obj_oid=..., rec=...) at src/executables/compactdb.c:783
#11 disk_update_instance (thread_p=0x555555675800, ...) at src/executables/compactdb.c:698
#12 process_object (thread_p=0x555555675800, ...) at src/executables/compactdb.c:524
#13 process_class (thread_p=0x555555675800, ...) at src/executables/compactdb.c:444
#14 compactdb_start (...) at src/executables/compactdb.c:250
#15 compactdb (...) at src/executables/compactdb.c:153
#16 main (...) at src/executables/util_admin.c:1168
```

frame 11의 `disk_update_instance ()`는 유효한 `thread_p`를 갖고 있고, frame 10의 `update_indexes ()`부터 NULL이 된다.

## Additional Information

- 관련 이슈: [CBRD-24426](http://jira.cubrid.org/browse/CBRD-24426). 같은 증상을 `heap_update_logical ()` 호출에서 고쳤다.
- ANALYSIS 확인 사항: `update_indexes ()`가 `thread_p`를 받아 다섯 호출에 넘기면 충분한지, 아니면 `pgbuf_fix_debug ()`의 tracker 코드도 다른 page buffer 함수처럼 NULL을 허용해야 하는지 정한다. CBRD-24426 회귀 테스트에 인덱스가 있는 테이블을 추가할지 정한다.
