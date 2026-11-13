# [Query] do_replace_into가 db_is_deleted 오류를 버려 REPLACE가 원래 오류 대신 고유 키 위반을 반환하는 문제

**한 줄 요약**: CodeQL 경고(도달할 수 없는 코드)를 확인하다가, `do_replace_into`에서 `retval = error;`가 `goto cleanup;` 뒤에 있어 `db_is_deleted` 오류가 반환값에 실리지 않는다는 것을 확인했다. gdb fault injection으로 이때 REPLACE가 원래 오류 대신 고유 키 위반 오류로 끝나는 것을 재현했다. 원래 오류 코드를 호출자에게 돌려주어야 한다.

## Issue Triage

**이슈 수행 목적**: `do_replace_into`에서 `db_is_deleted`가 오류를 반환하면 그 오류 코드를 REPLACE 문의 결과로 돌려준다.

**이슈 수행 이유**: `src/query/execute_statement.c:13174-13178`(develop `e64a04a79a`)는 `db_is_deleted`가 음수를 반환하면 `goto cleanup;`을 먼저 실행하고, 그 뒤의 `retval = error;`는 실행되지 않는다. 함수는 그때까지 삭제한 행 수(0 이상)를 반환하고, 두 호출자는 0 이상을 성공으로 보고 새 행 삽입을 계속한다. 충돌한 기존 행은 삭제되지 않았으므로 삽입은 고유 키 위반으로 실패한다. 2015년 커밋 `6a46b5dffd`(CUBRIDSUS-15027)가 `db_is_deleted` 오류를 처리하려고 넣은 두 줄의 순서가 바뀐 것으로 보인다.

**영향**: 클라이언트 측에서 실행되는 REPLACE만 해당한다. 대상 클래스에 DELETE 트리거가 있거나 `insert_execution_mode`가 서버 측 실행을 허용하지 않을 때다. 이 경로에서 `db_is_deleted` 안의 `obj_lock`이 객체 없음(`ER_HEAP_UNKNOWN_OBJECT`) 외의 오류로 실패하면, 사용자와 응용은 원래 원인(예: 인터럽트, 통신 오류) 대신 `ER_BTREE_UNIQUE_FAILED`(-670)를 받는다. 오류 메시지가 실제 원인을 가리키지 않아 진단이 어려워진다. 성공으로 잘못 보고되는 경우는 찾지 못했다(코드 추론, 아래 참고). 자연 재현은 관찰하지 않았고, 재현은 gdb로 오류를 강제한 fault injection이다. 동시 DELETE와 잠금 대기 시나리오에서는 이 분기에 도달하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`do_replace_into`는 REPLACE를 클라이언트 측에서 실행할 때 호출된다. 삽입할 값과 고유 키가 충돌하는 기존 행을 찾아 삭제하고, 삭제한 행 수를 반환한다. 오류가 나면 음수 오류 코드를 반환해야 한다.

```c
/* src/query/execute_statement.c:13168-13192 (develop e64a04a79a) */
  retval = 0;
  for (i = 0; i < oids_count; i++)
    {
      obj = ws_mop (&oids[i], NULL);
      error = db_is_deleted (obj);
      if (error < 0)
	{
	  goto cleanup;
	  retval = error;
	}
      if (error > 0)
	{
	  error = NO_ERROR;
	  continue;
	}

      error = delete_object_tuple (obj);
      if (error != NO_ERROR)
	{
	  retval = error;
	  goto cleanup;
	}
      retval++;
    }
```

- **도달 불가 대입**: 13177행 `retval = error;`는 `goto` 뒤에 있어 실행되지 않는다. 같은 함수의 다른 두 오류 분기는 `retval = error;` 다음에 `goto cleanup;`을 둔다.
- **반환값**: `retval`은 루프 시작 전 0이고 행을 하나 삭제할 때마다 1씩 는다. 따라서 오류가 나도 0 이상의 값(그때까지 삭제한 행 수)을 반환한다. `er_errid ()`에는 원래 오류가 남아 있다.
- **호출자 동작**: `do_insert_template`(13578-13590행)은 반환값이 양수면 `row_count`에 더하고 `error = NO_ERROR`로 둔 뒤 삽입을 계속한다. `insert_subquery_results`(14084-14099행)는 음수일 때만 오류로 처리하고, 아니면 `cnt`에 더한 뒤 삽입을 계속한다. 두 경우 모두 충돌 행이 남아 있어 템플릿을 반영할 때 고유 키 위반이 난다.
- **성공으로 보고될 가능성**: 충돌 행 검색(`do_find_unique_constraint_violations`)은 `btree_find_multi_uniques`를 `S_DELETE`로 호출해 서버에서 해당 OID에 잠금을 잡는다. 따라서 검색과 삽입 사이에 충돌 행이 사라져 삽입이 성공하는 경로는 찾지 못했다. 이는 코드를 읽고 판단한 결과이며 실행으로 확인하지 않았다.

### 이 분기에 도달하는 조건

- **클라이언트 측 REPLACE**: `is_server_insert_allowed`는 REPLACE 대상에 고유 제약과 DELETE 트리거가 함께 있으면 서버 측 실행을 허용하지 않는다. `insert_execution_mode`, INSERT ... INTO 변수, 대상 클래스의 INSERT 트리거 등도 클라이언트 측 실행을 만든다. 트리거가 없는 단일 행 REPLACE ... VALUES는 기본 설정에서 서버 측에서 실행되어 이 함수를 거치지 않는다(gdb로 확인함).
- **`db_is_deleted`의 음수 반환**: `db_is_deleted`(`src/compat/db_info.c:559-597`)는 MOP의 삭제 표시나 잠금 정보로 판단할 수 없으면 `obj_lock (obj, 0)`을 호출한다. `obj_lock`이 `ER_HEAP_UNKNOWN_OBJECT`로 실패하면 1(삭제됨)을 반환하고, 그 밖의 오류는 그대로 반환한다. 이 오류가 정상 운영에서 어떤 원인으로 나는지(인터럽트, 통신 오류, 메모리 부족 등)는 확인하지 않았다.

### Test Build

- 정적 분석: CodeQL 2.27.4, build-mode none, CUBRID develop `e64a04a79a`. 질의 묶음 `cubrid-bugs.qls`(선별한 CodeQL 질의 모음)에서 나온 경고이며, 질의 묶음을 구성한 에이전트가 소스와 대조했고 이 이슈를 쓰며 다시 확인했다.
- 재현: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux). `30043f4`는 `e64a04a79a`의 조상이며, 두 리비전의 `do_replace_into` 함수 본문과 `src/compat/db_info.c`는 같다. 다만 `execute_statement.c`의 행 번호는 `30043f4`에서 112행 앞에 있다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro (fault injection)

자연 재현이 아니다. gdb로 `db_is_deleted` 안의 `obj_lock` 결과를 `ER_INTERRUPTED`(-4)로 바꾸고 같은 오류를 `er_set`으로 설정한다. 아래 `execute_statement.c` 행 번호는 설치 빌드(`30043f4`) 기준이며, `e64a04a79a`에서는 각각 112를 더한다(13176, 13195). `db_info.c:583`은 두 리비전에서 같다.

```sh
mkdir -p rpl && (cd rpl && cubrid createdb --db-volume-size=64M --log-volume-size=64M rpl_db en_US.utf8)

cat > setup.sql <<'EOF'
create table t (id int primary key, v int);
insert into t values (1, 10);
create trigger t_del before delete on t execute print 'delete trigger fired';
commit;
EOF

cat > replace.sql <<'EOF'
replace into t values (1, 20);
select * from t order by id;
EOF

cat > inject.gdb <<'EOF'
set debuginfod enabled off
set pagination off
set breakpoint pending on
break db_info.c:583
commands
  silent
  printf "[FAULT INJECTION] db_is_deleted: obj_lock returned %d, forcing -4 (ER_INTERRUPTED)\n", error
  call (void) er_set (1, "fault-injection", 0, -4, 0)
  set var error = -4
  continue
end
break execute_statement.c:13064
commands
  silent
  printf "[observe] do_replace_into: db_is_deleted error=%d, retval=%d at 'goto cleanup'\n", error, retval
  continue
end
break execute_statement.c:13083
commands
  silent
  printf "[observe] do_replace_into cleanup: returning retval=%d, er_errid()=%d\n", retval, (int) er_errid ()
  continue
end
run
quit
EOF

csql -S -u dba -i setup.sql rpl_db
gdb -batch -x inject.gdb --args "$CUBRID/bin/csql" -S -u dba -i replace.sql rpl_db

cubrid deletedb rpl_db
```

### Expected Result

REPLACE가 `ER_INTERRUPTED`(-4, `Has been interrupted.`)로 실패하고, 삽입을 시도하지 않는다.

### Actual Result

`30043f4` debug 빌드, SA 모드에서 관찰한 결과다(gdb와 csql 출력 발췌, 인덱스와 클래스 식별자 생략).

```text
[FAULT INJECTION] db_is_deleted: obj_lock returned 0, forcing -4 (ER_INTERRUPTED)
[observe] do_replace_into: db_is_deleted error=-4, retval=0 at 'goto cleanup'
[observe] do_replace_into cleanup: returning retval=0, er_errid()=-4
In the command from line 1,
ERROR: Operation would have caused one or more unique constraint violations. INDEX pk_t_id(...) ON CLASS dba.t(...). key: 1(...).

           id            v
==========================
            1           10
```

- `do_replace_into`는 `er_errid ()`가 -4인 상태에서 0을 반환했다.
- 호출자는 삽입을 계속했고, REPLACE는 `ER_BTREE_UNIQUE_FAILED`(-670) 메시지로 끝났다. 기존 행은 바뀌지 않았다.
- 같은 구조의 테이블(고유 키와 DELETE 트리거)에서 fault injection 없이 실행하면 `obj_lock`이 0을 반환하고, REPLACE는 `2 rows affected`로 성공해 행이 `(1, 20)`이 되었다.

### 자연 재현 시도 (재현되지 않음)

같은 설치 빌드에서 서버 모드(`csql -C`)로 두 세션을 사용했다. 테이블과 DELETE 트리거는 위와 같다.

- **동시 DELETE**: 세션 A가 `delete from t where id = 1;`을 커밋하지 않고 잡은 상태에서 세션 B가 `replace into t values (1, 20);`을 실행했다. B는 A가 커밋할 때까지 약 4초 기다린 뒤 충돌 행을 찾지 못했고, `db_is_deleted`를 호출하지 않은 채 `1 row affected`로 성공했다.
- **잠금 대기 시간 초과**: 세션 A가 `update t set v = 11 where id = 1;`을 커밋하지 않고 잡은 상태에서 세션 B가 `lock_timeout=2`로 REPLACE를 실행했다. B는 충돌 행 검색 단계에서 X_LOCK 대기 시간 초과 오류를 정상적으로 받았고, `db_is_deleted`에는 도달하지 않았다.

이미 삭제된 행은 `db_is_deleted`가 1을 반환하므로 이 결함을 일으키지 않는다. 충돌 행 검색이 잠금을 잡은 뒤에 `obj_lock`이 실패해야 하므로, 자연 재현에는 그 사이의 인터럽트나 통신 실패 같은 조건이 필요하다.

### Additional Information

- 관련 이슈: [CBRD-27549](https://jira.cubrid.org/browse/CBRD-27549)는 클라이언트의 통계, 히스토그램, 도메인 검사, CREATE TABLE 경로가 서버 중단이나 abort 오류를 삼키거나 다른 오류로 바꾸는 문제를 다룬다. 원래 오류를 잃고 다른 오류를 보고한다는 점은 같지만, 다루는 함수가 다르고 REPLACE와 `db_is_deleted`는 포함하지 않는다.
- ANALYSIS 확인 사항: 정상 운영에서 `db_is_deleted`의 `obj_lock`이 `ER_HEAP_UNKNOWN_OBJECT` 외의 오류를 반환하는 조건이 무엇인지, 그리고 그 조건을 자연적으로 재현할 수 있는지 확인하지 않았다.
- ANALYSIS 확인 사항: 고유 제약이 여러 개여서 충돌 행이 둘 이상일 때, 앞 행을 삭제한 뒤 다음 행에서 오류가 나면 이미 삭제한 행과 DELETE 트리거의 효과가 문장 단위로 롤백되는지 확인하지 않았다. 이 경우 반환값은 양수가 되어 `row_count`에도 더해진다.
- ANALYSIS 확인 사항: 원래 오류가 트랜잭션을 서버에서 중단시키는 종류(예: 교착 상태 희생, `ER_LK_UNILATERALLY_ABORTED`)일 때 클라이언트가 삽입을 계속하면 어떤 결과가 되는지 확인하지 않았다.
