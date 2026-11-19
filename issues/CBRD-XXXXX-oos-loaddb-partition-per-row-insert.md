# [OOS][LOADDB] loaddb -C로 파티션에 적재하면 배치 단위 다중 행 삽입 대신 한 행씩 넣어 develop보다 약 1.5배 느리다

**한 줄 요약**: PR #7990(`feature/oos-merge` → develop) 최종 리뷰에서 찾은 성능 회귀다. OOS 브랜치의 CBRD-27089 변경 뒤로 server-side loaddb(`loaddb -C`)가 파티션에 적재할 때 develop의 배치 단위 다중 행 삽입을 쓰지 않고, 행마다 파티션 정의를 다시 읽으며 한 행씩 삽입한다. 그래서 OOS를 쓰지 않는 테이블도 develop보다 약 1.5배 느리다(debug 빌드 측정). 이 이슈는 파티션 적재 비용을 develop 수준으로 되돌리는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: `loaddb -C`로 파티션 테이블을 적재하는 비용을 develop 수준으로 되돌린다. OOS 값은 지금처럼 각 파티션의 OOS 파일에 기록되어야 한다.

**이슈 수행 이유**: PR #7990 head `71993ddb63`의 server-side loader는 적재 대상이 파티션이면 언제나 행 단위 경로를 탄다. 행마다 system operation을 따로 열고, 새 pruning context로 파티션 정의를 다시 읽고, 파티션용 scan cache를 만든 뒤 한 행을 넣는다. develop `86b3c49c10`은 HA가 꺼져 있고 무시할 unique 오류가 없으면 한 배치를 `locator_multi_insert_force ()` 한 번으로 넣는다. 이 행 단위 경로는 CBRD-27089(`3252fcffce`)가 넣었다. 루트 테이블에 적재한 행을 파티션으로 나누고, 각 행의 OOS 값을 그 파티션의 OOS 파일에 쓰기 위해서였다. 그런데 develop의 CBRD-27441(`ef12ae8ce7`)이 루트 테이블 적재를 거부(-1395)하고, 각 행이 대상 파티션에 속하는지를 배치마다 한 번 읽은 파티션 정의로 검사하게 했다. 그 뒤로 이 경로는 하는 일 없이 비용만 더한다. 같은 조건에서 측정했을 때 일반 테이블은 느려지지 않았고 파티션 적재만 약 1.5배 느렸다.

**영향**: `loaddb -C`로 파티션 테이블을 적재하는 모든 사용자가 겪는다. OOS 사용 여부와 상관없다. 특히 PR #7990은 이전 저장 형식의 DB를 -1401(`ER_BO_INCOMPATIBLE_STORAGE_FORMAT`)로 거부하므로, 기존 사용자가 새 엔진으로 옮기는 방법은 unloaddb와 loaddb뿐이다. unloaddb는 파티션 테이블의 행을 각 파티션 클래스 이름으로 내보내므로, CS 모드로 이관하면 파티션 테이블의 모든 행이 이 경로를 지난다. 적재 결과 데이터는 develop과 같다. 늘어나는 것은 적재 시간이다. 코드상 꽉 찬 페이지를 한 번에 남기던 로그도 행마다 남는다. 측정은 부하가 큰 공유 호스트에서 debug 빌드로 한 번씩 했다. release 빌드와 대용량에서 차이가 얼마인지, 로그 양이 어떻게 달라지는지는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: server-side loaddb의 배치 삽입과 파티션 적재

`loaddb -C`에서 클라이언트는 데이터 파일을 배치로 나눠 서버에 보낸다. 서버의 `server_object_loader`는 각 행을 레코드로 만들어 모아 두었다가 `flush_records ()`에서 heap에 넣는다. develop은 두 경로를 쓴다.

- HA가 꺼져 있고 `--error-control-file`로 무시하는 `ER_BTREE_UNIQUE_FAILED`가 없으면, 배치 전체를 `locator_multi_insert_force ()` 한 번으로 넣는다. system operation은 하나이고, 꽉 찬 heap 페이지는 페이지 단위 redo 로그(`LC_FORCE_FLAG_BULK_LOGGING`)로 남기며, unique 통계는 `MULTI_ROW_INSERT` 방식으로 모아 반영한다.
- HA가 켜져 있거나 unique 오류를 무시하면 행마다 `locator_insert_force ()`를 부른다. HA 복제 로그가 행마다 정확한 LSA를 가져야 하기 때문이다.

파티션 테이블은 이렇게 적재된다.

- unloaddb는 파티션 테이블의 행을 `%class [dba].[t__p__p0]`처럼 각 파티션 클래스 이름으로 쓴다(`unload_object.c:2635-2647`). 루트 테이블 몫으로는 헤더만 있고 행이 없다.
- server-side loader는 루트 테이블로 들어온 행을 -1395(`ER_LDR_PARTITIONED_CLASS_NOT_SUPPORTED`)로 거부한다(develop CBRD-27441).
- 파티션이 대상이면 배치마다 파티션 정의를 한 번 읽고(`partition_load_uncached_pruning_context ()`), `finish_line ()`에서 행마다 그 정의로 소속을 검사한다(`partition_check_record_for_partition ()`).

### 원인 (`src/loaddb/load_server_loader.cpp`, `71993ddb63` 기준)

- `start_attrinfo ()`(1352-1363)는 대상이 파티션이면 `m_pruning_type = DB_PARTITION_CLASS`로 둔다.
- `flush_records ()`(856)는 이 값을 `pruning_type`으로 쓴다. 분기 조건(892)에 `|| pruning_type != DB_NOT_PARTITIONED_CLASS`가 붙어 있어서, 파티션 적재는 HA나 오류 무시 여부와 상관없이 언제나 행 단위 분기로 간다.
- 행 단위 분기(897-918)는 행마다 다음을 한다.
  - `log_sysop_start ()`와 `log_sysop_attach_to_outer ()`
  - unique 통계를 `SINGLE_ROW_INSERT`로 처리
  - 빈 `PRUNING_CONTEXT`를 새로 만들어 `locator_insert_force ()`에 넘기고, 행이 끝나면 지운다
- `locator_insert_force ()`(`locator_sr.c:6245`)는 `partition_prune_insert ()`를 부른다. 이 함수(`partition.c:4174`)는 context가 비어 있으므로 `partition_load_pruning_context ()`(4215)로 파티션 정의를 다시 읽는다. 이때 루트 클래스를 찾고, 공유 파티션 캐시를 조회하고, 파티션 조건식을 역직렬화한다. 그다음 행이 속할 파티션을 다시 계산해 대상 파티션과 비교한다. 이어서 `locator_get_partition_scancache ()`(`locator_sr.c:6275`)가 파티션용 heap scan cache를 새로 연다. 둘 다 행이 끝나면 해제된다.
- 이 작업은 `finish_line ()`이 배치의 context로 이미 한 검사를 반복할 뿐이다. 행이 들어갈 heap은 처음부터 대상 파티션의 heap(`m_scancache.node.hfid`)으로 정해져 있다.

CBRD-27441은 파티션 정의를 행마다 읽으면 적재가 1.6~2.0배 느려진다고 기록하고(이전 구현 PR #7982 방식), 배치마다 한 번 읽는 방식을 택했다. head는 다른 경로로 행마다 읽는 비용을 다시 들여왔고, 배치 다중 행 삽입까지 잃었다.

### 경위

- `3252fcffce`(CBRD-27089, 2026-10-22, OOS 브랜치): OOS 값을 목적지 heap이 정해진 뒤에 쓰도록 바꿨다. 그때는 루트 테이블 적재가 허용되었으므로, loader가 루트로 들어온 행을 파티션으로 나누고 OOS 값을 그 파티션의 OOS 파일에 쓰도록 행 단위 pruning 경로를 넣었다.
- `ef12ae8ce7`(CBRD-27441, 2026-11-17, develop): 루트 테이블 적재를 거부하고, 파티션 소속 검사를 배치 단위로 옮겼다.
- `3e541fcf67`(OOS 브랜치에 develop 병합): 두 변경이 합쳐졌다. 루트 테이블로 들어온 행은 `finish_line ()`에서 거부되므로 나눌 행이 없다. 남은 것은 파티션 적재뿐이고, 그 목적지는 이미 정해져 있다.

OOS 소유 heap도 이 경로가 필요하지 않다. `locator_multi_insert_force ()`는 페이지를 잡기 전에 각 행의 OOS 값을 `heap_oos_finalize_record (thread_p, class_oid, ...)`로 기록한다(`locator_sr.c:15966`). 파티션 적재에서 `class_oid`는 대상 파티션이므로 OOS 값은 그 파티션의 OOS 파일로 간다. 이것은 코드를 읽어 확인했고, 실행으로 확인하지는 않았다.

### 조건별 차이

| 적재 조건 | develop `86b3c49c10` | PR #7990 head `71993ddb63` |
|---|---|---|
| 일반 테이블, HA off, 무시 오류 없음 | 배치 다중 행 삽입 | 같음 |
| 파티션, HA off, 무시 오류 없음 | 배치 다중 행 삽입 | 행 단위 삽입, 행마다 파티션 정의 로드 |
| 파티션, HA on 또는 `ER_BTREE_UNIQUE_FAILED` 무시 | 행 단위 삽입, pruning 없음 | 행 단위 삽입에 행마다 파티션 정의 로드와 `SINGLE_ROW_INSERT`가 더해짐(미측정) |

`loaddb -S`는 server-side loader를 쓰지 않으므로 이 이슈의 범위 밖이다.

### Test Build

- PR #7990 head: `71993ddb63` debug 빌드
- develop: `2e66081fd2` debug 빌드. `86b3c49c10`과의 차이는 커밋 3개이고, 그중 `src/loaddb`, `partition.c`, `locator_sr.c`, `heap_file.c`를 바꾼 커밋은 없다.
- 공유 호스트에 부하가 큰 상태였다. 빌드마다 새 DB를 만들고, 전용 서버로 CS 모드, HA off, `--no-statistics`로 한 번씩 측정했다.
- `cubrid.conf`: `data_buffer_size=64M`, `log_buffer_size=4M`, `sort_buffer_size=2M`, `log_max_archives=0`, 페이지 크기는 기본값(16KB)

### 측정 결과

20만 행 `(id int primary key, a varchar(100), b int, c varchar(200))`를 4개 hash 파티션 테이블과 일반 테이블에 같은 데이터로 넣은 뒤, `--datafile-per-class`로 unload해서 다시 적재했다. 한 행은 약 220바이트이므로 OOS로 가는 값은 없다.

| 적재 | head | develop |
|---|---|---|
| 일반 테이블 20만 행(파일 1개) | 2.54 s | 3.26 s |
| hash 파티션 4개, 파티션당 약 5만 행(loaddb 4회) | 1.69 / 1.67 / 1.69 / 1.69 s, 합계 6.74 s | 1.13 / 1.09 / 1.08 / 1.12 s, 합계 4.43 s |

- 파티션 적재는 네 파티션 모두에서 head가 약 1.5배 느렸다. 두 빌드 모두 행 수(20만, 20만)는 같았다.
- 일반 테이블은 head가 느리지 않았다. 한 번씩 측정한 값이라, head가 더 빠르게 나온 차이는 개선으로 보지 않는다.
- 각 시간에는 loaddb 클라이언트의 시작과 접속 비용이 들어 있다. 그래서 삽입 자체만 비교한 배율은 1.5배보다 크다.
- 측정하지 않은 것: release 빌드, 더 큰 데이터, HA on, OOS 값이 있는 행, 로그 양.

### Repro

비교할 빌드의 `cubrid`와 `csql`이 `PATH`에 있고, `CUBRID_DATABASES`가 설정되어 있으며, HA가 꺼져 있다고 가정한다. 다른 서버와 겹치지 않는 `cubrid_port_id`를 `cubrid.conf`에 둔다. 두 빌드에서 각각 새 디렉터리에서 실행한다.

```bash
db=ldpdb
mkdir -p ldp-repro && cd ldp-repro
cubrid createdb --db-volume-size=512M --log-volume-size=256M -F "$PWD" "$db" en_US.utf8

cat > prep.sql <<'SQL'
create table t_ldp (id int primary key, a varchar(100), b int, c varchar(200)) partition by hash (id) partitions 4;
create table t_ldn (id int primary key, a varchar(100), b int, c varchar(200));
insert into t_ldp select rownum, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || rownum, rownum % 97, repeat('x', 150) from db_class a, db_class b, db_class c limit 200000;
insert into t_ldn select * from t_ldp;
commit;
SQL
csql -S -u dba "$db" -i prep.sql

printf 't_ldp\nt_ldn\n' > classes.txt
cubrid unloaddb -S -d -i classes.txt --datafile-per-class -O "$PWD" "$db"

printf 'truncate t_ldp;\ntruncate t_ldn;\n' > trunc.sql
csql -S -u dba "$db" -i trunc.sql

cubrid server start "$db" > server_start.out 2>&1 < /dev/null
for f in "${db}"_*t_ldn_objects "${db}"_*t_ldp__p__p*_objects; do
  s=$(date +%s.%N)
  cubrid loaddb -C -u dba --no-statistics -d "$f" "$db" > "load_${f}.out" 2>&1 < /dev/null
  rc=$?; e=$(date +%s.%N)
  echo "$f rc=$rc elapsed=$(echo "$e - $s" | bc)"
done
csql -C -u dba "$db" -c 'select count(*) from t_ldp; select count(*) from t_ldn;'
cubrid server stop "$db" > server_stop.out 2>&1 < /dev/null
```

`ldpdb_dba.t_ldp__p__p0_objects` 같은 파티션 파일마다 시간을 출력한다. 루트 테이블 파일(`ldpdb_dba.t_ldp_objects`)은 헤더만 있으므로 적재하지 않는다.

### Expected Result

- 파티션 적재 시간이 같은 조건의 develop과 측정 편차 범위 안이다.
- 적재된 행과 값은 develop과 같다.

### Actual Result

- 파티션 적재가 develop보다 약 1.5배 느리다(위 표).
- 적재된 행 수는 같다.

## Acceptance Criteria

- HA off이고 무시 오류가 없을 때, `loaddb -C`로 파티션에 적재하는 시간이 같은 조건의 develop과 측정 편차 범위 안이다. release 빌드로 측정하는 것을 권한다.
- OOS로 가는 값이 있는 행을 파티션에 적재하면, 그 값은 해당 파티션의 OOS 파일에 기록되고 루트 테이블에는 OOS 파일이 생기지 않는다. 값은 원본과 같고 `checkdb`가 통과한다.
- CBRD-27441의 동작이 유지된다. 대상 파티션에 속하지 않는 행은 -891 또는 -1109로 거부되고, `--error-control-file`로 무시하면 그 행만 빠진다. 루트 테이블로 들어온 행은 -1395로 거부된다.
- HA on 또는 unique 오류 무시 조건의 적재는 develop처럼 행 단위로 처리된다.

## Options for Analysis

아래는 검토할 후보이고, 선택은 ANALYSIS에서 한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| 현행 유지 | 변경이 없다. | 파티션 적재가 계속 약 1.5배 느리다. 이관 때마다 비용을 낸다. | 정확성 문제는 없다. | 위 측정 |
| A. 파티션 적재에서 `flush_records ()`가 `DB_NOT_PARTITIONED_CLASS`를 쓰고, 분기 조건을 develop처럼 HA와 오류 무시 여부로만 정한다 | 파티션 적재가 develop과 같은 배치 다중 행 삽입 경로로 돌아간다. 행마다 파티션 정의를 읽는 비용과 공유 파티션 캐시 사용이 함께 사라진다. | 루트 테이블 적재(행 분배, CBRD-23296)를 지원하게 되면 그때는 pruning 경로가 필요하다. 그 경우 행마다 새 context가 아니라 배치의 context를 넘기는 방식을 따로 검토해야 한다. | 변경은 `flush_records ()` 안 20줄 안팎이다. 행 소속 검사와 루트 거부는 `finish_line ()`에 그대로 남는다. | (1) 파티션 적재의 unique 통계가 `m_scancache`의 `MULTI_ROW_INSERT` 경로로 올바르게 반영되는지(develop과 같은 경로) (2) OOS 값이 있는 행을 파티션에 적재했을 때 소유 heap이 맞는지 실행으로 확인 (3) release 빌드로 develop과 시간 비교 |

후보 A는 develop이 이미 쓰던 경로로 되돌리는 것이고, OOS 값 기록은 다중 행 삽입 경로가 이미 대상 클래스 기준으로 한다. 판단에 남는 근거는 위의 세 확인 사항이다. 루트 테이블 적재를 다시 지원할 계획이 있다면, 그 계획이 정해질 때 pruning 경로를 다시 설계하는 편이 지금 행 단위 경로를 유지하는 것보다 비용이 작다.

### 추가로 확인할 점

head의 행 단위 경로는 `partition_load_pruning_context ()`로 공유 파티션 캐시를 읽고 쓴다. 그런데 server-side loader는 파티션 테이블(루트)에 lock을 잡지 않는다. CBRD-27441은 바로 이 이유로 배치용 정의를 캐시를 거치지 않는 사본(`partition_load_uncached_pruning_context ()`)으로 읽게 했다. 동시에 실행되는 파티션 DDL이 커밋하기 전의 정의가 이 경로로 캐시에 들어갈 수 있는지는 확인하지 않았다. 후보 A를 택하면 이 경로 자체가 없어진다.

## Triage Request

- 이 회귀를 PR #7990의 develop 병합 전에 고칠지, 병합 뒤 11.5(guava) 전에 고칠지 정한다. 결과 데이터에는 영향이 없고, 비용은 파티션 테이블의 CS 모드 이관 시간이다.

## Related Issues

- CBRD-26978: OOS TODO(상위 이슈)
- CBRD-27089(Resolved): 행 단위 pruning 경로를 넣은 OOS 변경. 이 이슈는 그 변경과 CBRD-27441이 합쳐진 뒤의 성능 문제를 다룬다.
- CBRD-27441(Resolved, develop): 루트 테이블 적재 거부와 배치 단위 파티션 검사. 행마다 파티션 정의를 읽으면 1.6~2.0배 느려진다는 측정을 기록했다.
- CBRD-28075(Confirmed): COPY FROM STDIN 계획. HA on에서도 배치 삽입을 쓰도록 `flush_records ()`의 같은 분기 조건을 바꾸려 하므로, 이 이슈를 고칠 때 조율이 필요하다. 파티션은 COPY 대상이 아니다.
- CBRD-23296(Open): 루트 테이블에 적재한 행을 파티션으로 나누는 기능(pruning)이 없다는 오래된 이슈. 현재는 CBRD-27441이 이런 적재를 -1395로 거부한다.
