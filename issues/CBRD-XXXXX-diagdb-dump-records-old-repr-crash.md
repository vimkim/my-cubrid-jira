# [DIAGDB] ADD COLUMN 이전 representation으로 저장된 행이 있으면 `cubrid diagdb -d 9 --dump-records` 가 heap_attrinfo_dump()에서 SIGSEGV로 종료된다

**한 줄 요약**: [CUBRID/cubrid PR #8690](https://github.com/CUBRID/cubrid/pull/8690)(CBRD-28274)을 검증하다가 PR과 무관한 diagdb 결함을 발견했다([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28274/pr-8690-review.md) P-3). `ALTER TABLE ... ADD COLUMN` 이후에도 옛 representation으로 남아 있는 행을 `cubrid diagdb -d 9 --dump-records` 로 덤프하면, 추가된 컬럼의 NULL 속성 정보를 역참조해 유틸리티가 비정상 종료된다. 이 이슈는 이런 행도 끝까지 덤프되도록 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: ADD COLUMN으로 스키마가 바뀐 뒤 옛 representation으로 남은 행이 있는 테이블도 `cubrid diagdb -d 9 --dump-records` 가 모든 레코드를 덤프하고 정상 종료한다.

**이슈 수행 이유**: `heap_attrinfo_dump ()` (`src/storage/heap_file.c`)는 각 속성 값의 `value->read_attrepr->type` 을 NULL 검사 없이 역참조한다. 그런데 행의 representation id가 최신이 아니면 `heap_attrinfo_recache ()` 가 모든 `read_attrepr` 를 NULL로 비운 뒤, 그 행의 representation에 있는 속성만 다시 채운다. 그래서 ADD COLUMN으로 나중에 추가된 속성은 `read_attrepr == NULL` 로 남는다. 일반 테이블 하나에 행 3개를 넣고 컬럼 하나를 추가하는 최소 재현으로, release/11.4 debug 빌드와 develop debug 빌드에서 모두 SIGSEGV와 종료 코드 254를 확인했다. `--dump-records` 를 빼면 같은 테이블의 덤프가 종료 코드 0으로 끝난다.

**영향**: 개발자, QA, 운영자가 장애 분석이나 데이터 검증을 위해 `diagdb` 로 레코드를 덤프할 때, ADD COLUMN을 한 적이 있고 옛 행이 남은 테이블이면 덤프가 첫 옛 행에서 중단된다. ADD COLUMN은 기존 행을 다시 쓰지 않으므로 이런 테이블은 흔하다. 출력 파일은 버퍼에 남은 내용을 잃은 채 잘리고, 그 테이블의 레코드 값은 확인할 수 없다. `diagdb` 는 SA 모드에서 읽기만 하는 유틸리티이며, 데이터베이스 내용이 손상되는 것은 관측하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 원인 경로 (소스 확인)

| 단계 | release/11.4 (`46e71173c0`) | develop (`6f5ac7a9f9`) |
|---|---|---|
| `diagdb ()` → `heap_dump_heap_file ()` | `src/executables/util_sa.c:1733` | `src/executables/util_sa.c:1974` |
| `heap_dump ()` 가 행마다 `heap_attrinfo_read_dbvalues ()` 후 `heap_attrinfo_dump ()` 호출 | `src/storage/heap_file.c:14519-14524` | `heap_file.c:18093` |
| `heap_attrinfo_recache ()`: 최신 repr가 아니면 모든 `read_attrepr = NULL` 후, 행의 repr에 있는 속성만 다시 설정 | `heap_file.c:10003-10009` | `heap_file.c:11451` |
| `heap_attrinfo_dump ()`: `pr_type_name (value->read_attrepr->type)` 를 NULL 검사 없이 호출 | `heap_file.c:10634-10635` | `heap_file.c:13162-13163` |

`heap_dump ()` 는 `heap_attrinfo_start (..., -1, ...)` 로 클래스의 최신 representation에 있는 모든 속성을 요청한다. 옛 행을 읽을 때 `heap_attrvalue_read ()` 는 `read_attrepr == NULL` 인 속성에 `last_attrepr` 의 기본값을 채우고(11.4 `heap_file.c:10163-10175`), `heap_attrinfo_read_dbvalues ()` 는 성공을 반환한다. 그러나 그 속성의 `read_attrepr` 는 NULL로 남는다. 따라서 오류 분기(`"Error ... continue"`)로 가지 않고 `heap_attrinfo_dump ()` 에서 바로 비정상 종료된다.

`-n` 없이 모든 heap을 덤프하는 경우(`file_tracker_dump_all_heap ()`)도 같은 `heap_dump ()` 를 거치므로 영향을 받을 것으로 보이지만, 실행해 확인하지는 않았다.

### 수정 방향 후보 (리뷰 제안, 미결정)

리뷰에서는 `read_attrepr` 가 NULL인 속성(행의 representation에 없는 속성)을 건너뛰거나, `last_attrepr` 의 타입과 기본값임을 표시해 출력하는 방법을 제안했다. 같은 파일의 `heap_attrinfo_clear_dbvalues ()` (11.4 `heap_file.c:10108`)와 `heap_locate_attribute ()` (`:10692`)는 이미 `read_attrepr != NULL ? read_attrepr : last_attrepr` 로 이 상황을 처리한다. 어느 쪽이 진단 목적에 맞는지는 ANALYSIS에서 결정한다.

## Test Build

- `CUBRID 11.4.7 (11.4.7.2008-46e7117) (64bit debug build for Linux)`: PR #8690 head. PR은 `src/transaction/locator_sr.c` 만 바꾸므로 release/11.4 base(`065c452fe8`)도 같은 코드다.
- `CUBRID 11.5.0 (11.5.0.2704-cc94778) (64bit debug build for Linux)`: develop 빌드(2026-10-20). 현재 develop `6f5ac7a9f9` 소스에서도 같은 역참조를 확인했다(위 표).

## Repro

일반(비파티션) 테이블로 재현한다. 다른 SA 모드 접속이나 서버가 없는 상태에서 실행한다.

```bash
cubrid createdb --db-volume-size=64M --log-volume-size=32M p3dump en_US.utf8

cat > repro.sql <<'EOF'
create table t_dump (id int primary key, v varchar(30));
insert into t_dump select level, 'v' || level from db_root connect by level <= 3;
alter table t_dump add column c int default 42;
select * from t_dump order by id;
EOF
csql -S -u dba -i repro.sql p3dump

cubrid diagdb -d 9 -n dba.t_dump -o norec.diag p3dump;                 echo "exit=$?"
cubrid diagdb -d 9 --dump-records -n dba.t_dump -o rec.diag p3dump;    echo "exit=$?"

cubrid deletedb p3dump
```

## Expected Result

- 두 `diagdb` 명령 모두 종료 코드 0으로 끝난다. `--dump-records` 출력에는 행 3개가 모두 들어 있고, 추가된 컬럼 `c` 는 기본값 42나 "행의 representation에 없음" 표시로 나타난다.

## Actual Result

두 빌드에서 같은 결과를 얻었다.

- `csql` 의 `SELECT` 는 행 3개를 `c = 42` 로 정상 반환한다.
- `--dump-records` 없는 `diagdb`: 종료 코드 `0`.
- `--dump-records` 있는 `diagdb`: 종료 코드 `254`. `rec.diag` 는 레코드 값 출력 전에, 버퍼에 남은 내용을 잃은 채 중간에서 잘린다.
- 같은 명령을 `cub_admin diagdb ...` 로 gdb에서 실행한 결과(11.4 빌드):

```text
Program received signal SIGSEGV, Segmentation fault.
heap_attrinfo_dump (..., dump_schema=false) at src/storage/heap_file.c:10634
#0  heap_attrinfo_dump (...)            at src/storage/heap_file.c:10634
#1  heap_dump (..., dump_records=true)  at src/storage/heap_file.c:14524
#2  heap_dump_heap_file (..., class_name="dba.t_dump") at src/storage/heap_file.c:14574
#3  diagdb (...)                        at src/executables/util_sa.c:1733
#4  main (...)                          at src/executables/util_admin.c:1130
(gdb) print value->attrid                       -> 2      (추가된 컬럼 c)
(gdb) print value->read_attrepr                 -> 0x0
(gdb) print attr_info->read_classrepr->id       -> 1      (행의 representation)
(gdb) print attr_info->last_classrepr->id       -> 2      (최신 representation)
```

- develop 빌드도 같은 스택(`heap_attrinfo_dump` ← `heap_dump` ← `heap_dump_heap_file` ← `diagdb` `util_sa.c:1975`)과 같은 변수 값(`read_attrepr = 0x0`, read repr 1, last repr 2)을 보였다.

## Additional Information

- **출처**: [CUBRID/cubrid PR #8690](https://github.com/CUBRID/cubrid/pull/8690) 빌드·테스트 검증 중, 파티션 재분배 프로브(ADD COLUMN 후 REORGANIZE/COALESCE/REMOVE PARTITIONING)의 heap을 `--dump-records` 로 덤프하다가 처음 관측했다([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28274/pr-8690-review.md) P-3). 위의 최소 재현은 파티션과 재분배 없이도 발생함을 확인한 것이다.
- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-26, 인덱스 8,407건 완전 동기화, 후보 20건, JQL 키워드 검색 `heap_attrinfo_dump`, `dump-records` 병행): 중복 이슈 없음.
- **관련 이슈**:
  - [CBRD-27876](https://jira.cubrid.org/browse/CBRD-27876): 같은 `heap_attrinfo_recache ()` 의 속성 캐시 일관성 문제다. 다만 그 이슈는 짧은 레코드(`NULL_REPRID`)에서 `read_attrepr` 가 남는 경우이고, 이 이슈는 정상적인 옛 representation 행에서 `read_attrepr` 가 NULL인 것을 덤프 코드가 처리하지 못하는 경우다.
  - [CBRD-27385](https://jira.cubrid.org/browse/CBRD-27385) (Resolved): 같은 `diagdb -d 9` heap 덤프의 다른 결함이다. view처럼 heap이 없는 클래스에서 HFID 조회 실패가 assert에 걸린 경우로, 레코드 덤프와는 관계없다.
  - [CBRD-20619](https://jira.cubrid.org/browse/CBRD-20619): 2016년에 수정된 `heap_dump ()` assertion(`dump_records=false`, thread 없음)으로, 원인이 다르다.
  - [CBRD-28274](https://jira.cubrid.org/browse/CBRD-28274): 이 결함을 발견한 PR #8690의 대상 이슈다.
