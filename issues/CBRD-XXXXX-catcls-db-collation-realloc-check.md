# [Catalog] catcls_get_db_collation이 realloc 실패를 잘못된 포인터로 검사해 NULL을 역참조하고 기존 버퍼를 잃는 문제

**한 줄 요약**: CodeQL 경고(`cpp/redundant-null-check-simple`)를 확인하다가, `catcls_get_db_collation`이 `_db_collation` 결과 배열을 늘리는 `db_private_realloc` 뒤에 `*db_collations` 대신 `db_collations`를 검사해 할당 실패를 놓친다는 것을 확인했다. gdb fault injection으로 이 경우 NULL 기준 주소에 `memset`을 해 프로세스가 종료되는 것을 재현했다. 실패를 오류로 처리하고 기존 버퍼를 잃지 않게 해야 한다.

## Issue Triage

**이슈 수행 목적**: `catcls_get_db_collation`에서 배열 확장이 실패하면 `ER_OUT_OF_VIRTUAL_MEMORY`를 반환하고, 그때까지 읽은 배열을 호출자가 해제할 수 있게 한다.

**이슈 수행 이유**: `src/storage/catalog_class.c:5401-5402`(develop `e64a04a79a`)는 `*db_collations`에 `db_private_realloc` 결과를 대입한 뒤 `if (db_collations == NULL)`을 검사한다. `db_collations`는 호출자 지역 변수의 주소이므로 항상 NULL이 아니다. 따라서 확장이 실패해도 오류 처리로 가지 않고, 다음 줄에서 NULL 기준 주소의 배열 원소에 `memset`을 한다. 또 실패 시에도 유지되는 기존 버퍼의 유일한 포인터를 NULL로 덮어쓰므로, 검사만 고쳐도 기존 버퍼는 해제할 수 없게 된다.

**영향**: 이 함수는 데이터베이스를 재시작할 때마다 실행된다. `cub_server` 기동과 `csql -S` 같은 SA 모드 접속이 `boot_restart_server`에서 DB의 콜레이션을 시스템 콜레이션과 비교하고, `cubrid synccolldb`도 이 함수를 호출한다. 다만 결함이 있는 확장 분기는 `_db_collation` 행이 `LANG_MAX_COLLATIONS`(256)개를 넘을 때만 실행되고, 그때 메모리 할당도 실패해야 한다. 콜레이션 ID는 256 미만이고 사용자는 `_db_collation`에 직접 INSERT할 수 없으므로(확인함), 정상 운영에서 이 분기에 도달하는 경로는 찾지 못했다. 자연 재현은 관찰하지 않았고, 재현은 gdb로 조건을 강제한 fault injection이다. 도달하면 서버 기동 또는 SA 유틸리티가 SIGSEGV로 종료된다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`catcls_get_db_collation`은 시스템 카탈로그 `_db_collation`의 모든 행을 읽어 `LANG_COLL_COMPAT` 배열로 돌려준다. 처음에는 `LANG_MAX_COLLATIONS`(256)개 크기로 할당하고, 행이 더 있으면 크기를 두 배로 늘린다.

```c
/* src/storage/catalog_class.c:5397-5410 (develop e64a04a79a) */
      if (*coll_cnt >= max_coll_cnt)
	{
	  max_coll_cnt = max_coll_cnt * 2;
	  alloc_size = max_coll_cnt * sizeof (LANG_COLL_COMPAT);
	  *db_collations = (LANG_COLL_COMPAT *) db_private_realloc (thread_p, *db_collations, alloc_size);
	  if (db_collations == NULL)
	    {
	      error = ER_OUT_OF_VIRTUAL_MEMORY;
	      goto exit;
	    }
	}

      curr_coll = &((*db_collations)[(*coll_cnt)++]);
      memset (curr_coll, 0, sizeof (LANG_COLL_COMPAT));
```

- **검사 대상 오류**: 함수 인자 `db_collations`(`LANG_COLL_COMPAT **`)는 호출자의 지역 변수 주소이고, 함수 시작에서 `assert (db_collations != NULL)`로 확인한다. 5402행의 검사는 항상 거짓이다. 바로 위 최초 할당(`*db_collations == NULL` 검사)은 올바르다.
- **NULL 역참조**: 확장이 실패하면 `*db_collations`가 NULL이 되고, 5409행이 `NULL + coll_cnt * sizeof (LANG_COLL_COMPAT)` 주소를 계산해 5410행의 `memset`이 그 주소에 쓴다.
- **기존 버퍼 누수**: `db_private_realloc`이 이 함수에서 쓰는 `realloc`과 lea heap 재할당(`hl_lea_realloc`)은 실패 시 기존 블록을 해제하지 않는다. 결과를 `*db_collations`에 바로 대입하므로 기존 블록의 유일한 포인터가 사라진다. 호출자(`boot_restart_server`, `synccoll_check`)는 오류 시 `*db_collations`가 NULL이 아니면 해제하지만, 이때는 NULL이라 기존 블록을 해제하지 못한다. 따라서 5402행의 검사만 `*db_collations`로 바꾸면 크래시는 사라지지만 누수는 남는다. 이 누수는 코드를 읽고 판단한 결과이며, fault injection에서는 기존 버퍼가 데이터를 그대로 가진 채 포인터만 NULL로 바뀐 것을 확인했다.

### 실행 시점

- `boot_restart_server`(`src/transaction/boot_sr.c:2631-2652`)가 `check_db_coll`이 참일 때 호출한다. `cub_server` 기동, SA 모드(`csql -S`, `cubrid checkdb -S` 등) 접속이 여기에 해당한다. `synccolldb` 자신과 `copydb`의 내부 재시작은 이 검사를 끈다.
- `cubrid synccolldb`의 `synccoll_check`(`src/executables/util_sa.c:3158`)가 직접 호출한다.
- 확장 분기는 `_db_collation` 행이 256개를 넘을 때만 실행된다. 행은 `createdb`와 `synccolldb`가 로드된 콜레이션으로 채우며, 콜레이션 ID는 `LANG_MAX_COLLATIONS` 미만이다. DBA 계정으로 `_db_collation`에 직접 INSERT하면 `INSERT is not authorized on _db_collation.` 오류가 난다(확인함).

### Test Build

- 정적 분석: CodeQL 2.27.4, build-mode none, CUBRID develop `e64a04a79a`. `cubrid-bugs.qls` 질의 묶음을 구성하며 후보 질의 `cpp/redundant-null-check-simple`의 결과를 소스와 대조할 때 확인한 경고다.
- 재현: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux), SA 모드. `30043f4`는 `e64a04a79a`의 조상이며, 두 리비전의 `catcls_get_db_collation` 함수 본문은 같고 `src/base/memory_alloc.c`도 바뀌지 않았다. 다만 이 함수의 행 번호는 `30043f4`에서 16행 뒤에 있다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro (fault injection)

자연 재현이 아니다. gdb로 두 조건을 강제한다. 첫째, 확장 분기에 들어가도록 `max_coll_cnt`를 256에서 2로 낮춘다. 둘째, `db_private_realloc` 호출을 건너뛰고 결과 NULL을 대입해 할당 실패를 흉내 낸다. 아래 행 번호는 `e64a04a79a` 기준이며, `30043f4` 빌드에서는 각각 16을 더한다(5413, 5417, 5418, 5425).

```sh
mkdir -p collrealloc && (cd collrealloc && cubrid createdb --db-volume-size=64M --log-volume-size=64M collrealloc_db en_US.utf8)

cat > inject.gdb <<'EOF'
set var $old = (void *) 0
set pagination off
set breakpoint pending on
break catalog_class.c:5397
commands 1
  silent
  printf "[row-check] coll_cnt=%d max_coll_cnt=%d\n", *coll_cnt, max_coll_cnt
  if max_coll_cnt == 256
    set var max_coll_cnt = 2
  end
  continue
end
break catalog_class.c:5401
commands 2
  silent
  printf "[before-realloc] *db_collations=%p coll_cnt=%d\n", *db_collations, *coll_cnt
  set var $old = *db_collations
  set var *db_collations = 0
  jump 5402
end
break catalog_class.c:5409
commands 3
  silent
  printf "[after-check] *db_collations=%p coll_cnt=%d old=%p\n", *db_collations, *coll_cnt, $old
  continue
end
run
bt 3
frame 1
p curr_coll
p $old
kill
quit
EOF

gdb -q -batch -x inject.gdb --args "$CUBRID/bin/csql" -S -u dba collrealloc_db -c "select count(*) from _db_collation"

cubrid deletedb collrealloc_db
```

### Expected Result

확장이 실패하면 5402행의 검사가 실패를 잡아 `ER_OUT_OF_VIRTUAL_MEMORY`로 `exit`에 간다. 재시작은 메모리 부족 오류로 끝나고, 기존 버퍼는 해제된다.

### Actual Result

`30043f4` debug 빌드에서 관찰한 결과다(gdb 출력 발췌). 스택의 `catalog_class.c:5426`은 설치 빌드 기준이며 `e64a04a79a`의 5410행(`memset`)에 해당한다.

```text
[row-check] coll_cnt=0 max_coll_cnt=256
[row-check] coll_cnt=1 max_coll_cnt=2
[row-check] coll_cnt=2 max_coll_cnt=2
[before-realloc] *db_collations=0x555555642f18 coll_cnt=2
[after-check] *db_collations=(nil) coll_cnt=2 old=0x555555642f18

Program received signal SIGSEGV, Segmentation fault.
#0  __memset_evex_unaligned_erms () from /lib64/libc.so.6
#1  catcls_get_db_collation (...) at src/storage/catalog_class.c:5426
#2  boot_restart_server (..., db_name="collrealloc_db", ...) at src/transaction/boot_sr.c:2632
curr_coll = 0x98
```

- `*db_collations`가 NULL인데도 5402행(설치 빌드 5418행) 검사를 통과해 5409행으로 진행했다.
- `curr_coll`은 `0x98`(= 2 × `sizeof (LANG_COLL_COMPAT)` 76)이고, `memset`에서 SIGSEGV가 발생했다.
- 기존 버퍼 `0x555555642f18`은 앞서 읽은 콜레이션 데이터를 그대로 가지고 있었지만, 이를 가리키는 포인터는 남지 않았다.
- 같은 DB에 fault injection 없이 `csql -S`로 접속하면 정상 동작했고, `_db_collation`은 10행이었다.

### Additional Information

- ANALYSIS 확인 사항: `_db_collation` 행이 256개를 넘을 수 있는 경로(카탈로그 손상, 업그레이드, 향후 `LANG_MAX_COLLATIONS` 변경)가 있는지 확인하지 않았다. 없다면 확장 분기 자체가 불필요한지도 함께 판단할 수 있다.
- 같은 함수 5431-5432행의 `coll_name` 복사는 이름 길이가 `sizeof (curr_coll->coll_name)` 이상이면 배열 바로 뒤에 `'\0'`을 쓴다. 이 이슈의 범위는 아니며, 실행으로 확인하지 않았다.
