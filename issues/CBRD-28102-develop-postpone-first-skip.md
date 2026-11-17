# [Log] 바로 뒤에 system operation이 시작되는 postpone을 log_do_postpone이 실행하지 않는다

**한 줄 요약**: PR #8434(CBRD-27781) 리뷰에서 "develop에서도 트랜잭션의 첫 postpone이 빠지는 경로가 있는가"라는 질문을 받아 develop에서 재현했다. 이 이슈는 log_do_postpone이 system operation의 last parent 위치에 있는 postpone을 건너뛰는 경계 비교 오류를 다룬다.

## Issue Triage

**이슈 수행 목적**: 커밋된 트랜잭션의 모든 postpone이 commit 시점과 재시작 복구 시점 모두에서 빠짐없이 실행되게 한다.

**이슈 수행 이유**: log_do_postpone은 postpone 탐색이 system operation(sysop) 범위의 시작 LSA와 정확히 같은 곳에서 시작하면 그 레코드를 sysop 안쪽으로 보고 건너뛴다. sysop 범위는 sysop 바로 앞 레코드(lastparent)에서 시작한다. 그래서 postpone 바로 뒤에 commit되는 sysop이 시작되고 탐색이 그 postpone에서 시작하면, 그 postpone은 실행되지 않는다. develop에서 일반 DML(relocation된 행의 UPDATE 뒤 INSERT)로 이 상황을 만들었고, postpone 캐시가 넘치는 commit과 재시작 복구 두 경로 모두에서 첫 postpone이 실행되지 않는 것을 로그 덤프로 확인했다.

**영향**: 현재 develop에서 확인한 producer는 RVHF_MARK_REUSABLE_SLOT 하나이고, 결과는 DONT_REUSE_OID 테이블의 slot 하나가 재사용되지 않고 남는 작은 공간 누수다. checkdb는 이를 잡지 못한다. 기본값인 REUSE_OID 테이블에서는 겉으로 드러나는 영향이 없다. 다만 이 함수는 모든 postpone이 실행된다는 전제로 쓰이므로, postpone 바로 뒤에 sysop이 오는 producer가 새로 생기면 그 동작이 조용히 빠진다. OOS 브랜치(PR #8434)에서는 UPDATE의 drop postpone 뒤에 OOS 페이지 할당 sysop이 와서 OOS chain이 누수되었다.

**이슈 수행 방안**: log_do_postpone의 범위 비교를 `LSA_LT`에서 `LSA_LE`로 바꾸어, 탐색이 lastparent에서 시작하면 그 레코드를 sysop 바깥으로 보고 처리하게 한다. OOS 브랜치의 같은 수정(commit b7abf652bc)과 같은 변경이며, develop에 따로 반영한다. 구현은 [PR #8565](https://github.com/CUBRID/cubrid/pull/8565)이고, 시험 케이스는 `shell/_40_guava/cbrd_28102/cases/cbrd_28102.sh`(cubrid-testcases-private-ex, 브랜치 `tc/pr-8565`)다.

---

## AI-Generated Context

## Description

### 동작 원리

트랜잭션이 commit할 때 postpone은 보통 postpone 캐시(log_postpone_cache)에서 실행된다. 캐시가 가득 찼거나 시작 LSA를 찾지 못하면 log_do_postpone이 로그를 앞으로 읽으며 실행한다. 재시작 복구에서 COMMIT_WITH_POSTPONE 상태로 남은 트랜잭션을 마무리할 때도 log_do_postpone을 쓴다. 이때는 캐시가 없다.

log_do_postpone은 log_get_next_nested_top으로 commit된 sysop들의 범위 [lastparent_lsa, sysop end]를 구하고, 그 범위를 건너뛰며 postpone을 찾는다. 범위 처리 부분은 다음과 같다(src/transaction/log_manager.c, develop 149fcf4f6a).

```c
	  if (LSA_LT (&start_seek_lsa, &(nxtop_range->start_lsa)))
	    {
	      end_seek_lsa = &(nxtop_range->start_lsa);
	      LSA_COPY (&next_start_seek_lsa, &(nxtop_range->end_lsa));
	    }
	  else if (LSA_EQ (&start_seek_lsa, &(nxtop_range->end_lsa)))
	    { ... }
	  else
	    {
	      LSA_COPY (&next_start_seek_lsa, &(nxtop_range->end_lsa));
	      continue;	/* 범위 전체를 건너뛴다 */
	    }
```

탐색 시작(start_seek_lsa)이 범위 시작(lastparent)과 같으면 마지막 else로 가서 그 레코드까지 건너뛴다. lastparent는 sysop 바깥 레코드이므로, 그것이 postpone이면 실행되어야 한다. 같아지는 경우는 두 가지다.

```
경우 1: 앞 sysop의 SYSOP_END 바로 뒤에 다음 sysop이 시작   → 같은 자리 = SYSOP_END, 건너뛰어도 무해
경우 2: postpone 바로 뒤에 sysop이 시작, 탐색이 그 postpone에서 시작 → 그 postpone이 실행되지 않음
```

탐색 시작점은 commit 경로에서는 트랜잭션의 첫 postpone(tdes->posp_nxlsa)이다. 재시작 복구에서는 log_recovery_find_first_postpone이 고른 "아직 실행되지 않은 첫 postpone"이다. 따라서 복구 경로에서는 트랜잭션의 첫 postpone이 아니어도, crash 시점에 첫 미실행 postpone이 된 것이 sysop의 lastparent이면 같은 일이 생길 수 있다. 이 두 번째 형태도 재현했다(아래 ANALYSIS 결론 참고).

### develop에서 경우 2가 생기는 경로

MVCC UPDATE가 relocation된 행(REC_RELOCATION)을 고쳐서 새 값이 home 페이지에 들어가거나 새 forward 페이지가 필요하면, heap_update_relocation은 옛 forward 레코드(REC_NEWHOME)를 물리적으로 지우고 RVHF_MARK_REUSABLE_SLOT postpone을 남긴다. 이 postpone이 그 UPDATE의 마지막 로그 레코드다. 같은 트랜잭션의 다음 문장이 INSERT이고 새 heap 페이지가 필요하면, heap_vpid_alloc의 sysop(log_sysop_commit으로 끝남)이 그 사이에 다른 레코드 없이 바로 시작한다. 문장 사이에 savepoint 레코드는 없었다. 그래서 그 sysop의 lastparent가 postpone의 LSA가 된다.

DDL(DROP TABLE, DROP INDEX, LOB 테이블 DROP 등)이 남기는 postpone 뒤에는 카탈로그 삭제(RVCT_DELETE) 레코드가 이어져서 경우 2가 되지 않았다. PR #8434 리뷰어가 DDL 12가지에서 경우 1만 본 것과 맞는 결과다.

## Test Build

CUBRID 11.5.0.2917 debug build, develop 149fcf4f6a (debug_gcc preset). 클라이언트/서버 모드에서 실행했다. SA 모드는 MVCC를 쓰지 않으므로 이 경로를 타지 않는다.

## Repro

1. 데이터베이스를 만들고 서버를 띄운다. commit 경로를 보려면 cubrid.conf `[common]`에 `postpone_cache_size=4`(숨은 파라미터, 최솟값 4)를 넣는다. 복구 경로는 기본값으로 본다.
2. setup SQL을 만들어 실행한다. 압축되지 않는 3000자 값으로 바꾸어 행을 relocation시킨다.

```sh
python3 - > setup.sql <<'EOF'
import base64, os
r = lambda k: base64.b64encode(os.urandom(k)).decode()[:k]
print("create table rel (id int, v varchar(20000)) dont_reuse_oid;")
print("insert into rel select rownum, 'x' from db_class a, db_class b limit 40;")
print("commit;")
for i in range(1, 41):
    print(f"update rel set v = '{r(3000)}' where id = {i};")
print("commit;")
EOF
csql -u dba testdb -i setup.sql
```

3. 시험 트랜잭션을 만들어 실행한다. 첫 UPDATE는 relocation된 행을 줄여 postpone을 남기고, 이어지는 INSERT는 새 heap 페이지를 할당한다. 나머지 UPDATE는 postpone 수를 캐시 크기보다 많게 만든다.

```sh
python3 - > tx.sql <<'EOF'
import base64, os
r = lambda k: base64.b64encode(os.urandom(k)).decode()[:k]
print("create table g (id int, v varchar(20000));")
print(f"insert into g values (0, '{r(10000)}');")
print("commit;")
print(";autocommit off")
print("update rel set v = 'y' where id = 40;")
print(f"insert into g values (1, '{r(10000)}');")
for i in range(30, 40):
    print(f"update rel set v = 'y' where id = {i};")
print("commit;")
EOF
csql -u dba testdb -i tx.sql
```

4. 복구 경로: 3을 실행하기 전에 gdb를 cub_server에 붙여 `break log_postpone_cache::do_postpone if this->m_cursor >= 8`을 걸고, 멈추면 `kill`로 서버를 죽인다. 이 지점은 log_append_commit_postpone이 LOG_COMMIT_WITH_POSTPONE을 flush한 뒤이고, postpone은 하나도 실행되기 전이다. 그 뒤 서버를 다시 띄워 재시작 복구가 postpone을 마무리하게 한다.
5. 서버를 내리고 `cubrid diagdb -d 8 testdb`로 로그를 덤프한다(대화형으로 `1`, `-1`, `-1`, `-1`, `y`를 입력). 시험 트랜잭션의 LOG_POSTPONE마다 그것을 가리키는 LOG_RUN_POSTPONE("Postpone record with LSA = ...")이 있는지 본다.
6. 서버를 띄워 `show slotted page slots of volume=<v> and page=<p>`로 건너뛴 postpone의 slot 상태를 본다.

## Expected Result

시험 트랜잭션의 postpone 11개가 모두 실행된다(LOG_RUN_POSTPONE 11개). 지운 forward slot은 모두 `DELETED_WILL_REUSE`가 된다.

## Actual Result

두 경로 모두 첫 postpone만 실행되지 않았다.

| 실행 | 경로 | 실행된 postpone | 첫 postpone |
|---|---|---|---|
| ovf1 (postpone_cache_size=4) | commit 시 log_do_postpone | 10/11 | LSA 183:13544 실행 안 됨 |
| crash1 (기본 캐시, gdb kill 뒤 재시작) | 재시작 복구 log_do_postpone | 10/11 | LSA 183:13416 실행 안 됨 |
| fixovf1 (비교를 LSA_LE로 바꾼 빌드) | commit 시 log_do_postpone | 11/11 | 실행됨 |
| fixcrash1 (비교를 LSA_LE로 바꾼 빌드) | 재시작 복구 | 11/11 | 실행됨 |

ovf1의 로그 덤프 일부(시험 트랜잭션, 페이지 할당 내부 레코드는 생략):

```
183|13544 LOG_POSTPONE RVHF_MARK_REUSABLE_SLOT  (Volid = 1 Pageid = 651 Offset = 4)
183|13864 LOG_SYSOP_END  Prev parent LSA = 183|13544, LOG_SYSOP_END_LOGICAL_UNDO   (file_alloc)
183|16008 LOG_SYSOP_END  Prev parent LSA = 183|13544, LOG_SYSOP_END_COMMIT         (heap_vpid_alloc)
183|16112 LOG_MVCC_UNDOREDO_DATA RVHF_MVCC_INSERT
...
186|10248 LOG_COMMIT_WITH_POSTPONE
LOG_RUN_POSTPONE x 10   (183|13544를 가리키는 것은 없음)
LOG_COMMIT
```

slot 상태(ovf1, 1|651):

```
Slot_id 1  DELETED_WILL_REUSE
Slot_id 2  DELETED_WILL_REUSE
Slot_id 3  DELETED_WILL_REUSE
Slot_id 4  MARKDELETED          <- 건너뛴 postpone의 slot
Anchor_type 'ANCHORED_DONT_REUSE_SLOTS'
```

LSA_LE 빌드(fixovf1)에서는 같은 slot 4가 `DELETED_WILL_REUSE`였다. ovf1에서 `cubrid checkdb -S`는 rc=0으로 끝나 이 누수를 보고하지 않았다. crash1 덤프에는 LOG_DUMMY_CRASH_RECOVERY가 있어 재시작 복구가 실제로 postpone을 마무리했음을 확인했다.

## Additional Information

### develop의 postpone producer와 경우 2 가능성

| producer | 위치 | 바로 뒤에 commit되는 sysop | 확인 |
|---|---|---|---|
| RVHF_MARK_REUSABLE_SLOT (relocation UPDATE) | heap_file.c heap_update_relocation, heap_log_delete_physical | 다음 문장의 heap 페이지 할당(heap_vpid_alloc) | 재현함 |
| RVHF_MARK_REUSABLE_SLOT (non-MVCC delete) | heap_file.c 23379, 23884 | 가능성 있음 | 재현 안 함 |
| RVVAC_NOTIFY_DROPPED_FILE, RVFL_DESTROY, RVBT_REMOVE_UNIQUE_STATS | vacuum.c 6173, file_manager.c 4372, btree.c 6365 | DROP 뒤에는 RVCT_DELETE가 이어짐 | DROP TABLE, DROP INDEX 등에서 경우 2 없음 |
| RVHF_LOB_REMOVE_DIR | locator_sr.c 14844 | LOB 테이블 DROP에서 경우 2 없음 | 덤프로 확인 |
| RVFL_DEALLOC, RVDK_UNRESERVE_SECTORS | file_manager.c 6130, disk_manager.c 4934 | 주로 sysop 안이나 run postpone 중 | 코드만 확인 |
| RVHF_MARK_DELETED, RVHF_APPEND_PAGES_TO_HEAP, RVBT_NO_LOGGING_INDEX_DURABLE, RVBT_DELETE_OBJECT_POSTPONE | heap_file.c 5528, 28773, btree_load.c 1741, btree.c 27161 | 미확인 | 코드만 확인 |

### 관련 이슈

- CBRD-27781 / PR #8434: OOS 브랜치에서 같은 비교를 LSA_LE로 고쳤다(commit b7abf652bc). 거기서는 UPDATE의 drop postpone 뒤에 OOS 페이지 할당 sysop이 와서, 고치기 전 release 3000행 실행 7번 중 5번에서 chain 누수가 났고, 고친 뒤 4번 중 0번이었다.
- CBRD-27987(analysis의 tran_start_postpone_lsa가 헤더 하나만큼 어긋남)과 CBRD-28065(logpb_flush_pages의 LSA_LT 경계)는 다른 위치의 다른 문제다.

### ANALYSIS 결론

- **log_recovery_find_first_postpone은 바꾸지 않는다.** 이 함수의 `LSA_LT`는 같은 경계에서 start_postpone_lsa 하나만 건너뛴다. 그 레코드는 이 함수가 원래 결과에서 빼는 레코드이므로 결과가 달라지지 않는다. log_do_postpone만 고친 빌드에서 아래 두 복구 시험이 모두 통과했다.
- **복구 경로의 두 번째 형태를 재현했다.** 시험 트랜잭션을 `UPDATE(id=40)`, `UPDATE(id=39)`, `INSERT`, 나머지 UPDATE 순서로 바꾸어, 두 번째 postpone이 페이지 할당 sysop의 lastparent가 되게 했다. gdb로 첫 RVHF_MARK_REUSABLE_SLOT의 LOG_RUN_POSTPONE을 flush한 뒤 서버를 죽이면, 재시작 복구는 두 번째 postpone부터 탐색을 시작한다. 수정 전에는 10/11만 실행되었고(두 번째 postpone LSA 184:256 실행 안 됨), 수정 뒤에는 11/11이 실행되었다.
- **develop에 따로 반영한다.** OOS 브랜치에는 이미 같은 수정(같은 비교와 주석)이 있으므로, OOS가 develop에 병합될 때 충돌이 생기지 않을 것으로 본다(추론). develop만으로도 DONT_REUSE_OID 테이블의 slot 누수가 있으므로 OOS 병합을 기다리지 않는다.
- **수정 빌드 결과**(develop 666bb10ae6 + PR #8565, debug build):

| 시험 | 수정 전 | 수정 뒤 |
|---|---|---|
| commit 경로, postpone_cache_size=4 | 10/11 | 11/11 |
| 복구, postpone 실행 전 crash | 10/11 | 11/11 |
| 복구, 첫 postpone 실행 뒤 crash(두 번째 형태) | 10/11 | 11/11 |
| 건너뛴 postpone의 slot 상태 | MARKDELETED | DELETED_WILL_REUSE |

- sysop 자체의 postpone(log_sysop_do_postpone)도 같은 함수를 거치므로 같은 수정이 적용된다. 이 경로에서 경우 2를 만드는 producer는 찾지 못했고 재현하지 않았다.
