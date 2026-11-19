# [Index] ADD COLUMN의 큰 DEFAULT 값을 담는 복합 인덱스 키가 4KB 스택 버퍼를 넘어 써서 서버가 비정상 종료한다

**한 줄 요약**: PR #7990(OOS)의 Greptile 리뷰 [r4624406280](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4624406280)(CBRD-28254)를 검증하다가 develop에도 있는 별도 결함을 찾았다. 기존 행이 있는 테이블에 `ALTER TABLE ... ADD COLUMN ... DEFAULT <긴 문자열>`을 하고 그 컬럼을 포함한 복합 인덱스를 만들면, 키 버퍼 크기를 행 길이로만 정해서 기본값 길이를 빠뜨리고 키를 4KB 스택 버퍼 밖까지 쓴다. 이 이슈는 기존 행에 없는 컬럼의 기본값까지 키 버퍼 크기에 반영하도록 바로잡는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: `ADD COLUMN ... DEFAULT`로 추가한 컬럼이 들어간 복합 인덱스를 만들거나 쓸 때, 그 컬럼이 아직 저장되지 않은 기존 행에서도 키를 버퍼 안에 만들어 CREATE INDEX, UPDATE, DELETE, `checkdb`가 정상 동작하게 한다.

**이슈 수행 이유**: CUBRID는 `ADD COLUMN`에 상수 DEFAULT가 있어도 기존 행을 다시 쓰지 않고, 그 행을 읽을 때 스키마에 저장된 기본값을 돌려준다. 복합 인덱스 키 버퍼는 행 길이(`recdes->length`)로 크기를 정하고, 4096바이트 이하이면 호출자의 4KB 스택 버퍼를 쓴다. 기존 행에는 새 컬럼 값이 없으므로 행 길이에 기본값 길이가 빠진다. 그래서 기본값이 길면 작은 버퍼가 선택되고, 키는 길이 제한 없이 기본값 전체를 쓴다. develop `2e66081fd2` debug 빌드에서 CREATE INDEX 중 SIGSEGV(리턴 주소가 기본값 문자열로 덮임)를 재현했다. 초과 크기가 작으면 CREATE INDEX가 오류 없이 끝나고, 이후 `checkdb` 불일치 보고와 UPDATE 중 B-tree assert가 난다.

**영향**: 테이블을 ALTER하고 인덱스를 만들 권한이 있는 사용자가 흔한 스키마 변경 두 개(큰 기본값이 있는 ADD COLUMN, 그 컬럼을 포함한 복합 인덱스)로 서버를 비정상 종료시킬 수 있다. 재현에서 덮어쓴 리턴 주소가 사용자가 준 기본값 문자열이었으므로, 단순 비정상 종료가 아니라 보안 측면의 메모리 손상으로 다뤄야 한다. 초과 크기가 작으면 오류 없이 지나가서 스택이 조용히 손상되고, 이후 그 테이블에서 `checkdb`가 인덱스 불일치를 보고하며, 기존 행의 UPDATE가 B-tree에서 지울 키를 찾지 못한다. 이 B-tree 코드의 주석은 이 상태를 recovery 중 재실행되면 복구할 수 없다고 설명한다. 조건은 기본값 + 다른 키 컬럼이 4KB를 넘는 경우로 좁지만, 실제 발생 빈도는 알 수 없다. release 빌드와 CS 모드에서는 실행하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: 기존 행의 새 컬럼 값과 복합 인덱스 키 버퍼

`ALTER TABLE ... ADD COLUMN c ... DEFAULT <상수>` 뒤에도 기존 행은 다시 쓰지 않는다. 각 행은 저장될 때의 스키마 버전(representation)을 기억한다. 행을 읽을 때 그 버전에 없는 컬럼은 스키마에 저장된 기본값으로 채운다. 기본값이 식(expression)이면 ALTER가 기존 행을 UPDATE하므로 이 이슈와 관계없다.

복합 인덱스(multi-column index)의 키(midxkey)는 호출자가 준 `DBVAL_BUFSIZE`(4096바이트) 스택 버퍼에 만들고, 예상 크기가 그보다 크면 heap 메모리를 할당한다. 예상 크기는 행 길이(`recdes->length`)다. 행에 있는 값으로만 키를 만든다면 이 예상은 대체로 충분하다. 하지만 행에 없는 컬럼의 기본값은 행 길이에 들어 있지 않다.

### 원인 (develop `2e66081fd2` 기준)

- 키 값 읽기: `heap_midxkey_get_value ()`(`src/storage/heap_file.c:11970`)는 컬럼이 행의 스키마 버전에 없으면(11996) 스키마의 기본값 `att->default_value`를 키 값으로 쓴다(12000-12002).
- 인덱스 생성 경로: `heap_attrinfo_generate_key ()`(`heap_file.c:14943`)는 `midxkey_size = recdes->length`(14991)로 크기를 정하고, 4096바이트 이하이면 호출자 버퍼를 쓴다(15001). `heap_midxkey_key_generate ()`는 `or_init (&buf, midxkey->buf, -1)`(14843)로 길이 제한 없이 쓴다. 호출자인 `btree_sort_get_next ()`(`src/storage/btree_load.c:6054` 버퍼, 6211 호출)와 `online_index_builder ()`(7526 버퍼, 7614 호출)는 모두 `char midxkey_buf[DBVAL_BUFSIZE + MAX_ALIGNMENT]` 스택 버퍼를 넘긴다.
- DML·`checkdb` 경로: `heap_attrvalue_get_key ()`(`heap_file.c:15091`)도 `midxkey_size = recdes->length`(15153), 버퍼 선택(15163), `heap_midxkey_key_get ()`의 길이 제한 없는 쓰기(14639)로 같다. 호출자는 `src/transaction/locator_sr.c`의 4KB 스택 버퍼를 넘긴다. INSERT·DELETE 인덱스 갱신 `locator_add_or_remove_index_internal ()`(9169 버퍼, 9276 호출), UPDATE `locator_update_index ()`(9673-9674 버퍼, 9892·9895 호출), `checkdb`의 `locator_check_btree_entries ()`(10754 버퍼, 10856 호출) 등이다.

### Test Build

- develop `2e66081fd2`, debug 빌드(CMake preset `debug_gcc`), 기본 16KB 페이지, SA 모드(`csql -S`)
  - 이 호스트에서 develop `2e66081fd2`는 `src/broker/cas_cgw_odbc.c`에 `#include <ctype.h>`가 없어 컴파일되지 않았다. 빌드를 위해 이 include 한 줄만 로컬에 추가했다(broker 코드이고 엔진 경로와 무관).
- OOS: `feature/oos-merge`의 `3f58b7305a` debug 빌드(`heap_file.c`·`btree_load.c`가 `e262e79fab`과 같다)에서도 같은 결과가 나왔다.
- release 빌드와 CS 모드는 실행하지 않았다.

### Repro

LZ4 압축으로 기본값이 작아지지 않도록 무작위 문자열을 쓴다. `N`이 기본값 길이다.

```bash
cat > gen.py <<'EOF'
import random, string, sys
n = int(sys.argv[1])
random.seed(1)
d = ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(n))
print("create table tk (id int, v varchar(10));")
print("insert into tk values (1, 'small');")
print("insert into tk values (2, 'small');")
print("commit;")
print(f"alter table tk add column c varchar(6000) default '{d}';")
print("create index ik on tk (c, id);")
print("commit;")
EOF
python3 gen.py 5000 > repro_5000.sql
python3 gen.py 4200 > repro_4200.sql

cubrid createdb --db-volume-size=64M --log-volume-size=64M p1db en_US.utf8
csql -S -u dba p1db -i repro_5000.sql      # (1) CREATE INDEX 중 SIGSEGV
cubrid checkdb -S p1db

cubrid deletedb p1db
cubrid createdb --db-volume-size=64M --log-volume-size=64M p1db en_US.utf8
csql -S -u dba p1db -i repro_4200.sql      # (2) CREATE INDEX 성공
cubrid checkdb -S p1db                     # -544 보고
csql -S -u dba p1db -c "update tk set id = 3 where id = 2"   # B-tree assert
```

키 크기는 gdb breakpoint로 측정했다(`heap_attrinfo_generate_key ()`와 `heap_attrvalue_get_key ()`의 `db_make_midxkey ()` 호출 줄에서 `midxkey_size`와 `midxkey.size`를 비교).

### Expected Result

CREATE INDEX가 성공하고, 기존 행의 UPDATE·DELETE와 `checkdb`가 오류 없이 끝난다. 기본값이 길어도 키는 heap 버퍼에 만들어진다.

### Actual Result

| 경우 | 예상 크기 → 실제 키 | 결과 |
|---|---|---|
| (1) 기본값 5000자, `create index ik on tk (c, id)` | 28 → 5017바이트, 4KB 스택 버퍼를 921바이트 넘음 | `btree_sort_get_next ()`(`btree_load.c:6263`)에서 SIGSEGV. backtrace의 리턴 주소(`0x494566424c595765` 등)가 기본값 문자열이다. 인덱스는 생성되지 않는다. |
| (1)과 같은 SQL에 `with online` | 같음 | 같은 위치에서 SIGSEGV. SA 모드에서는 `online_index_builder ()`가 아니라 `btree_sort_get_next ()`를 지났다. `online_index_builder ()`도 같은 4KB 버퍼와 같은 함수를 쓰지만 CS 모드에서 따로 실행하지 않았다. |
| (2) 기본값 4200자, CREATE INDEX | 28 → 4217바이트, 121바이트 넘음(행마다) | 오류 없이 성공한다. 인덱스 스캔(`using index ik(+)`)은 두 행을 모두 찾는다. |
| (2) 뒤 `checkdb` | DML 없음 | 두 행 모두 `-544`(`ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE1`, `locator_sr.c:10905`)를 보고한다(rc=1). |
| (2) 뒤 기존 행 `update tk set id = 3 where id = 2` | `heap_attrvalue_get_key ()`에서 28 → 4217바이트, 121바이트 넘음 | `btree_key_delete_remove_object ()`(`btree.c:37047`)의 assert("object to remove was not found in its key")로 SIGABRT. 이어서 `checkdb`가 -544를 보고한다. |
| 대조: 같은 ADD COLUMN DEFAULT, 인덱스 없음 | — | 정상. 조회는 기본값 5000자를 돌려준다. |
| 대조: `default 'x'`로 ADD COLUMN, 인덱스 생성 뒤 `alter column c set default <5000자>` | — | 정상. 기존 행은 ADD COLUMN 당시의 기본값을 유지한다. |

### Additional Information

- **OOS 이슈와의 관계**: PR #7990의 Greptile P1 r4624406280에 대응하는 CBRD-28254("[OOS] DROP COLUMN 전에 저장된 행의 복합 인덱스 키를 만들 때 OOS 값 크기를 잘못 계산해 서버 버퍼를 넘어 쓴다")와 증상과 버퍼가 같다. 원인은 다르다. OOS 결함은 OOS 브랜치에서 추가한 크기 보정이 현재 스키마의 컬럼 위치로 이전 행을 읽어서 생기고, develop에는 없다. 이 이슈는 develop부터 있는 "키 크기 ≤ 행 길이" 가정이 행에 없는 기본값을 빠뜨려서 생기고, develop과 OOS 모두에 있다. OOS 이슈의 수정 후보(이전 행의 스키마 버전에서 컬럼을 찾음)는 이 결함을 고치지 않는다. 그 후보는 행에 없는 컬럼에 0을 더한다.
- **(2)의 불일치 원인은 미확인**: 인덱스 스캔은 두 행을 찾지만 `checkdb`와 UPDATE는 키를 찾지 못한다. 인덱스에 들어간 키가 틀렸는지, 아니면 `checkdb`·UPDATE가 자기 스택 버퍼를 넘어 쓰는 과정에서 비교할 키가 손상됐는지 ANALYSIS에서 확인한다.
- **ANALYSIS 확인 사항**:
  1. 크기 예상에 행에 없는 컬럼의 기본값 길이를 더하는 것으로 충분한지, 아니면 키를 쓸 때 버퍼 한계를 검사하고 부족하면 heap에서 다시 만들어야 하는지. 후자는 OOS 결함처럼 다른 원인의 과소 추정도 함께 막는다.
  2. `heap_midxkey_key_get ()`·`heap_midxkey_key_generate ()` 뒤에 "쓴 크기 ≤ 버퍼 크기" debug assert를 넣어 앞으로의 과소 추정을 바로 드러낼지.
  3. 함수 인덱스, 파티션 테이블, CS 모드의 online index 생성, release 빌드에서의 증상.
  4. 이미 (2)처럼 인덱스를 만든 DB의 진단·복구 방법(인덱스 재생성으로 충분한지).
- **회귀 테스트 후보**: 위 SQL에서 기본값 4200자와 5000자로 CREATE INDEX, `checkdb`, 기존 행의 UPDATE·DELETE를 실행하고 모두 오류 없이 끝나는지 확인하는 SQL 테스트.
- **관련**: CBRD-28254(위 OOS 결함), CBRD-26565(OOS 브랜치에서 같은 버퍼의 OOS 값 과소 추정을 처음 보정한 이슈), CBRD-27874(같은 OOS 크기 보정 함수가 잘린 레코드에서 가변 오프셋 표를 범위 밖으로 읽는 문제. OOS 전용이고 원인이 다르다). 중복 이슈는 찾지 못했다.
