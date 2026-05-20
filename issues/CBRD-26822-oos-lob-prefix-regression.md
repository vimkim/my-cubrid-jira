# [OOS] LOB INSERT 시 HFID-attrid prefix 가 빠져 CLOB/BLOB 파일이 디스크에 만들어지지 않는 버그

## Issue Triage

**이슈 수행 목적** (필수): OOS branch 의 모든 빌드에서 CLOB/BLOB 컬럼 INSERT 후 동일 row 의 locator 로 `CLOB_FROM_FILE` / `BLOB_FROM_FILE` 가 ER_ES_INVALID_PATH 없이 원래 값을 반환한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: develop 의 canonical LOB write 경로 (`heap_attrinfo_transform_variable_to_disk`) 는 `snprintf (lob_path_prefix, PATH_MAX, "%d%d%d%d", HFID_AS_ARGS (&hfid), attrid)` 로 테이블별 prefix 를 만들고 `db_elo_copy_with_prefix` 를 호출해, 임시 LOB 파일을 `lob/<HFID-attrid>/ces_NNN/file.dat` 로 옮긴 뒤 같은 경로를 row 의 locator 에 stamp 한다. 그러나 본 branch 의 동일 함수는 `db_elo_copy` (prefix 없는 버전) 를 호출하고 있다. 추가로 OOS branch 가 새로 도입한 `heap_attrinfo_dbvalue_to_recdes` 도 처음부터 prefix 없이 작성됐다.
- **영향**: `CREATE TABLE t (c CLOB); INSERT INTO t VALUES (CHAR_TO_CLOB('hello'));` 만으로도 LOB 파일이 디스크에 만들어지지 않는다. row 의 locator (`file:ces_NNN/dba.t.<id>`) 는 prefix 가 빠진 경로를 가리키므로 `CLOB_FROM_FILE(locator)` 는 stat 실패 후 ER_ES_INVALID_PATH 로 떨어진다. CI shell 의 B 클러스터 (`bug_bts_7596`, `bug_bts_10290`, `bug_bts_16011`, `cbrd_23349`) 가 NOK 로 떨어지는 직접적 원인이다.

**이슈 수행 방안**:

- `heap_attrinfo_transform_variable_to_disk` (`src/storage/heap_file.c`) 의 LOB 분기에서 `heap_hfid_cache_get` 으로 hfid 를 가져온 뒤 `snprintf (lob_path_prefix, PATH_MAX, "%d%d%d%d", HFID_AS_ARGS (&hfid), value->attrid)` 로 prefix 를 만들고 `db_elo_copy_with_prefix` 를 호출한다. develop 의 동일 분기와 의미상 동일하게 맞춘다.
- 동일 패턴을 OOS-eligible 경로인 `heap_attrinfo_dbvalue_to_recdes` 에도 적용한다. 이 함수는 `class_oid` 를 값으로 받으므로 그 지역변수의 주소 (`&class_oid`) 로 hfid 캐시를 조회한다.
- 변경 범위는 `src/storage/heap_file.c` 한 파일. ES / ELO / `locator_sr` / OOS expand / index / WAL 은 손대지 않는다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고한다.

## Summary

- **누락된 함수 호출**: `heap_attrinfo_transform_variable_to_disk` 와 `heap_attrinfo_dbvalue_to_recdes` 둘 다 `db_elo_copy_with_prefix` 대신 `db_elo_copy` 를 호출한다. prefix 인자가 빠지면 `xes_posix_move_file_with_prefix` 가 호출되지 않고, 임시 LOB 파일이 `lob/<HFID-attrid>/` 디렉터리로 옮겨지지 않는다.
- **call chain (망가진 쪽)**: `INSERT` -> `heap_attrinfo_transform_to_disk_internal` -> `heap_attrinfo_transform_columns_to_disk` -> 위 두 함수 -> `db_elo_copy` -> 임시 디렉터리 그대로 잔존, row 안의 locator 는 prefix 없는 경로를 가리킨다.
- **에러 노출 지점**: `CLOB_FROM_FILE` / `BLOB_FROM_FILE` -> `lob_from_file` (`src/query/string_opfunc.c:17453`) -> `db_elo_size` 가 stat 실패하면 `lob_from_file` 가 `ER_ES_INVALID_PATH` 를 emit (`src/query/string_opfunc.c:17469`).
- **용어**:
  - OOS (Out-of-row Overflow Storage, CBRD-26583 의 M2 마일스톤에서 도입된 큰 가변 컬럼 외부 저장 매커니즘)
  - ELO (External LOB Object, CUBRID 의 LOB 추상화 계층)
  - HFID (Heap File ID, `(volid, fileid, hpgid)` 3-튜플)
  - attrid (attribute ID, 컬럼 식별자)
  - recdes (record descriptor, 디스크 row 바이트 표현 구조체)
  - locator (LOB locator, `"file:..."` 형태로 row 안에 저장되는 외부 파일 경로 문자열)
  - ces_NNN (CUBRID External Storage 의 디렉터리 이름; NNN 은 hash-derived sequence)

## Scope

- **In-scope**: `src/storage/heap_file.c` 의 두 함수 — `heap_attrinfo_transform_variable_to_disk` (line 12979) 와 `heap_attrinfo_dbvalue_to_recdes` (line 12570).
- **Out-of-scope**: `src/storage/es*.c`, `src/object/elo.c`, `src/transaction/locator_sr.c` (xlob_*), OOS expand / heap_record_replace_oos_oids, CBRD-26816 CTP 환경 이슈, `bug_bts_16011` / `cbrd_23349` 의 conf 비어 있음 문제.

## Description

CHAR_TO_CLOB 또는 BLOB literal 로 만든 LOB 값을 `INSERT` 하면 본 branch 의 빌드에서는 다음 두 가지가 함께 일어난다.

1. row 안의 LOB 컬럼에는 `file:ces_NNN/dba.<table>.<id>` 형태의 locator 가 정상 저장된다.
2. 그러나 그 locator 가 가리키는 파일 자체는 디스크 어디에도 만들어지지 않는다. `find $CUBRID_DATABASES/lobdb/lob -type f` 가 0 줄을 리턴한다.

이후 같은 row 의 locator 를 `CLOB_FROM_FILE` / `BLOB_FROM_FILE` 에 다시 넘기면 ES 계층이 stat 에서 실패하고 ER_ES_INVALID_PATH 가 노출된다.

### 왜 파일이 만들어지지 않는가

CREATE TABLE 시점부터 INSERT 까지의 prefix 흐름은 다음과 같다.

```
CREATE TABLE t (c CLOB)
  -> xlob_create_dir (src/transaction/locator_sr.c:14201)
     -> locator_lob_make_dir_path (src/transaction/locator_sr.c:14271)
        snprintf (lob_path, PATH_MAX, "%d%d%d%d", HFID_AS_ARGS (hfid), attrid)
     -> es_make_dirs ($CUBRID_DATABASES/lobdb/lob/<prefix>/)
```

INSERT 가 같은 prefix 포맷으로 파일을 옮겨야 비로소 DDL 시점에 만들어 둔 디렉터리 안에 LOB 파일이 들어간다.

develop 의 LOB INSERT 분기 (`heap_attrinfo_transform_variable_to_disk`) 가 따르는 흐름은 다음과 같다.

```
INSERT
  -> heap_attrinfo_transform_to_disk_internal
     -> heap_attrinfo_transform_columns_to_disk
        -> heap_attrinfo_transform_variable_to_disk      (CLOB/BLOB 분기)
           heap_hfid_cache_get (&attr_info->class_oid, &hfid)
           snprintf (lob_path_prefix, "%d%d%d%d",
                     HFID_AS_ARGS (&hfid), value->attrid)
           db_elo_copy_with_prefix (src_elo, lob_path_prefix, &dest_elo)
              -> elo_copy_with_prefix (src/object/elo.c:367)
                 -> es_move_file_with_prefix (src/storage/es.c:544)
                    -> xes_posix_move_file_with_prefix (src/storage/es_posix.c:835)
                       lob/ces_temp/...  ->  lob/<prefix>/ces_NNN/file.dat
                 -> dest_elo->locator = "file:<prefix>/ces_NNN/file.dat"
```

본 branch 는 두 호출 지점 모두 `db_elo_copy` (`src/object/elo.c:213`, prefix 없는 버전) 를 호출한다. 결과적으로:

- 임시 파일이 옮겨질 목적지가 prefix 없이 계산되고,
- 그렇게 만들어진 path 와 row 의 locator 가 모두 prefix 가 빠진 채 저장되며,
- DDL 시점에 만들어 둔 `lob/<prefix>/` 디렉터리는 비어 있고 locator 가 가리키는 위치엔 파일이 없다.

`CLOB_FROM_FILE` 은 row 의 locator 를 `lob_from_file` -> `db_elo_size` -> `xes_posix_get_file_size` 로 보내 stat 을 호출한다. 파일이 없으니 stat 이 실패하고 `lob_from_file` 가 ER_ES_INVALID_PATH 를 emit 한다 (`src/query/string_opfunc.c:17469`).

### 어떤 호출이 누락됐는가

`git show 8ba543178:src/storage/heap_file.c` 의 develop 본문과 본 branch 본문을 비교한 결과는 다음과 같다.

| 위치 | develop | 본 branch |
|---|---|---|
| `heap_attrinfo_transform_variable_to_disk` (heap_file.c:12979) | `db_elo_copy_with_prefix (src, lob_path_prefix, &dest)` | `db_elo_copy (src, &dest)` |
| `heap_attrinfo_dbvalue_to_recdes` (heap_file.c:12570) | 함수 자체가 존재하지 않음 | OOS branch 가 새로 도입한 함수다. develop 의 canonical prefix 호출 의도를 옮기지 않은 채로 만들어졌다. |

두 호출 모두 prefix 가 빠져 있으므로 OOS 가 켜졌든 꺼졌든 동일한 방식으로 LOB 파일이 잘못된 위치에 저장된다.

### 회귀 노출 경위

근본 원인은 commit `2cedac9fc "merge conflict"` (KIM HUISU, 2026-02-24) 의 잘못된 merge conflict resolution 이다. 해당 commit 의 `src/storage/heap_file.c` 차분에서 다음 3 줄이 삭제됐다:

```c
- char lob_path_prefix[PATH_MAX];
- snprintf (lob_path_prefix, PATH_MAX, "%d%d%d%d", HFID_AS_ARGS (&hfid), attrid);
- ret = db_elo_copy_with_prefix (db_get_elo (dbvalue), lob_path_prefix, &dest_elo);
```

그리고 1 줄이 추가됐다:

```c
+ rv = db_elo_copy (db_get_elo (dbvalue), &dest_elo);
```

OOS branch 가 develop 을 흡수할 때 두 쪽의 LOB write 분기가 충돌했는데, resolver 가 OOS-side 의 prefix 없는 버전을 채택하면서 develop 쪽 prefix 생성 코드가 통째로 사라진 결과다.

다만 같은 시점에 `_develop_ver` 변형 함수군은 prefix 있는 develop 본문을 별도 사본으로 보관하고 있었다. OOS-eligible 호출자가 `_develop_ver` 쪽을 거치는 동안에는 회귀가 가려졌고, `b30244cb9 "Remove _develop_ver function family from heap_file.c"` 가 shim 을 정리하면서 가림막이 사라져 OOS expand 경로까지 canonical 의 버그에 노출됐다. 비-OOS LOB INSERT 경로는 `2cedac9fc` 시점부터 줄곧 같은 버그를 안고 있었다. 따라서 b30244cb9 는 회귀 도입 커밋이 아니라 회귀 노출 커밋이며, 진짜 도입 시점은 `2cedac9fc` 이다.

## Test Build

`CUBRID 11.5.0.2336 (debug build, clang20)`, OS: Linux 5.14.0-570.30.1.el9_6.x86_64

- base 커밋: `e2a5d2b10` (`vk/cbrd-26815-oos-json-deserialize` merge from cub/develop)
- 회귀 도입 커밋: `2cedac9fc "merge conflict"` (KIM HUISU, 2026-02-24) — develop merge 의 conflict resolution 에서 prefix 생성 + `db_elo_copy_with_prefix` 3 줄을 버리고 prefix 없는 OOS-side `db_elo_copy` 1 줄을 채택.
- 회귀 노출 커밋: `b30244cb9 "Remove _develop_ver function family from heap_file.c"` ( masking shim 제거)
- 수정 커밋: `b19f88f70 [CBRD-26822] Restore LOB-path prefix in heap LOB INSERT` on branch `vk/cbrd-26815-b-cluster-oos-lob-leak`

## Repro

전제 조건: `$CUBRID` / `$CUBRID_DATABASES` 가 환경에 설정돼 있어야 한다 (`source $CUBRID/share/init/cubrid.sh` 또는 direnv `.envrc` 로 export). 아래 스크립트는 그 후에 복사-붙여넣기로 실행 가능하다.

```sh
./build.sh -m debug
source $CUBRID/share/init/cubrid.sh   # $CUBRID, $CUBRID_DATABASES 가 export 됨

cubrid service stop
cubrid deletedb lobdb 2>/dev/null
cubrid createdb --db-volume-size=20M --log-volume-size=20M lobdb en_US

# ;commit 은 csql 의 session command 다. autocommit OFF 상황에서도 INSERT 를 강제 commit 한다.
csql -u dba -S lobdb <<'EOF'
CREATE TABLE t (c CLOB);
INSERT INTO t VALUES (CHAR_TO_CLOB('hello'));
;commit
select c from t;
EOF

# row 의 locator 를 robust 하게 추출한다 (위치 의존 awk 회피).
LOCATOR=$(csql -u dba -S -c "select c from t;" lobdb \
            | grep -E '^[[:space:]]+file:' | head -1 | awk '{print $1}')
echo "row locator: $LOCATOR"

csql -u dba -S lobdb -c "select cast(clob_from_file('$LOCATOR') as varchar) from db_root;"

# DDL 시점에 xlob_create_dir 이 만든 prefix 디렉터리 아래에 LOB 파일이 존재해야 한다.
find "$CUBRID_DATABASES/lobdb/lob" -type f
```

## Expected Result

```
=== <Result of SELECT Command in Line 1> ===

  <castedExpr>
==============
  'hello'
```

`<castedExpr>` 자리는 csql 이 원래 SELECT expression 전체를 그대로 헤더로 찍는다. 예를 들어 위 Repro 의 마지막 csql 호출에서는 `cast(clob_from_file('file:...') as varchar)` 가 그대로 들어간다. 자동화 검증 시에는 헤더 라인을 무시하고 값 라인 (`'hello'`) 만 확인한다.

```
# find 출력에 lob/<HFID-attrid>/ces_NNN/dba.t.<id> 형태 경로의 파일이 존재한다.
```

## Actual Result

csql 출력은 두 단계로 나뉘어 보인다. 앞쪽은 csql parser 가 EOF 부근에서 토큰을 보고하는 preamble 이고, 뒤쪽이 실제 ER_ES_INVALID_PATH 본문이다.

```
In line 1, column N,
ERROR: before ' ) as varchar) from db_root;'
```

```
Path for external storage 'file:ces_NNN/dba.t.<id>' is invalid.
```

```
# find 출력 0 줄 — lob 디렉터리가 비어 있음
```

## Implementation

### 변경 1 — `heap_attrinfo_transform_variable_to_disk` (`src/storage/heap_file.c:12979`)

LOB 분기에서 prefix 를 다시 만들고 `_with_prefix` 호출을 복원한다. `value->attrid` 는 호출자 (`heap_attrinfo_transform_columns_to_disk`) 가 `attr_info->values[i]` 를 넘기는 시점에 이미 채워져 있다. `heap_hfid_cache_get` 의 반환값은 체크하지 않는다 — CREATE TABLE 시점에 `xlob_create_dir` 가 동일한 HFID 로 directory 를 만들었으므로 hfid 캐시는 이 시점에 항상 채워져 있다. develop 의 호출 패턴과 동일하다.

```c
if (heap_get_class_name (thread_p, &attr_info->class_oid, &new_meta_data) != NO_ERROR
    || new_meta_data == NULL)
  {
    return S_ERROR;
  }
save_meta_data = elo_p->meta_data;
elo_p->meta_data = new_meta_data;
{
  HFID hfid;
  char lob_path_prefix[PATH_MAX];

  /* hfid cache 는 xlob_create_dir 가 DDL 시점에 채웠으므로 별도 체크 없이 사용한다. */
  heap_hfid_cache_get (thread_p, &attr_info->class_oid, &hfid, NULL, NULL);
  snprintf (lob_path_prefix, PATH_MAX, "%d%d%d%d",
            HFID_AS_ARGS (&hfid), value->attrid);
  rv = db_elo_copy_with_prefix (db_get_elo (dbvalue),
                                lob_path_prefix, &dest_elo);
}
free_and_init (elo_p->meta_data);
elo_p->meta_data = save_meta_data;

if (rv < 0)
  {
    return S_ERROR;
  }
```

### 변경 2 — `heap_attrinfo_dbvalue_to_recdes` (`src/storage/heap_file.c:12570`)

OOS-eligible LOB 경로에도 동일한 patch 를 적용한다. 이 함수는 `class_oid` 를 값으로 받기 때문에 지역변수 주소 (`&class_oid`) 를 hfid 캐시에 넘긴다. 변경 1 의 `attr_info->class_oid` 와 가리키는 OID 자체는 같다 — 호출 진입 시점에 `attr_info->class_oid` 가 값 복사돼 들어왔기 때문이다. 위와 같은 이유로 `heap_hfid_cache_get` 반환값은 체크하지 않는다.

```c
if (heap_get_class_name (thread_p, &class_oid, &new_meta_data) != NO_ERROR
    || new_meta_data == NULL)
  {
    return S_ERROR;
  }
save_meta_data = elo_p->meta_data;
elo_p->meta_data = new_meta_data;
{
  HFID hfid;
  char lob_path_prefix[PATH_MAX];

  /* class_oid 는 값으로 전달돼 지역변수에 들어와 있다. xlob_create_dir 가 동일한
   * HFID 로 directory 를 만들었으므로 hfid 캐시는 항상 채워져 있다. */
  heap_hfid_cache_get (thread_p, &class_oid, &hfid, NULL, NULL);
  snprintf (lob_path_prefix, PATH_MAX, "%d%d%d%d",
            HFID_AS_ARGS (&hfid), value->attrid);
  rv = db_elo_copy_with_prefix (db_get_elo (dbvalue),
                                lob_path_prefix, &dest_elo);
}
free_and_init (elo_p->meta_data);
elo_p->meta_data = save_meta_data;

value->state = HEAP_WRITTEN_LOB_ATTRVALUE;

if (rv < 0)
  {
    return S_ERROR;
  }
```

### 변경 안 한 것

- `es_*`, `xes_posix_*`, `elo_copy_with_prefix` 본체 — develop 과 동일하므로 그대로 둔다.
- `xlob_create_dir` / `xlob_remove_dir` (`src/transaction/locator_sr.c`) — DDL 시점 prefix 디렉터리 생성·삭제 로직. 본 버그와 무관하다.
- OOS expand 경로 / `heap_record_replace_oos_oids` — 본 버그와 무관한 별도 경로.

## Acceptance Criteria

- [ ] 위 Repro 의 `select cast(clob_from_file('$LOCATOR') as varchar)` 가 `'hello'` 를 반환한다.
- [ ] INSERT 한 row 의 LOB 파일이 `find "$CUBRID_DATABASES/lobdb/lob" -path '*/ces_*/*' -type f` 결과에 존재한다.
- [ ] `bug_bts_7596` (`shell/_06_issues/_12_2h/bug_bts_7596`) 가 OK 로 통과한다.
- [ ] `bug_bts_10290` (`shell/_06_issues/_12_2h/bug_bts_10290`) 가 OK 로 통과한다.
- [ ] 위 두 테스트 모두 `Total Fail Case:0` 으로 끝난다.
- [ ] `./build.sh -m debug`, `./build.sh -m release` 클린 빌드.
- [ ] `heap_attrinfo_dbvalue_to_recdes` 의 hfid 조회는 인자가 값-전달된 `class_oid` 지역변수의 주소를 사용한다 (`&class_oid`). 변경 1 의 `&attr_info->class_oid` 와 의미상 동등하나 함수 시그니처가 달라 표기가 다르다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족.
- [ ] CI (`test_sql`, `test_medium`, `test_shell`) 기준 `bug_bts_7596` / `bug_bts_10290` 회귀가 사라진다.
- [ ] develop 의 `heap_attrinfo_transform_variable_to_disk` LOB 분기 (커밋 `8ba543178`, line 12200 부근) 의 prefix 생성 로직과 본 branch 의 동일 분기 사이에 의미상 동일 (함수 이름·prefix 포맷 일치).

## 참고 코드

- `src/storage/heap_file.c:12979 heap_attrinfo_transform_variable_to_disk` — non-OOS LOB write 경로 (수정 대상 1).
- `src/storage/heap_file.c:12570 heap_attrinfo_dbvalue_to_recdes` — OOS-eligible LOB write 경로 (수정 대상 2).
- `src/transaction/locator_sr.c:14271 locator_lob_make_dir_path` — `"%d%d%d%d"` prefix 포맷의 단일 출처.
- `src/transaction/locator_sr.c:14201 xlob_create_dir` — CREATE TABLE 시 `lob/<HFID-attrid>/` 디렉터리를 미리 만드는 함수.
- `src/object/elo.c:367 elo_copy_with_prefix` — prefix 를 받아 `es_move_file_with_prefix` 로 내려보내는 ELO 계층.
- `src/object/elo.c:213 elo_copy` — prefix 없는 버전. 본 버그에서 잘못 호출되던 함수.
- `src/storage/es.c:544 es_move_file_with_prefix` — ES 계층의 prefix-aware move 진입점.
- `src/storage/es_posix.c:835 xes_posix_move_file_with_prefix` — `<prefix>/<dirname1>/<filename>` 경로를 만드는 POSIX 구현.
- `src/query/string_opfunc.c:17453 lob_from_file` — `CLOB_FROM_FILE` / `BLOB_FROM_FILE` 본체. stat 실패 시 ER_ES_INVALID_PATH 를 emit (`src/query/string_opfunc.c:17469`).

## Remarks

- prefix 예시: `vol=5 file=131 hpg=4 attrid=2` 일 때 `"%d%d%d%d"` 결과는 `"513142"` 다. `%d` 사이에 구분자가 없어 자릿수 캐리 시 ambiguity 가 발생할 수 있으나, 이 ambiguity 자체는 본 버그와 별개이며 out of scope 다.
- 본 버그는 OOS 자체와 무관한 LOB INSERT 경로의 버그지만 OOS 리팩터링 중 정리 과정에서 노출됐으므로 CBRD-26583 (OOS M2 EPIC) 의 sub-task 로 다룬다.
- `bug_bts_16011`, `cbrd_23349` 두 테스트는 본 fix 이후에도 NOK 인데, `cubrid_createdb` 단계에서 conf 가 비어 있는 별도 CTP 환경 이슈로 추정된다. 근본 원인 분석은 CBRD-26816 후속 작업에서 다룬다.
