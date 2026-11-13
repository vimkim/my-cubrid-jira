# [Utility] SA 모드 compactdb가 heap 읽기 오류(S_ERROR)를 끊어진 참조로 보고 살아 있는 객체 참조를 NULL로 바꿔 커밋한다

**한 줄 요약**: 중복 코드 drift 점검에서 `cubrid compactdb`의 SA 복사본(`compactdb.c`)만 S_ERROR 처리가 빠진 것을 찾았다. debug 빌드에서 gdb로 heap 읽기 오류를 주입하면, SA 모드는 살아 있는 객체를 가리키던 참조를 NULL로 바꿔 커밋하고 경우에 따라 종료 코드 0으로 끝나는 것을 재현했다. CS 모드는 같은 주입에서 참조를 지키지만, 오류가 난 객체를 실패로 세지 않는다.

## Issue Triage

**이슈 수행 목적**: compactdb가 참조 대상 객체를 읽다가 오류가 나면 참조를 그대로 두고 그 객체를 실패로 보고하게 한다. 참조를 NULL로 바꾸는 것은 대상 객체가 실제로 없을 때만 해야 한다.

**이슈 수행 이유**: `src/executables/compactdb.c:572`(SA)는 `heap_get_visible_version`의 결과가 `S_SUCCESS`가 아니면 `S_ERROR`까지 포함해 참조를 NULL로 바꾼다. 서버 쪽 복사본 `src/storage/compactdb_sr.c:111-120`(CS)은 `S_ERROR`면 오류를 반환하고, 대상이 없을 때만 NULL로 바꾼다. 2015년 `6a1f5b4a38`이 두 복사본에 S_ERROR 처리를 넣었는데, 다음 날 `4fc3ee1760`(CUBRIDSUS-16544, SA compactdb 크래시 회귀)이 SA 쪽 변경을 통째로 되돌리면서 이 처리도 같이 빠졌다. 이후 SA 쪽에 검사를 다시 넣을 때(`d0e8ac3839`, `974e199a08`)도 S_ERROR 분기는 돌아오지 않았다. S_ERROR를 끊어진 참조로 보려는 설계 근거는 찾지 못했다.

**영향**: `cubrid compactdb -S` 실행 중 I/O 오류, 인터럽트, 메모리 부족 등으로 참조 대상 읽기가 실패하면, 살아 있는 객체에 대한 참조가 NULL로 바뀌어 저장된다. 오류가 마지막 객체에서 나면 "3 objects processed."와 종료 코드 0이 출력되어 운영자는 손실을 알 수 없다. 오프라인 관리 도구라 발생 빈도는 낮다. 실제 I/O 오류로 일어나는 장면은 재현하지 않았고, gdb로 오류 반환을 강제했다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

소스 기준은 develop `e64a04a79a`다.

### 1. SA: S_ERROR를 끊어진 참조로 처리 (재현)

| 쪽 | 위치 | 동작 |
| --- | --- | --- |
| SA | `src/executables/compactdb.c:535` `process_value`, 검사 `:572`, NULL 대입 `:575` | `scan_code != S_SUCCESS`이면 `OID_SET_NULL (ref_oid)` 후 1을 반환한다. `process_object`가 `disk_update_instance`(`:653`)로 객체를 다시 쓴다. |
| CS | `src/storage/compactdb_sr.c:86` `process_value`, 검사 `:111-120` | `S_ERROR`면 `ASSERT_ERROR_AND_SET`으로 오류를 반환하고 객체를 갱신하지 않는다. 그 밖의 실패만 NULL로 바꾼다. |

SA에서는 S_ERROR가 남긴 오류 상태도 지워지지 않는다. 같은 묶음의 다음 객체들이 `desc_disk_to_obj`의 `er_errid ()` 검사(`src/loaddb/load_object.c:979-981`)에서 실패로 처리된다. 그 결과 "Only 1 out of 3 objects processed successfully."가 출력되지만, 실패로 집계된 것은 멀쩡한 다른 객체이고 참조가 NULL로 바뀐 객체는 성공으로 집계된다. 이 쓰기는 실패 검사(`compactdb.c:257`)보다 먼저 `db_commit_transaction ()`(`:255`)으로 커밋된다.

### 2. CS: 오류가 난 객체를 실패로 세지 않음 (관찰)

CS는 참조를 지키지만, `process_object`가 오류 코드(이 재현에서는 -13)를 반환해도 호출자 `src/storage/compactdb_sr.c:444-451`은 `-1`만 실패로 센다. 클라이언트는 "Failed objects: 0", 종료 코드 0을 출력한다. 데이터 손실은 없지만 오류 보고가 빠진다.

### 되돌림 커밋에 대해

`4fc3ee1760`의 JIRA 기록(CUBRIDSUS-16544, CUBRIDSUS-16548)은 "Revert stand-alone compactdb changes."뿐이고, 크래시는 같은 커밋이 넣은 참조 갱신(`COPY_OID`) 경로와 맞아 보인다(추론). S_ERROR 처리를 일부러 뺐다는 기록은 없다.

## Repro

Test Build: CUBRID 11.5.0.2802 debug(`debug_gcc` preset), `e64a04a79a`. 소스 변경 없이 gdb로 오류를 주입했다.

```sql
create table tgt (a int) dont_reuse_oid;
create table src (id int, r tgt) dont_reuse_oid;
insert into tgt values (1), (2), (3);
insert into src (id, r) select t.a, t from tgt t;
commit;
```

확인 쿼리:

```sql
select s.id, s.r is null as r_is_null, s.r.a as r_a from src s order by s.id;
select count(*) as tgt_rows from tgt;
```

주입 방법: `process_value`에서 `heap_get_visible_version` 호출 직후(SA `compactdb.c:565`, CS `compactdb_sr.c:109`)에 breakpoint를 두고, N번째 참조에서 `er_set (ER_ERROR_SEVERITY, ..., ER_IO_READ, ...)`로 읽기 오류를 설정한 뒤 `scan_code`를 `S_ERROR`로 바꾼다. 실제 호출은 성공했고 반환값만 바꾼 것이다. `cubrid compactdb`는 `cub_admin`을 fork하므로 SA는 gdb로 `cub_admin compactdb -S -v <db> dba.src`를 직접 실행했다. CS는 `cub_server`에 gdb를 붙이고 `cubrid compactdb -C -v <db> dba.src`를 실행했다.

**Actual Result** (실행 전에는 모두 `(1,0,1) (2,0,2) (3,0,3)`, `tgt_rows = 3`):

| 경우 | compactdb 출력, 종료 코드 | 실행 후 `src` (id, r_is_null, r_a) | `tgt_rows` |
| --- | --- | --- | --- |
| SA, 주입 없음 | "3 objects processed.", 0 | (1,0,1) (2,0,2) (3,0,3) | 3 |
| SA, 첫 참조에 S_ERROR | "Only 1 out of 3 objects processed successfully.", 1 | **(1,1,NULL)** (2,0,2) (3,0,3) | 3 |
| SA, 마지막 참조에 S_ERROR | **"3 objects processed.", 0** | (1,0,1) (2,0,2) **(3,1,NULL)** | 3 |
| CS, 첫 참조에 S_ERROR | "Failed objects: 0 / Modified objects: 0", 0 | (1,0,1) (2,0,2) (3,0,3) | 3 |

`tgt_rows`가 3이므로 NULL이 된 참조는 살아 있는 객체를 가리키고 있었다.

**Expected Result**: 읽기 오류가 난 객체의 참조는 바뀌지 않고, 그 객체는 실패로 집계되며 종료 코드가 실패를 나타낸다.

### 확인하지 않은 것

- 실제 I/O 오류나 페이지 손상으로 `S_ERROR`가 나는 장면은 만들지 않았다. heap/page buffer 경로에 fault-injection 지점이 없다. 결함이 있는 판단은 `scan_code` 값에만 의존한다.
- 집합 속성(`process_set`)과 클래스 인자 없이 전체 DB를 대상으로 한 실행은 하지 않았다.

## 관련 이슈

- CBRD-27965: SA 모드 compactdb의 다른 결함(인덱스가 있는 테이블에서 debug 빌드 SIGSEGV)이다. 원인은 다르다.
- CBRD-28101: 같은 drift 점검에서 나온 정리 항목 묶음이다(SA compactdb의 `tables` 배열 누수 포함).
