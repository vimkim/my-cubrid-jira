# [OOS] [M2] OOS 컬럼이 여러 개 있는 row 를 INSERT 하면 csql 가 죽는다

## Issue Triage

**이슈 수행 목적**: 큰 OOS 컬럼이 여러 개 들어 있는 row 를 INSERT 할 때 `csql` 가 assertion 으로 죽는 회귀를 고친다. `bigPageSize.sh` 의 `init.sql` 이 256 row 를 모두 INSERT 할 수 있어야 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: INSERT 가 row 를 disk 포맷으로 변환하는 단계 (`heap_attrinfo_transform_variable_to_disk`, `heap_file.c:13009-13018`) 의 OOS 분기는 한 OOS 컬럼마다 18 바이트 (`OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE`) 의 메타데이터를 record buffer 에 적는다. 그런데 buffer 공간이 충분한지 체크하는 위치와 실제로 쓰는 위치가 다르다. 체크는 offset table 영역에서 하고, 쓰기는 값 영역으로 점프해서 한다. 둘 다 같은 buffer 안이지만 위치가 다르다.
- **영향**: LOB/ELO 클러스터 회귀 9 건 (CBRD-26660) 의 머지 게이트가 막힌다. `bigPageSize.sh` 의 `init.sql` 첫 INSERT 에서 SIGABRT 가 나서 row 가 0 개 들어가고, 그 뒤의 unloaddb / loaddb 도 빈 입력으로 실패한다. 자매 회귀 CBRD-26813 (READ 측 fix) 도 데이터가 없으니 검증 불가.

**이슈 수행 방안**:

- **수정 위치**: `heap_file.c:13013` 의 bounds check `buf->ptr + OR_OOS_INLINE_SIZE > buf->endptr` 를 실제 쓰기 위치 기준 (`*ptr_varvals + OR_OOS_INLINE_SIZE > buf->endptr`) 으로 바꾸거나, `buf->ptr = *ptr_varvals` 점프 직후에 같은 체크를 한 번 더 둔다.
- **흐름 합류**: 체크가 정확해지면 buffer 가 부족할 때 `S_DOESNT_FIT` 가 반환되고, 호출자 `locator_allocate_copy_area_by_attr_info` (`locator_sr.c:7486`) 가 더 큰 buffer 로 재시도하는 기존 로직이 정상 작동한다.
- **검증 기준**: `csql -udba -S -i init.sql tdb1` 가 SIGABRT 없이 256 row 를 모두 INSERT 한다. CBRD-26813 패치와 함께 `bigPageSize.sh` 가 OK 로 통과하는지 확인.
- **TBD**:
    - bounds check 의 정확한 식이 `buf->endptr` 기준이 맞는지 `buf->buffer + buffer_size` 기준이 맞는지: `TBD - ANALYSIS 단계에서 결정`.
    - 단위 테스트로 쓸 최소 repro (현재는 `init.sql` 전체가 필요한데, OOS 컬럼 2-3 개짜리 작은 schema 로 좁히는 게 첫 작업): `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 gdb 스택을 대조해 작성한 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다.

### Summary

- **문제**: INSERT 의 disk transform 단계에서 OOS 분기의 buffer 공간 체크가 잘못된 위치에서 일어나, 실제 쓰기 위치에서 buffer 가 부족할 때 assertion 으로 죽는다.
- **배경**: OOS 컬럼은 row 안에 실제 값 대신 18 바이트짜리 포인터(OOS OID 10 + 길이 8) 만 남긴다. 여러 OOS 컬럼이 한 row 에 들어가면 그 18 바이트들이 누적돼서 어느 순간 buffer 끝을 넘는다.
- **변경**: bounds check 위치를 실제 쓰기 위치(`*ptr_varvals`) 기준으로 옮긴다. `S_DOESNT_FIT` 가 반환되면 호출자가 더 큰 buffer 로 재시도하는 기존 흐름과 합류.
- **영향 범위**: OOS-eligible 컬럼이 들어 있는 모든 INSERT/UPDATE. LOB/ELO 클러스터 회귀 9 건의 첫 단계 차단 원인일 가능성이 높다.

---

## Description

### 버그를 쉬운 말로

INSERT 가 disk 에 row 를 쓰기 직전에, CUBRID 는 row 를 record buffer 에 한 번 직렬화한다. row 의 가변 컬럼 (varchar, JSON, BLOB 같은 것들) 은 두 곳에 나눠 적힌다:

1. **offset table 영역**: 각 컬럼이 buffer 의 어디서 시작하는지 알려주는 작은 표.
2. **값 영역**: 컬럼의 실제 byte 들.

OOS 컬럼은 (1) 의 offset table 에는 평소처럼 짧은 entry 만 두지만, (2) 의 값 영역에는 실제 데이터 대신 18 바이트짜리 포인터 (`OOS OID 10 바이트 + 길이 8 바이트`) 를 남긴다. 진짜 값은 OOS file 에 따로 저장돼 있다.

이번 버그는 이 18 바이트를 값 영역에 적기 직전의 공간 체크가 잘못된 위치에서 일어난다는 점이다. 비유하자면, 노트의 두 섹션 중 **앞 섹션에 18 페이지 여유가 있는지** 확인한 다음 정작 **뒷 섹션에 18 페이지를 적는** 셈이다. 앞 섹션은 여유가 있지만 뒷 섹션은 이미 끝에 와 있으면 글이 노트 밖으로 빠져 나간다.

### 코드 위치

`src/storage/heap_file.c:13009-13018` (`heap_attrinfo_transform_variable_to_disk` 안의 OOS 분기):

```c
if (is_oos)
{
  /* (A) 공간 체크 — 그런데 buf->ptr 는 offset table 영역의 현재 위치다 */
  if (buf->ptr + OR_OOS_INLINE_SIZE > buf->endptr)
    {
      return S_DOESNT_FIT;
    }

  /* (B) 값 영역으로 점프 — 같은 buffer 안의 다른 위치 */
  buf->ptr = *ptr_varvals;

  /* (C) OOS OID 를 쓴다 (10 바이트) */
  or_put_oid (buf, oos_oid);

  /* (D) OOS 길이를 쓴다 (8 바이트) — buffer 끝을 넘으면 여기서 죽는다 */
  or_put_bigint (buf, oos_length);

  *ptr_varvals = buf->ptr;
}
```

(A) 의 체크가 통과한 뒤 (B) 가 `buf->ptr` 을 다른 위치로 옮긴다. 그 새 위치에서 18 바이트가 들어갈 공간이 있는지는 다시 확인하지 않는다. 그 결과 (D) 의 `or_put_bigint` 가 `buf->ptr + OR_BIGINT_SIZE <= buf->endptr` assertion 에서 죽는다.

### 왜 컬럼이 여럿이어야 발동하나

OOS 컬럼이 하나뿐이면 18 바이트 한 번만 쓰면 끝이라 buffer 가 충분하기 쉽다. 그러나 OOS 컬럼이 둘, 셋, 그 이상이면 매 OOS 컬럼마다 18 바이트씩 값 영역에 누적된다. 어느 순간 `*ptr_varvals` 가 `buf->endptr` 근처에 닿고, 다음 OOS 컬럼의 18 바이트가 buffer 밖으로 비어져 나간다.

`bigPageSize` 의 schema 는 OOS 임계치를 넘는 컬럼이 5 개 이상 (`c2 varchar(10757)`, `c3 string`, `cl clob`, `bl blob`, `j json`) 이라 이 버그가 첫 INSERT 부터 바로 터진다.

### 호출자 retry 흐름과의 관계

(A) 가 `S_DOESNT_FIT` 를 반환하면 호출자 `locator_allocate_copy_area_by_attr_info` (`locator_sr.c:7486`) 가 더 큰 copyarea 를 받아 retry 한다. 이 흐름은 이미 잘 짜여 있다. 본 회귀는 그 retry 가 발동돼야 할 자리에서 assertion 으로 죽는 것이 핵심이다 — 체크 위치만 정확해지면 retry 흐름으로 자연스럽게 합류한다.

### gdb 스택 (debug build, `8d7b97a` + CBRD-26813 패치 상태)

```
#0  or_put_bigint                            object_representation.h:1745
       buf=0x7fffffff4b40, num=1096
#1  heap_attrinfo_transform_variable_to_disk heap_file.c:13017
       is_oos=true, oos_oid=0x4ad9ae8, oos_length=1096, index=25,
       offset_size=2, header_size=16
#2  heap_attrinfo_transform_columns_to_disk  heap_file.c:13129
#3  heap_attrinfo_transform_to_disk_internal heap_file.c:13271
#4  heap_attrinfo_transform_to_disk          heap_file.c:12726
#5  locator_allocate_copy_area_by_attr_info  locator_sr.c:7486
#6  locator_attribute_info_force             locator_sr.c:7668
#7  qexec_execute_insert                     query_executor.c:13047
...
#19 do_execute_insert                        execute_statement.c:14075
#23 csql_execute_statements                  csql.c:2295
```

`oos_length=1096`, `index=25` (25 번째 컬럼) — schema 의 마지막 즈음 OOS 컬럼이 들어가는 시점에 발동.

## Test Build

- `CUBRID 11.5.0 (11.5.0.2328-8d7b97a) (64bit debug build for Linux)`
- 브랜치: `feat-oos-m2-manual` (commit `8d7b97a88`).
- 자매 sub-task CBRD-26813 (`vk/cbrd-26813-oos-bigone-expand`, commit `6087ed163`) 가 적용된 상태에서도 동일하게 재현.
- OS: RHEL 9.6 (5.14.0-570.30.1.el9_6.x86_64).

## Repro

```bash
cubrid service start
cubrid deletedb tdb1 2>/dev/null
cubrid createdb -r tdb1 en_US

CASES=/home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
csql -udba -S -i ${CASES}/createtbl.sql tdb1

# 실패 단계:
csql -udba -S -i ${CASES}/init.sql tdb1
```

결과:

```
Execute OK. (0.000000 sec) Committed. (0.000000 sec)    # set @j='...';
csql: src/base/object_representation.h:1745:
  int or_put_bigint(OR_BUF *, DB_BIGINT):
  Assertion `buf->ptr + OR_BIGINT_SIZE <= buf->endptr' failed.
```

`select count(*) from t` 결과: 0 row.

핵심 schema (`createtbl.sql` 발췌) — OOS 임계치를 넘는 컬럼이 다수:

```sql
CREATE TABLE t (
  id INT AUTO_INCREMENT,
  col1 SMALLINT, col2 INT, col3 BIGINT,
  col4 NUMERIC(4,4), col5 FLOAT, col6 DOUBLE,
  d1 DATE, ..., d8 DATETIMETZ,
  b1 BIT, c1 CHAR(4),
  c2 VARCHAR(10757),
  c3 STRING,
  e ENUM (...),
  cl CLOB,
  bl BLOB,
  s1 SET (CHAR(1)), s2 MULTISET (CHAR(1)), s3 LIST (CHAR(1)),
  j JSON
);
```

`init.sql` 첫 INSERT 는 `c2 = repeat(@j, 780)` (수 MB), `c3 = repeat(@j, 780)`, `cl = CHAR_TO_CLOB('...')`, `bl = BIT_TO_BLOB(X'000001')`, `j = repeat(@j, 780)` 등 OOS-eligible 컬럼이 여럿 동시에 채워진다.

### TBD - 최소 repro

분석 시작 시점에 `varchar(20000) + blob` 1 row 로는 재현되지 않았다. OOS 컬럼 한 개로는 부족하고 두 개 이상 + 일정 크기가 필요해 보인다. 분석 단계의 첫 작업으로 최소 schema 를 좁힌 뒤 단위 테스트화 가능한 형태로 정리.

## Expected Result

```
$ csql -udba -S -i ${CASES}/init.sql tdb1
... (no abort) ...
$ csql -udba -S -c "select count(*) from t;" tdb1
                     256
```

## Actual Result

첫 INSERT 에서 `or_put_bigint` assertion 으로 SIGABRT. row 0 개.

## Additional Information

### CBRD-26813 과의 관계

두 sub-task 는 같은 OOS 경로의 서로 다른 단계 회귀다.

| Sub-task | 단계 | 위치 |
|---|---|---|
| **본 sub-task (CBRD-26814)** | WRITE | `heap_attrinfo_transform_variable_to_disk` (`heap_file.c:13017`) |
| CBRD-26813 | READ | `heap_get_record_data_when_all_ready` 의 `REC_BIGONE` 분기 (`heap_file.c:7934`) |

CBRD-26813 만 머지하면 `init.sql` 단계에서 막혀 검증이 불가하다. CBRD-26814 가 먼저 (또는 같이) 머지돼야 `bigPageSize.sh` 가 끝까지 진행된다.

### 영향 클러스터

CBRD-26660 의 LOB/ELO 클러스터 9 건이 본 회귀의 영향권. 각각의 테스트 모두 BLOB/CLOB/JSON + 큰 varchar 가 섞인 row 를 INSERT 해야 본 시나리오에 도달하는데, INSERT 자체가 막히면 후속 단계 전체가 불통이다.

## Implementation

### 1단계: 최소 repro 좁히기

`init.sql` 의 첫 INSERT 에서 컬럼을 하나씩 빼며 어느 조합부터 SIGABRT 가 사라지는지 확인. 예상은 OOS-eligible 컬럼 (`c2`, `c3`, `cl`, `bl`, `j`) 중 둘 이상이 동시에 있을 때 발동.

```bash
csql -udba -S tdb1 -c "create table t (c2 varchar(10000), c3 string, j json);"
csql -udba -S tdb1 -c "insert into t values (repeat('x', 8000), repeat('y', 8000), repeat('{\"k\":\"v\"}', 200));"
```

좁힌 schema 를 단위 테스트로 등록.

### 2단계: gdb 로 가설 확인

```
break heap_file.c:13013   # bounds check
break heap_file.c:13017   # or_put_oid 직전
break heap_file.c:13018   # or_put_bigint 직전 (크래시 직전)
```

각 break 에서 다음 값을 dump:

- `buf->buffer`, `buf->buffer_size`, `buf->endptr` (buffer 전체)
- `buf->ptr` (현재 offset table 위치)
- `*ptr_varvals` (값 영역 쓰기 위치)
- 차이값: `buf->endptr - *ptr_varvals`

가설이 맞으면 (A) 의 체크는 통과 (`buf->endptr - buf->ptr >= 18`) 하지만 (B) 점프 후 `*ptr_varvals + 18 > buf->endptr` 가 된다.

### 3단계: 패치

`heap_file.c:13007-13018` 의 OOS 분기를 다음 패턴으로 (정확한 식은 2단계 후 결정):

```c
if (is_oos)
{
  assert (dbvalue != NULL && db_value_is_null (dbvalue) != true);

  /* offset table entry 공간 체크 (기존) */
  if ((buf->ptr + offset_size) > buf->endptr)
    {
      return S_DOESNT_FIT;
    }

  length = CAST_BUFLEN (*ptr_varvals - buf->buffer - header_size);
  length = OR_SET_VAR_OOS (length);
  or_put_offset_internal (buf, length, offset_size);

  /* NEW: 값 영역 쓰기 위치 기준으로 다시 체크 */
  if (*ptr_varvals + OR_OOS_INLINE_SIZE > buf->endptr)
    {
      return S_DOESNT_FIT;
    }

  buf->ptr = *ptr_varvals;
  or_put_oid (buf, oos_oid);
  or_put_bigint (buf, oos_length);
  *ptr_varvals = buf->ptr;
}
```

`S_DOESNT_FIT` 반환 시 호출자 `locator_allocate_copy_area_by_attr_info` (`locator_sr.c:7486`) 가 더 큰 copyarea 로 retry 하는 기존 로직과 합류.

### 4단계: 회귀 재실행

```bash
# 본 sub-task 단독
csql -udba -S -i ${CASES}/init.sql tdb1
csql -udba -S tdb1 -c "select count(*) from t;"     # 256 가 나와야 함

# CBRD-26813 과 같이
bash ${CASES}/bigPageSize.sh
```

### 5단계: 단위 테스트 (TBD)

`unit_tests/` 에 OOS-eligible 컬럼이 둘 이상 있는 row 의 disk transform round-trip 테스트 추가. write -> read 가 원래 값과 같아야 한다.

## Acceptance Criteria

- [ ] `csql -udba -S -i init.sql tdb1` 가 SIGABRT 없이 256 row 를 모두 INSERT.
- [ ] CBRD-26813 패치와 함께 적용했을 때 `bigPageSize.sh` 가 OK 로 통과.
- [ ] CBRD-26660 의 LOB/ELO 클러스터 9 건 일괄 재실행 결과를 본 sub-task 댓글에 표로 기록 — 같이 풀리는 항목은 close-out, 남는 항목은 별도 sub-task 로 분리.
- [ ] 최소 repro 가 좁혀져 본 sub-task 댓글 또는 단위 테스트로 등록.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] PR merge.
- [ ] CBRD-26660 의 클러스터 1 표에 본 sub-task 번호 기록.

## 참고 코드

| 파일:줄 | 역할 |
|---|---|
| `src/storage/heap_file.c:13009-13018` | **수정 대상**. OOS 분기의 bounds check 가 잘못된 위치 기준. |
| `src/storage/heap_file.c:13017` (`or_put_oid`), `:13018` (`or_put_bigint`) | 크래시 사이트. 실제 write 가 일어나는 곳. |
| `src/base/object_representation.h:455` | `OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE = 18`. |
| `src/base/object_representation.h:1745` (`or_put_bigint`) | assertion 사이트. |
| `src/transaction/locator_sr.c:7486` (`locator_allocate_copy_area_by_attr_info`) | `S_DOESNT_FIT` retry 호출자. fix 가 들어가면 이 retry 흐름으로 합류. |
| `src/storage/heap_file.c:13129` (`heap_attrinfo_transform_columns_to_disk`) | 컬럼 단위 dispatch. |
| `src/query/query_executor.c:13047` (`qexec_execute_insert`) | INSERT XASL 실행 진입점. |

## Remarks

- 부모 epic: CBRD-26583 (OOS M2 epic).
- 자매 sub-task: CBRD-26813 (REC_BIGONE OOS expansion, READ 측 회귀).
- 동반 sub-task: CBRD-26660 (M2 매뉴얼 회귀 분류).
- 본 회귀가 풀려야 CBRD-26813 의 fix 가 `bigPageSize.sh` 끝까지 검증 가능.
