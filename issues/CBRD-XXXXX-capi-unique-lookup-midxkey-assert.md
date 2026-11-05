# [C API] 유일키 조회가 인덱스의 key 형태와 다른 key를 보내 debug 서버가 btree_compare_key의 assert로 멈춘다

**한 줄 요약**: Sidecar 개발 중 C API 객체 조회 하네스에서 발견하고 develop `e64a04a79` debug 빌드에서 재현한 결함으로, `db_find_unique ()` 가 여러 열 유일 인덱스를 고르거나 `db_find_multi_unique* ()` 가 한 열 인덱스에 MIDXKEY를 보내면 서버가 `btree_compare_key ()` 의 assert로 멈춘다.

## Issue Triage

**이슈 수행 목적**: C API의 유일키 조회 함수가 찾는 B-tree의 key 형태(한 열 값 또는 MIDXKEY)에 맞는 key를 보내, 행을 찾거나 정상적인 오류를 돌려주게 한다.

**이슈 수행 이유**: 두 경우에 클라이언트가 B-tree의 key 도메인과 다른 형태의 key를 서버에 보낸다. (1) `db_find_unique (class, "id", INT)` 는 `id` 가 들어간 첫 UNIQUE 제약을 고르는데, 그것이 `(id, s)` 같은 여러 열 인덱스여도 그대로 INT key로 찾는다. (2) `db_find_multi_unique ()`, `db_find_multi_unique_committed ()`, `db_find_multi_unique_for_update ()` 는 속성 하나로 불러도 key를 항상 MIDXKEY로 만들어 한 열 인덱스에 보낸다. develop `e64a04a79` debug 빌드에서 네 경우 모두 두 번씩 서버가 멈췄다.

**영향**: `dbi.h` 를 직접 링크한 C 프로그램이 이 조건으로 조회하면 debug 서버가 멈추고, debug 서버의 abort 처리기가 같은 호스트의 모든 클라이언트에 SIGABRT를 보내므로 다른 세션도 함께 끊긴다. 엔진 안의 호출자는 카탈로그 클래스의 이름 속성(`unique_name` 등)으로 `db_find_unique ()` 를 부르거나 히스토그램 조회에서 두 열로 `db_find_multi_unique* ()` 를 부르므로, 이 조건에 닿지 않을 것으로 본다(호출 위치를 읽은 추론). 발견 경로는 C API로 사용자 테이블을 조회한 하네스였다. release 빌드는 실행하지 않았다. 코드상 release에서는 비교가 `ER_TP_CANT_COERCE` 와 `DB_UNK` 를 돌려주므로, 행이 있어도 오류나 "없음"이 나올 것으로 추정한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 경우 1: `db_find_unique ()` 가 여러 열 유일 인덱스를 고른다

`find_unique ()` (`src/object/object_accessor.c:3414`)는 속성의 제약 캐시 `att->constraints` 에서 UNIQUE, PRIMARY KEY, REVERSE UNIQUE, INDEX 순으로 첫 제약의 BTID를 고른다. 이 캐시는 여러 열 제약도 그 제약의 모든 속성에 매단다(`classobj_cache_constraint_entry ()`, `src/object/class_object.c:2390-2437`). 그래서 `id int primary key` 와 `unique (id, s)` 가 함께 있는 테이블에서 `db_find_unique (t, "id", 1)` 은 PK가 아니라 `(id, s)` 인덱스를 고른다. 이어지는 key 타입 검사 `find_unique_key_matches ()` (3464행, CBRD-27583)는 key를 인덱스의 key 도메인이 아니라 속성 도메인(INT)과 비교하므로 통과하고, INT key가 MIDXKEY B-tree로 간다(3470행). 서버의 `btree_compare_key ()` 는 MIDXKEY 도메인 분기에서 `key1` 이 MIDXKEY가 아니면 `ER_TP_CANT_COERCE` 를 설정하고 `assert (false)` 로 멈춘다(`src/storage/btree.c:23518-23524`).

코드로만 본 추론: `id` 가 여러 열 인덱스의 첫 열이 아니어도(`unique (s, id)`) 같은 선택이 일어난다. 실행으로 확인하지는 않았다.

### 경우 2: 한 속성 `db_find_multi_unique* ()` 가 MIDXKEY를 보낸다

`obj_find_multi_attr_internal ()` 은 속성 이름 목록과 정확히 맞는 인덱스를 찾은 뒤, 인덱스가 한 열이어도 key를 항상 `do_create_midxkey_from_values ()` 로 MIDXKEY로 만든다(`src/object/object_accessor.c:3824`). 한 열 인덱스의 key 도메인은 그 열의 타입이므로, 서버의 `btree_compare_key ()` 는 MIDXKEY가 아닌 도메인 분기에서 `assert (key1_type != DB_TYPE_MIDXKEY)` 로 멈춘다(`src/storage/btree.c:23550`). 잠금 조회(`btree_find_unique ()`, 3859행)와 committed·for update 조회(`btree_find_multi_uniques ()`, 3845행)가 모두 같다.

두 경우의 공통점은 클라이언트가 조회할 B-tree를 고른 뒤 그 B-tree의 key 형태(열 수)를 확인하지 않고 key를 만든다는 점이다. 서버는 key가 인덱스 도메인과 맞는다고 가정한다.

## Test Build

- develop `e64a04a79` (CUBRID 11.5.0.2802, 64bit debug build, Linux)
- `origin/develop` `21c6e635d` 은 실행하지 않았다. `e64a04a79` 이후 `object_accessor.c`, `class_object.c` 는 바뀌지 않았고, `btree.c` 의 변경은 이 경로와 다른 곳(SHOW INDEX CAPACITY, range scan 재시작)이다.

## Repro

1. DB를 만들고 테이블을 만든다.

```sh
cubrid createdb testdb en_US.utf8
cat > schema.sql <<'EOF'
create table t_comp (id int primary key, s varchar(100));
create unique index u_comp_id_s on t_comp (id, s);
insert into t_comp values (1, 'one');
create table t_pk (id int primary key, s varchar(100));
insert into t_pk values (1, 'one');
EOF
csql -S -u dba -i schema.sql testdb
cubrid server start testdb
```

2. 아래 C 프로그램을 빌드해 경우별로 실행한다.

```c
/* find_unique_repro <db> unique|pk|multi|committed|update */
#include <stdio.h>
#include <string.h>
#include "dbi.h"

int
main (int argc, char **argv)
{
  const char *mode = argv[2];
  const char *table = strcmp (mode, "unique") == 0 ? "t_comp" : "t_pk";
  DB_OBJECT *cls, *obj = NULL;
  DB_VALUE key, s;
  DB_VALUE *values[1] = { &key };
  char *names[1] = { (char *) "id" };

  if (argc != 3 || db_login ("dba", "") != NO_ERROR || db_restart (argv[0], 0, argv[1]) != NO_ERROR)
    return 1;
  cls = db_find_class (table);
  db_make_int (&key, 1);
  if (strcmp (mode, "unique") == 0 || strcmp (mode, "pk") == 0)
    obj = db_find_unique (cls, "id", &key);
  else if (strcmp (mode, "multi") == 0)
    obj = db_find_multi_unique (cls, 1, names, values, DB_FETCH_READ);
  else if (strcmp (mode, "committed") == 0)
    obj = db_find_multi_unique_committed (cls, 1, names, values);
  else if (strcmp (mode, "update") == 0)
    obj = db_find_multi_unique_for_update (cls, 1, names, values);
  if (obj == NULL || db_get (obj, "s", &s) != NO_ERROR)
    {
      fprintf (stderr, "%s: error %d: %s\n", mode, db_error_code (), db_error_string (1));
      return 1;
    }
  printf ("%s: found id 1, s = %s\n", mode, db_get_string (&s));
  db_shutdown ();
  return 0;
}
```

```sh
gcc -o find_unique_repro find_unique_repro.c -I$CUBRID/include -L$CUBRID/lib -lcubridcs
./find_unique_repro testdb pk         # 대조군: PK만 있는 테이블
./find_unique_repro testdb unique     # 경우 1
./find_unique_repro testdb multi      # 경우 2 (committed, update도 같다)
```

경우마다 서버가 멈추므로 다음 경우 전에 서버를 다시 시작한다(`auto_restart_server` 가 켜져 있으면 master가 다시 띄운다).

## Expected Result

다섯 경우 모두 `t_comp` 또는 `t_pk` 의 `id = 1` 행을 찾아 `s = one` 을 출력한다. 조회할 수 없는 조합이라면 서버를 멈추지 않고 오류를 돌려준다.

## Actual Result

두 번 실행해 두 번 모두 같은 결과를 얻었다.

| 경우 | 클라이언트 | 서버 |
|---|---|---|
| `pk` (대조군) | `found id 1, s = one` | 정상 |
| `unique` | SIGABRT 또는 -711 | `btree.c:23524` `Assertion 'false' failed` |
| `multi` | SIGABRT 또는 -111 | `btree.c:23550` `Assertion 'key1_type != DB_TYPE_MIDXKEY' failed` |
| `committed` | SIGABRT 또는 -111 | `btree.c:23550` 같은 assert |
| `update` | SIGABRT 또는 -111 | `btree.c:23550` 같은 assert |

클라이언트의 SIGABRT는 debug 서버의 abort 처리기(`src/executables/server.c` `abort_handler ()`)가 로컬 클라이언트에 보낸 것이다. 서버를 gdb 아래에서 실행하면 처리기가 돌지 않아 클라이언트는 -711 또는 -111을 받는다. 경우 1의 -711(객체 없음)은 `find_unique ()` 가 서버 실패도 "찾지 못함"으로 바꾸기 때문이다.

경우 1의 서버 오류 로그:

```text
ERROR *** file src/storage/btree.c, line 23522 ERROR CODE = -181, Tran = 1, CLIENT = find_unique_repro
Cannot coerce value of domain "integer" to domain "midxkey".
```

경우 1의 서버 스택(gdb):

```text
cub_server: src/storage/btree.c:23524: btree_compare_key(...): Assertion `false' failed.
#5  btree_compare_key at src/storage/btree.c:23524
#6  btree_compare_bound_key at src/storage/btree.c:23604
#7  btree_compare_search_key at src/storage/btree.c:23657
#8  btree_search_leaf_page at src/storage/btree.c:5775
#9  btree_get_root_with_key at src/storage/btree.c:27473
#10 btree_search_key_and_apply_functions at src/storage/btree.c:27298
#11 btree_find_unique_internal at src/storage/btree.c:28896
#12 xbtree_find_unique at src/storage/btree.c:28961
#13 sbtree_find_unique_internal at src/communication/network_interface_sr.cpp:5012
#14 sbtree_find_unique at src/communication/network_interface_sr.cpp:4991
```

경우 2(`committed`)의 서버 스택(gdb):

```text
cub_server: src/storage/btree.c:23550: btree_compare_key(...): Assertion `key1_type != DB_TYPE_MIDXKEY' failed.
#5  btree_compare_key at src/storage/btree.c:23550
#6  btree_compare_bound_key at src/storage/btree.c:23604
#7  btree_compare_search_key at src/storage/btree.c:23657
#8  btree_search_leaf_page at src/storage/btree.c:5775
#9  btree_get_root_with_key at src/storage/btree.c:27473
#10 btree_search_key_and_apply_functions at src/storage/btree.c:27298
#11 btree_find_unique_internal at src/storage/btree.c:28896
#12 xbtree_find_unique at src/storage/btree.c:28961
#13 xbtree_find_multi_uniques at src/storage/btree.c:6241
#14 sbtree_find_multi_uniques at src/communication/network_interface_sr.cpp:5085
```

`multi` 의 스택은 #13이 `sbtree_find_unique_internal` 인 점만 다르다.

## Additional Information

- 관련 이슈: CBRD-27583은 `db_find_unique ()` 의 key 타입이 속성 타입과 다를 때 -181을 돌려주도록 `find_unique_key_matches ()` 를 넣었다. 이 검사는 속성 도메인과 비교하므로 경우 1을 막지 못한다. 같은 이슈의 2026-10-27 댓글은 반대 방향의 경우(`db_find_primary_key ()` 가 여러 열 PK에 SEQUENCE key를 보내 찾지 못함)를 develop 동작으로 남겼다.
- ANALYSIS 확인 사항: release 빌드에서 각 경우가 오류, "없음", 잘못된 행 중 무엇을 돌려주는지. `db_find_unique ()` 가 여러 열 인덱스밖에 없는 속성(`unique (s, id)` 의 `id`)을 받을 때 어떻게 해야 하는지(오류, 질의로 대체 등).
