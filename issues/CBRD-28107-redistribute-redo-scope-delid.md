# [Storage] 파티션 재분배 뒤 크래시 복구가 삭제된 행을 되살린다 (재분배 redo 로그의 DELID 미초기화, redo 버퍼 stack-use-after-scope)

**한 줄 요약**: 중복 코드 drift 점검에서 CBRD-27206이 고친 stack-use-after-scope가 쌍둥이 함수 `heap_rv_mvcc_redo_redistribute`에는 남아 있는 것을 찾았고, 재현하다가 같은 로그 레코드를 남기는 `heap_mvcc_log_redistribute`가 DELID 자리에 초기화하지 않은 값을 기록하는 것을 확인했다. 파티션 재구성을 커밋한 뒤 checkpoint 전에 서버가 비정상 종료하면, release 빌드에서도 복구 후 삭제한 행이 다시 조회되고 heap과 인덱스가 어긋나며 vacuum으로 회복되지 않는다.

## Issue Triage

**이슈 수행 목적**: 파티션 재분배 중에 남은 로그를 재시작 복구가 다시 적용할 때, 원래의 DELID와 정의된 버퍼로 레코드를 복원하게 한다. 크래시 복구 뒤에도 삭제된 행은 보이지 않고 heap과 인덱스가 일치해야 한다.

**이슈 수행 이유**: `heap_mvcc_log_redistribute`(`src/storage/heap_file.c:26403`)는 `MVCCID delid`를 대입하지 않고 `RVHF_MVCC_REDISTRIBUTE` 로그에 넣는다. redo `heap_rv_mvcc_redo_redistribute`는 그 값을 복원된 레코드의 DELID로 쓴다. 같은 redo 함수는 레코드를 만든 스택 버퍼를 블록 밖에서 읽는다(쌍둥이 함수는 CBRD-27206에서 고쳐졌다). 두 결함 모두 develop `e64a04a79a`의 debug, release, ASAN 빌드에서 재현했다.

**영향**: 아직 vacuum되지 않은 삭제 행이 있는 테이블에 `ALTER TABLE ... REMOVE PARTITIONING`(또는 `REORGANIZE`, `COALESCE`, 해시 `PARTITION BY`)를 커밋하고, 해당 heap 페이지가 디스크에 기록되기 전에 서버가 비정상 종료하면 다음이 일어난다. 크래시 6회(debug 4, release 2) 모두 같았다.
- 사용자: 삭제한 행이 heap 스캔으로 다시 보인다. 인덱스 경로는 보이지 않으므로 쿼리 결과가 실행 계획에 따라 달라진다.
- 운영자: `checkdb`가 heap/인덱스 불일치로 실패한다. vacuum(`vacuumdb -S` 포함)으로 정리되지 않아 손상이 남는다. 되살아난 행을 DELETE하면 release는 잠금 오류(-1002) 또는 `Unknown key` 오류로 실패하고, debug 서버는 assert로 종료한다.
- ASAN 빌드에서는 복구가 매번 stack-use-after-scope로 중단되어 서버가 기동하지 못한다. 일반 -O2 빌드에서 버퍼 결함이 증상을 내지는 않을 것으로 본다(어셈블리 분석, 추론).
- HA 복제 적용과 미디어 복구는 실행하지 않았다. 같은 redo 함수를 쓴다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

소스 기준은 develop `e64a04a79a`다. 아래 1은 중복 코드 drift 점검에서, 2는 1을 재현하다가 찾았다.

### 1. 블록 밖에서 버퍼 사용 (재현)

| 쪽 | 위치 | 상태 |
| --- | --- | --- |
| 결함 | `src/storage/heap_file.c:26466` `heap_rv_mvcc_redo_redistribute` | `data_buffer`를 `else` 블록 안(`:26495`)에 선언한다. 블록이 끝난 뒤 `:26534` `spage_insert_for_recovery (thread_p, rcv->pgptr, slotid, &recdes)`가 `recdes.data`(그 버퍼)를 읽는다. |
| 고쳐진 쌍둥이 | `src/storage/heap_file.c:17407` `heap_rv_mvcc_redo_insert` | CBRD-27206(`1ffcf1257b`, #7647)에서 `data_buffer`를 함수 범위(`:17415`)로 옮겼다. |

로그를 남기는 경로: `heap_insert_logical`에서 `UPDATE_INPLACE_OLD_MVCCID`이고 레코드에 유효한 DELID가 있으면 재분배 삽입으로 처리하고(`heap_file.c:21667`), `heap_mvcc_log_redistribute`가 `RVHF_MVCC_REDISTRIBUTE`를 기록한다. 이 모드는 `src/transaction/locator_sr.c:12853` `redistribute_partition_data`만 쓴다.

### 2. 로그의 DELID가 초기화되지 않는다 (재현, 데이터 손상)

```c
// src/storage/heap_file.c:26403- heap_mvcc_log_redistribute (develop e64a04a79a)
  MVCCID delid;                         /* 대입하는 곳이 없다 */
  MVCC_REC_HEADER mvcc_rec_header;
  ...
      or_mvcc_get_header (p_recdes, &mvcc_rec_header);
      assert (MVCC_IS_FLAG_SET (&mvcc_rec_header, OR_MVCC_FLAG_VALID_DELID));
      ...
      redo_crumbs[n_redo_crumbs].length = OR_MVCCID_SIZE;
      redo_crumbs[n_redo_crumbs++].data = &delid;
```

레코드 헤더에서 DELID를 읽어 두고(`mvcc_rec_header`) 로그에는 대입하지 않은 지역 변수 `delid`를 넣는다. redo(`:26503` `OR_GET_MVCCID`, `:26524` `MVCC_SET_DELID`)는 이 값을 복원된 레코드의 DELID로 쓴다. -O2 어셈블리에서도 그 스택 슬롯에 쓰는 명령이 없다.

실측된 DELID(크래시 후 redo 계측): 이 재현에서 삭제와 재분배는 같은 트랜잭션이므로 올바른 DELID는 redo 레코드의 INSID와 같아야 한다.
- debug(-O0): redo 1000건 모두 `0x181fa070b27f0000`이었다. 스택 주소를 바이트 순서만 뒤집은 값이다. 앞으로 발급될 어떤 MVCCID보다 커서, 스냅샷은 "삭제 트랜잭션이 아직 진행 중"으로 보고 행을 보여준다.
- release(-O2): 레코드마다 달랐다. 500건 중 451건은 0, 49건은 2^32보다 큰 값이었다. 0이면 `MVCC_IS_HEADER_DELID_VALID`(`src/transaction/mvcc.h:87`)가 거짓이 되어 삭제되지 않은 행으로 본다. 정상 범위의 커밋된 MVCCID는 하나도 없었다.

vacuum이 정리하지 못하는 이유(추론): `mvcc_satisfies_vacuum`(`src/transaction/mvcc.c:321`)은 DELID가 무효이거나 oldest보다 크면 삭제되지 않은 행 또는 최근 삭제로 보고 INSID만 정리한다.

되살아난 행을 지울 때: `locator_get_settled_last_version`(`src/transaction/locator_sr.c:13180`)이 가짜 DELID의 트랜잭션이 끝나기를 기다린다. 그 MVCCID는 활성으로 보이지만 소유자가 없어서, debug에서는 `logtb_wait_for_tran_end`의 `assert (false)`(`src/transaction/log_tran_table.c:4364`)에 걸리고 release에서는 잠금 오류를 반환한다.

## Repro

Test Build: CUBRID 11.5.0.2802, `e64a04a79a`. 데이터 손상은 `debug_gcc`(-O0)와 `release_gcc`(-O2), 버퍼 결함은 `asan_debug_gcc`(GCC 11.5.0, use-after-scope 탐지 기본값)로 확인했다. 재현 동안 checkpoint가 돌지 않도록 DB에 `checkpoint_interval=60min`, `checkpoint_every_size=10G`를 설정했다.

```sql
-- setup
create table t_d4 (id int primary key, v varchar(200))
  partition by range (id) (partition p0 values less than (500), partition p1 values less than maxvalue);
insert into t_d4 select rownum, repeat('x', 150) from db_class a, db_class b, db_class c limit 1000;
commit;

-- csql --no-auto-commit: 한 트랜잭션에서 삭제 후 재분배
delete from t_d4 where mod(id, 2) = 0;
alter table t_d4 remove partitioning;
commit;
```

그다음 checkpoint 전에 `kill -9`로 `cub_server`를 종료하고 서버를 다시 시작해 복구를 실행한다. 확인 쿼리:

```sql
select id from t_d4 where id between 1 and 12 order by id;   -- PK 인덱스 경로
select id from t_d4 where id + 0 between 1 and 12;           -- heap 스캔 경로
```

```sh
cubrid checkdb -C <db>
```

**Expected Result**: 두 쿼리 모두 `1 3 5 7 9 11`, 보이는 행은 500개, `checkdb` 성공. 크래시 없이 같은 절차를 실행한 대조군은 이렇게 나왔다.

**Actual Result** (debug, release 모두):
- 인덱스 경로는 `1 3 5 7 9 11`, heap 스캔은 `1 2 3 4 5 6 7 8 9 10 11 12`. 보이는 행 1000개.
- `checkdb`: `INDEX pk_t_d4_id ... the number of OIDs in the unique hierarchy: 1000 does not equal the number of OIDs: 500 found in the unique B+tree`와 키마다 `B+tree key N entry for object OID ... was not found`.
- release에서 `delete from t_d4 where mod(id,2)=0`은 `ERROR: The current transaction could not acquire a database lock it requires to continue processing.`, `delete from t_d4 where id + 0 = 2`는 `ERROR: Unknown key 2 referenced in B+tree index`.

**ASAN 빌드 Actual Result**: 재시작 복구가 매번 아래 보고로 중단된다. ASAN csql은 CBRD-27875(DELETE prepare 경로의 다른 stack-use-after-scope)에 먼저 걸리므로, 이 경우 DELETE에 `/*+ RECOMPILE */` 힌트를 붙였고 csql이 커밋 전에 중단되어 재분배 트랜잭션은 커밋되지 않은 상태로 복구됐다. 복구는 redo 단계에서 미완료 트랜잭션의 로그도 다시 적용하므로 같은 함수가 실행된다.

```
ERROR: AddressSanitizer: stack-use-after-scope on address 0x7fe58b4cc030
READ of size 180 at 0x7fe58b4cc030 thread T34
    #0 __interceptor_memcpy
    #1 spage_insert_for_recovery(...) src/storage/slotted_page.c:1987
    #2 heap_rv_mvcc_redo_redistribute(...) src/storage/heap_file.c:26534
    #3 log_rv_redo_record_sync<log_rec_mvcc_undoredo>(...) src/transaction/log_recovery_redo.hpp:646
  ...
    [176, 16600) 'data_buffer' (line 26495) <== Memory access at offset 176 is inside this variable
```

### 확인하지 않은 것

- HA 복제 적용, `restoredb` 뒤 로그 재적용.
- `REMOVE PARTITIONING` 외의 재분배 진입점(모두 `redistribute_partition_data`를 거치는 것은 코드로 확인).
- 이미 손상된 DB를 복구하는 방법.

## 관련 이슈

- CBRD-27206: 쌍둥이 함수 `heap_rv_mvcc_redo_insert`의 같은 결함을 고친 이슈다.
- CBRD-27875: 재현 중 ASAN csql이 먼저 걸리는 DELETE prepare 경로의 stack-use-after-scope다.
- CBRD-28101: 같은 drift 점검에서 나온 정리 항목 묶음이다.
