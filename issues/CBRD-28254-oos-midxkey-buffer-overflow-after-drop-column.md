# [OOS] DROP COLUMN 전에 저장된 행의 복합 인덱스 키를 만들 때 OOS 값 크기를 잘못 계산해 서버 버퍼를 넘어 쓴다

**한 줄 요약**: PR #7990(`feature/oos-merge` → develop)에 달린 Greptile P1 리뷰 [r4624406280](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4624406280)이 지적한 결함을 재현으로 확인했다. 복합 인덱스에 OOS 값이 있는 테이블에서 다른 가변 길이 컬럼을 DROP한 뒤 기존 행을 DELETE·UPDATE하면, 키 버퍼를 작게 잡고 큰 OOS 값을 그 버퍼 밖까지 써서 서버가 비정상 종료하거나 스택이 조용히 손상된다. 이 이슈는 키 크기 계산이 행이 저장될 때의 스키마를 쓰도록 바로잡는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: 스키마가 바뀌기 전에 저장된 행에서도 복합 인덱스 키를 버퍼 안에 정확히 만들어, DELETE·UPDATE·`checkdb`가 develop과 같이 정상 동작하게 한다.

**이슈 수행 이유**: OOS 엔진은 복합 인덱스 키 버퍼의 크기를 정할 때 OOS 값의 실제 길이를 더한다. 이때 현재 스키마의 컬럼 위치로 행을 읽는다. 하지만 키 값은 행이 저장될 때의 스키마에서 같은 컬럼을 찾아 읽는다. 앞쪽 가변 컬럼을 DROP하면 두 위치가 어긋나서 크기는 작게 계산되고 실제 키는 큰 OOS 값을 담는다. debug 빌드에서 SIGSEGV, 921바이트 스택 초과 쓰기, debug allocator assert, `checkdb` 오탐·비정상 종료를 재현했다. PR #7990이 develop에 들어가면 develop에도 이 결함이 생기므로 그 전에 고쳐야 한다.

**영향**: 자기 테이블에 ALTER 권한이 있는 일반 사용자가 서버(`cub_server`)를 비정상 종료시킬 수 있다. 재현에서 덮어쓴 스택의 리턴 주소가 사용자가 넣은 문자열이었으므로, 단순한 비정상 종료가 아니라 보안 측면의 메모리 손상으로 다뤄야 한다. UPDATE 경로는 오류 없이 스택을 손상시키므로 이후 동작을 예측할 수 없다. `checkdb`는 이런 DB에서 없는 인덱스 불일치(-544)를 보고하거나 비정상 종료한다. 조건은 흔한 스키마 변경 하나(큰 가변 컬럼을 포함한 복합 인덱스 + 그보다 뒤에 선언한 가변 컬럼의 DROP)뿐이다. release 빌드와 CS 모드에서는 실행하지 않았지만 같은 서버 코드(`locator_*`, `heap_*`)를 지난다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: 스키마 버전과 복합 인덱스 키 버퍼

CUBRID는 `ALTER TABLE ... DROP COLUMN` 뒤에도 기존 행을 바로 다시 쓰지 않는다. 각 행은 자신이 저장될 때의 스키마 버전(representation)을 기억하고, 읽을 때 그 버전의 컬럼 배치로 해석한다. 가변 길이 컬럼의 위치는 행 앞쪽의 가변 오프셋 표에서 정해지므로, 앞쪽 가변 컬럼이 빠지면 뒤 컬럼의 위치가 바뀐다.

복합 인덱스(multi-column index)의 키(midxkey)는 호출자가 준 4KB 스택 버퍼(`DBVAL_BUFSIZE`)에 만들고, 그보다 크면 heap 메모리를 할당한다. develop은 행 길이(`recdes->length`)로 크기를 정한다. OOS에서는 큰 값이 행 밖에 있고 행에는 24바이트 stub만 있으므로, OOS 엔진은 키에 들어갈 OOS 값의 실제 길이를 따로 더한다.

### 원인 (`src/storage/heap_file.c`, `e262e79fab` 기준)

- `heap_attrvalue_get_key ()`(16345)는 키 컬럼을 현재 스키마의 인덱스 정의(`index->atts`, 16384)에서 가져온다. 이 컬럼의 `location`은 현재 스키마의 가변 오프셋 표 위치다.
- 크기 계산(16420-16425)은 `heap_midxkey_get_oos_extra_size (recdes, index->atts[i], ...)`를 부른다. 이 함수(12553)는 `att->location`으로 **행의** 가변 오프셋 표를 바로 읽는다. 행이 이전 스키마로 저장되었으면 다른 필드를 읽는다. 그 필드가 OOS가 아니면 0을, 다른 OOS 컬럼이면 그 컬럼의 길이를 더한다.
- 실제 키 쓰기(`heap_midxkey_key_get ()`, 15821)는 `or_init (&buf, midxkey->buf, -1)`로 길이 제한 없이 쓴다. 각 값은 `heap_midxkey_get_value ()`(12453)가 행의 스키마 버전에서 컬럼 ID로 다시 찾아(12471-12482) 읽는다. 그래서 큰 OOS 값 전체가 작게 잡힌 버퍼에 써진다.
- 인덱스를 만들 때 쓰는 `heap_attrinfo_generate_key ()`(16232-16241)는 행의 스키마 버전으로 컬럼을 찾은 뒤 계산하므로 영향이 없다.

이 크기 계산은 OOS 브랜치의 PR #6902(CBRD-26565, `7edcb2be5b`)가 처음 넣었고, 그때는 행의 스키마 버전에서 컬럼을 찾았다. 같은 PR의 리뷰 반영 커밋 `901180ee47`("remove attr_info from argument")이 그 매핑을 지우고 "호출자가 행의 스키마에 맞는 컬럼을 준다"는 전제로 바꿨다. `heap_attrinfo_generate_key ()`는 그 전제를 지키지만 `heap_attrvalue_get_key ()`는 지키지 않는다. 이 코드는 `2c792b423c`(#7803, CBRD-26835)로 `feature/oos-merge`에 들어왔다.

### Test Build

- OOS: `feature/oos-merge` `e262e79fab`과 같은 `heap_file.c`·`locator_sr.c`·`btree.c`를 가진 `3f58b7305a`의 debug 빌드(`debug_gcc`)
- develop: `2e66081fd2` debug 빌드
- 4KB가 아니라 기본 16KB 페이지 DB, SA 모드(`csql -S`)

### Repro

트리거 조건은 DROP하는 가변 컬럼이 인덱스의 OOS 컬럼보다 **뒤에** 선언된 것이다. 이 빌드에서 가변 오프셋 표는 선언의 역순이므로, 뒤에 선언한 `v`가 표에서 `c`보다 앞에 놓인다. 반대 순서(`v`를 `c` 앞에 선언)에서는 `c`의 위치가 바뀌지 않아 재현되지 않는다.

LZ4 압축으로 값이 작아지지 않도록 무작위 문자열을 쓴다.

```bash
python3 - > repro.sql <<'EOF'
import random, string
random.seed(1)
c = ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(5000))
print("create table ta (id int, c varchar(8000), v varchar(100));")
print("create index ia on ta (c, id);")
print(f"insert into ta values (1, '{c}', 'x');")
print("commit;")
print("alter table ta drop column v;")
print("delete from ta where id = 1;")
print("commit;")
EOF
cubrid createdb --db-volume-size=64M --log-volume-size=64M p1db en_US.utf8
csql -S -u dba p1db -i repro.sql
cubrid checkdb -S p1db
```

변형: 마지막 DELETE를 `update ta set id = 2 where id = 1;`로 바꾸면 UPDATE 경로, `create unique index`로 바꾸면 unique 인덱스, `b varchar(8000)` 컬럼에 5000바이트 값을 하나 더 넣고 `c`를 15000바이트로 하면 heap 버퍼 경로를 재현한다.

### Expected Result

develop과 같이 DELETE·UPDATE가 성공하고 `checkdb`가 오류 없이 끝난다(develop `2e66081fd2`에서 같은 SQL이 이렇게 동작한다).

### Actual Result (OOS debug 빌드)

| 시나리오 | 크기 계산 → 실제 키 | 결과 |
|---|---|---|
| 복합 인덱스 `(c, id)`, DELETE | 52 → 5017바이트, 4KB 스택 버퍼 | `heap_midxkey_get_value ()`에서 SIGSEGV. backtrace의 리턴 주소(`0x374b53534f4e4d75` = "uMNOSSK7")가 넣은 문자열이다. 이어서 `checkdb`가 -544(`ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE1`)를 보고한다. |
| 같은 조건, `UPDATE ... SET id` | 52 → 5017바이트 | 스택 버퍼 밖으로 921바이트를 쓰지만 오류 없이 성공한다. |
| unique 인덱스, DELETE | 52 → 5017바이트 | SIGSEGV. 이어서 `checkdb`도 비정상 종료한다. |
| OOS 컬럼 2개(`c` 15000B, `b` 5000B), DELETE | `b`의 길이로 약 5KB heap 버퍼 → 15017바이트 | debug allocator assert(`memory_alloc.c:843`), SIGABRT. `checkdb`도 같은 assert로 종료한다. |
| DROP 뒤 DML 없이 `checkdb`만 | — | 없는 불일치 -544를 보고한다(rc=1). |
| 단일 컬럼 인덱스, DROP하지 않은 대조군 | — | 정상 |

크기 계산과 실제 쓴 크기는 gdb breakpoint로 `heap_attrvalue_get_key ()` 안에서 측정했다.

### Additional Information

- develop에는 이 결함이 없다. develop의 `heap_attrvalue_get_key ()`는 행 길이만 쓰므로 위치가 어긋날 계산이 없고, DROP한 컬럼은 이전 행에 남아 있어 행 길이는 과대 추정만 한다. 위 DELETE·UPDATE 시나리오가 develop debug 빌드에서 정상 동작하고 `checkdb`도 깨끗했다.
- 별도의 develop 결함: `ALTER TABLE ... ADD COLUMN c varchar(6000) DEFAULT '<5000자>'` 뒤 `CREATE INDEX (c, id)`도 키 버퍼를 넘어 써서 `btree_sort_get_next ()`(`btree_load.c:6263`)에서 SIGSEGV가 난다. 이전 행에 없는 컬럼의 기본값이 행 길이 계산에 빠지기 때문이다. develop `2e66081fd2`와 OOS에서 똑같이 재현되므로 이 이슈와 원인이 다르고, 별도 이슈로 다룬다.
- ANALYSIS 확인 사항: (1) 키 크기를 계산할 때 행의 스키마 버전으로 컬럼을 찾는 것으로 충분한지, 아니면 키를 쓸 때 버퍼 한계를 검사하고 부족하면 heap에서 다시 만드는 방식이 필요한지. 후자는 위 develop 결함도 함께 막는다. (2) `heap_midxkey_key_get ()` 뒤에 "쓴 크기 ≤ 버퍼 크기" debug assert를 넣어 앞으로의 과소 추정을 바로 드러낼지. (3) release 빌드·CS 모드에서의 증상.
- 재현 확인용 수정 후보는 `heap_file.c` 한 파일(+49/−12)로, 크기 계산이 `heap_midxkey_get_value ()`와 같은 방식으로 행의 스키마 버전에서 컬럼을 찾는다. 이 후보로 위 OOS 시나리오가 모두 정상 동작하고 `checkdb`도 깨끗했다. 최종 방안은 ANALYSIS에서 정한다.
- 회귀 테스트 후보: 위 시나리오(복합·unique, DELETE·UPDATE, OOS 컬럼 2개)를 실행하고 `checkdb`가 깨끗한지 확인하는 OOS SQL 테스트.
- 관련: CBRD-26565(이 크기 계산을 처음 넣은 이슈), CBRD-27874(같은 함수 `heap_midxkey_get_oos_extra_size ()`의 다른 결함. 잘린 레코드에서 가변 오프셋 표를 범위 밖으로 읽는 문제로, 정상 레코드에서 위치가 어긋나는 이 이슈와 원인이 다르다), CBRD-26978(OOS TODO).
