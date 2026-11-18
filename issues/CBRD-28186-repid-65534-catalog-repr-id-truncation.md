# [Catalog] 한 테이블의 표현 ID(repid)가 65,534에 이르면 시스템 카탈로그 갱신이 멈추고, debug 서버는 해당 ALTER마다 abort한다

**한 줄 요약**: 시스템 카탈로그가 표현 ID를 16비트로 저장하면서 repid 65,534가 -2로 잘려 카탈로그 내부 캐시 키와 충돌하는 결함이다. 이 때문에 테이블의 65,534번째 스키마 표현 이후 release 서버는 통계 갱신과 `SHOW INDEX`에 실패하고, debug 서버는 해당 ALTER마다 abort한다. 이 이슈는 그 원인과 필요한 결과를 다룬다.

## Issue Triage

**이슈 수행 목적**: 한 테이블에서 컬럼 추가·삭제가 누적되어 repid가 65,534 이상이 되어도 시스템 카탈로그가 최신 표현을 계속 기록하게 한다. 또는 그 한계에 이르기 전에 명확한 오류로 막아, 통계·인덱스 정보가 조용히 깨지거나 서버가 abort하지 않게 한다.

**이슈 수행 이유**: 클래스의 표현 ID(repid, 32비트 `REPR_ID`)는 `ADD COLUMN`, `DROP COLUMN` 같은 표현 변경마다 1씩 늘고, `compactdb -d`로도 줄지 않는다. 시스템 카탈로그의 표현 디렉터리 항목은 이 값을 `INT16`으로 저장하고 조회한다. 그래서 repid 65,534는 -2가 된다. -2는 클래스별 "표현 디렉터리 OID" 캐시 항목의 해시 키 `CATALOG_DIR_REPR_KEY`와 같으므로, 이 repid의 표현을 찾으면 디렉터리 레코드가 반환된다. develop `5b38db9e0e`의 debug·release 빌드에서 실제 ALTER 반복으로 재현했다.

**영향**: repid 65,534에 이른 테이블에서 release 서버는 `ALTER TABLE`을 성공으로 커밋하지만, 그 뒤 카탈로그는 새 표현을 더 이상 반영하지 않는다. `UPDATE STATISTICS`는 메시지 없는 오류(`ERROR: (null)`)로 실패하므로 옵티마이저는 이 테이블의 통계를 갱신할 수 없다. `SHOW INDEX`는 실패하고, 이 테이블을 쓰는 쿼리는 실행 계획을 새로 만들 때마다 약 1.25초가 더 걸린다. `checkdb`는 이 상태를 감지하지 못한다. debug 서버(개발·QA)는 이 경계를 넘는 ALTER마다 abort한다. 한 테이블에 표현 변경이 6만 회 이상 쌓여야 하므로 발생 빈도는 낮을 것으로 보이지만, 스키마를 자동으로 자주 바꾸는 응용이 이 수에 도달하는지는 확인하지 않았다. 행 데이터 자체는 정확히 읽혔다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경

테이블(클래스)의 레코드 형식이 바뀔 때마다 서버는 새 표현(representation)을 만들고 repid를 1 늘린다(`src/object/class_object.c:7504`, 상한 검사 없음). 시스템 카탈로그는 클래스마다 표현 디렉터리 레코드 하나를 두고, 그 안에 "class info 항목(repr_id = -1, `NULL_REPRID`)"과 "마지막 표현 항목"을 `catalog_repr_item`으로 저장한다. 이 항목의 `repr_id` 필드가 `INT16`이다(`src/storage/system_catalog.c:266`, `:549`, `:558`).

- repid 32,768~65,533은 음수로 저장되지만 저장과 조회가 같은 방식으로 잘리므로 실제로 문제가 없었다(디렉터리 덤프에 `Repr_id: -32768`, `-3` 등으로 보이고 모든 확인이 정상).
- repid 65,534는 -2가 된다. 카탈로그 해시맵(`catalog_Hashmap`, 키 `(class OID, repr_id)`)은 디렉터리 OID 캐시에 `repr_id = CATALOG_DIR_REPR_KEY (-2)`를 쓴다(`src/storage/system_catalog.h:42`, `src/storage/system_catalog.c:5757`). `catalog_get_representation_item`(`:2314-2316`)은 같은 해시맵을 먼저 찾으므로, repid 65,534의 표현을 찾으면 이 캐시 항목이 반환되어 디렉터리 레코드를 디스크 표현(`DISK_REPR`)으로 읽게 된다.
- repid 65,535는 -1(`NULL_REPRID`)이 되어 class info 항목과 같은 값이 된다. 그러나 아래와 같이 65,534에서 카탈로그 갱신이 먼저 멈추므로, 이 충돌은 재현 중 도달하지 않았다.

### Test Build

- develop `5b38db9e0e` (CUBRID 11.5.0.2962)
- debug: CMake preset `debug_gcc`. release: CMake preset `release_gcc`(RelWithDebInfo, `-O2 -DNDEBUG`)
- Linux x86_64, 기본 `cubrid.conf`, CS 모드(csql `-C`)
- 참고: 이 커밋은 `src/broker/cas_cgw_odbc.c`의 `toupper`/`tolower` 선언 누락으로 빌드가 실패해, `CMAKE_CXX_FLAGS`에 `-include ctype.h`를 더해 빌드했다. 재현 대상 코드와는 무관하다.

### Repro

`CREATE TABLE` 직후 repid는 1이고, 표현을 바꾸는 ALTER 1회마다 1씩 는다. 아래 절차는 2,000회마다 `compactdb -d`로 이전 표현을 정리하며 repid를 65,533까지 올린다(테스트 장비에서 debug 약 8분, release 약 3분). `compactdb` 없이 한 번에 실행하는 경우는 시험하지 않았다. csql은 서버가 중단되어도 종료 코드 0을 반환할 수 있으므로 출력의 `ERROR`도 확인한다.

```bash
cubrid createdb repiddb en_US.utf8
cubrid server start repiddb
csql -u dba -C -c "create table t(a int);" repiddb                  # repid 1

for i in $(seq 1 1000); do
  echo "alter table t add column b int;"
  echo "alter table t drop column b;"
done > alters-2000.sql                                               # repid +2000
for c in $(seq 1 32); do                                             # repid 64001
  csql -u dba -C -i alters-2000.sql repiddb > out.$c.log 2>&1
  grep -q ERROR out.$c.log && { echo "failed at chunk $c"; break; }
  cubrid compactdb -C -d repiddb > /dev/null
done
head -n 1532 alters-2000.sql > alters-1532.sql                       # 766쌍 = repid +1532
csql -u dba -C -i alters-1532.sql repiddb                            # repid 65533

# 현재 repid 확인: 새로 넣은 행의 표현 ID
csql -u dba -C repiddb <<'EOF'
insert into t(a) values (-424242);
select /*+ SELECT_RECORD_INFO */ t_reprid from t where a = -424242;   -- 65533
delete from t where a = -424242;
EOF

# repid 65534를 만드는 ALTER
csql -u dba -C -c "alter table t add column b int;" repiddb
csql -u dba -C -c "update statistics on t;" repiddb
csql -u dba -C -c "show index from t;" repiddb
cubrid checkdb -C repiddb
```

`select_record_info`는 vacuum되지 않은 삭제 행도 보여 주므로 확인용 marker 값은 실행할 때마다 바꾼다.

### Expected Result

- repid 65,534 이후의 ALTER도 카탈로그에 새 표현을 기록하고, `UPDATE STATISTICS`, `SHOW INDEX`, 실행 계획 생성이 정상 동작한다.
- 지원 한계가 있다면 ALTER가 그 한계를 알리는 오류로 실패하고, 서버 abort나 카탈로그 불일치가 남지 않는다.

### Actual Result

| repid | debug | release |
|---|---|---|
| 32,768 | 정상 (디렉터리 `Repr_id: -32768`) | 정상 |
| 65,533 | 정상 | 정상 |
| 65,534를 만드는 ALTER | 서버 abort: `system_catalog.c:4484: int catalog_update(THREAD_ENTRY*, RECDES*, OID*): Assertion 'er_errid () != NO_ERROR' failed.` 클라이언트는 `ERROR: Server no longer responding.` 재시작 후 롤백되어 repid 65,533. 같은 ALTER는 다시 abort | `Execute OK`(4.48초)로 커밋. 이후 `UPDATE STATISTICS` → `ERROR: (null)`(서버 로그 `error code : -1`), `checkdb -C`/`-S` 통과 |
| 65,535~65,538 (release) | - | ALTER, `CREATE INDEX`, default 값이 있는 `ADD COLUMN` 모두 성공. 카탈로그 디렉터리는 계속 `Repr_id: -2`(65,534)에 머문다. `UPDATE STATISTICS` 실패, `SHOW INDEX FROM t` → `Execute: Query execution failure #...`(-495), `/*+ recompile */` 쿼리 약 1.25초(같은 서버의 다른 테이블은 0.6ms) |

debug abort 시점의 스택(gdb attach로 수집):

```
#5 catalog_update (...) at src/storage/system_catalog.c:4484
     current_repr_id = -2, new_repr_id = 65534, old_repr_p = 0x0
#6 locator_update_force (...) at src/transaction/locator_sr.c:6048
#7 xlocator_force (...) at src/transaction/locator_sr.c:789
#8 slocator_force (...) at src/communication/network_interface_sr.cpp:1493
#9 net_server_request (...) at src/communication/network_sr.c:979
```

### Additional Information

**확인한 동작 순서**(gdb breakpoint 추적): ALTER 한 번이 클래스 레코드를 두 번 flush하여 `catalog_update`가 두 번 불린다.

1. 첫 호출(`current_repr_id = -3`)은 repid 65,533 표현을 지우고 65,534 표현을 `-2`로 추가한다.
2. 이후 `catalog_get_representation(-2)`가 `page=(0|577) slot=47`을 돌려준다. 이것은 이 테이블의 표현 디렉터리 OID `{0, 577, 47}`과 같다.
3. 두 번째 호출(`current_repr_id = -2`)에서 `catalog_get_representation`이 오류 코드 없이 NULL을 반환한다. `catalog_update`(`:4475-4486`)는 `er_errid () != ER_SP_UNKNOWN_SLOTID` 분기로 들어간다. debug는 assert에 걸리고, release는 `er_errid ()`, 곧 `NO_ERROR`를 반환한다.

release에서는 이후 모든 `catalog_update`가 같은 분기에서 `NO_ERROR`로 끝나 카탈로그 표현이 갱신되지 않는다. `catalog_get_last_representation_id`(`:4343`)를 거쳐 `catalog_get_representation`을 부르는 통계 갱신(`src/storage/statistics_sr.c:287`), 계획용 통계 조회(`statistics_sr.c:613`), `SHOW INDEX`(`qexec_execute_build_indexes`)가 실패한다. 계획 생성 지연은 perf에서 `xstats_get_statistics_from_server → catalog_get_representation`의 `memset`과 `catalog_free_representation`이 상위를 차지했다. 디렉터리 레코드를 디스크 표현으로 해석하면서 잘못된 크기의 배열을 할당하고 지우는 것으로 보이며, 이 해석은 추론이다.

**heap 데이터**: repid 65,534와 65,537로 저장된 행, 65,538에서 default 값과 함께 추가한 컬럼 모두 정확히 읽혔다. 행 해석은 클래스 레코드의 표현 정보를 쓰므로 이번 결함의 영향을 받지 않은 것으로 보인다.

**우회 방법**: 새 테이블로 옮기면 repid가 1부터 다시 시작한다. release에서 `create table t_new like t; insert into t_new select * from t; drop table t; rename table t_new as t;` 후 통계, `SHOW INDEX`, `checkdb`가 정상이었다. unload/load로 테이블을 다시 만드는 방법도 repid를 처음부터 시작하게 할 것으로 보이지만 이번 재현에서는 실행하지 않았다.

**ANALYSIS에서 확인할 점**

- repid 65,534 + k·65,536, 65,535 + k·65,536에서도 같은 동작이 반복되는지(INT16 잘림 결과가 같아 반복될 것으로 보이나 미검증)
- 이미 이 상태에 이른 데이터베이스를 수정 버전으로 열 때 카탈로그를 어떻게 복구하거나 진단할지. 현재 `checkdb`는 감지하지 못한다
- 같은 반복에서 `ADD COLUMN`이 32,767회 쌓여 속성 ID도 32,767에 이르렀다(카탈로그 덤프의 `Attrid = 32767`). 속성 ID에도 16비트 저장 경로가 있는지는 확인하지 않았다
- release의 `ERROR: (null)`처럼 오류 코드 없이 실패를 반환하는 카탈로그 경로를 함께 정리할지

**수정 방향 후보(제안, 미검토)**: 카탈로그 디렉터리 항목의 `repr_id`를 32비트로 넓히는 방법(16바이트 항목에 빈 바이트가 있음), 사용하지 않는 `ER_CT_REPRCNT_OVERFLOW`(`src/base/error_code.h:499`)를 되살려 `classobj_install_template`에서 상한을 검사하는 방법, 디렉터리 OID 캐시 키를 표현 ID와 겹치지 않는 별도 키 공간으로 옮기는 방법이 있다. 앞의 두 방법은 디스크 형식 호환성, 마지막 방법은 65,535(-1)와 class info 항목의 충돌이 남는지를 함께 따져야 한다.

**관련 이슈**: CBRD-21416(`catalog_put_representation_item` crash)은 같은 `catalog_update`의 표현 교체 경로에서 `catalog_drop` 오류를 무시하던 문제를 고친 이슈다. 이번 결함과 같은 함수의 오류 처리를 다루지만, 원인(SQL 회귀와 backupdb 동시 실행 중 crash)은 다르다. 중복 검색에서 같은 문제를 다룬 이슈는 찾지 못했다.
