# [OOS] [M2] OOS 컬럼이 들어 있는 row 를 unloaddb 로 읽을 때 JSON 역직렬화가 죽는다

## Issue Triage

**이슈 수행 목적**: BLOB/CLOB/JSON 컬럼을 가진 row 를 OOS 로 저장한 뒤 `unloaddb` 로 추출할 때 JSON 컬럼 역직렬화가 invalid type 으로 죽는 회귀를 고친다. `bigPageSize.sh` 가 끝까지 OK 로 통과한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `cubrid unloaddb -S tdb1` 가 첫 row 의 JSON 컬럼을 읽다가 `db_json_deserialize_doc_internal` (`src/compat/db_json.cpp:4260`) 의 `default:` 케이스에서 `assert(false)` 로 SIGABRT. 이 default 는 buffer 의 type 바이트가 `DB_JSON_BOOL`/`DB_JSON_NULL`/`DB_JSON_OBJECT`/`DB_JSON_ARRAY`/`DB_JSON_STRING`/`DB_JSON_INT`/`DB_JSON_BIGINT`/`DB_JSON_DOUBLE` 중 어느 것도 아닐 때 발동한다. 즉 OOS 로 저장된 JSON 페이로드를 다시 읽을 때 buffer cursor 가 엉뚱한 위치를 가리키거나 OOS 가 풀어낸 바이트가 type 헤더 없이 페이로드만 들어가 있다는 뜻.
- **영향**: LOB/ELO 클러스터 회귀 9 건 (CBRD-26660) 의 머지 게이트 차단. CBRD-26813 (`vk/cbrd-26813-oos-bigone-expand`) 의 READ-side BIGONE 패치와 CBRD-26814 (`vk/cbrd-26814-oos-write-bounds-check`) 의 WRITE-side bounds-check 패치를 둘 다 적용해도 unloaddb 가 이 지점에서 죽어 `bigPageSize.sh` 가 NOK 다. `tdb1_objects` 에 1 row 만 추출된다.

**이슈 수행 방안**:

- **1단계 — 가설 확인**: `db_json_deserialize_doc_internal` 진입 시점에 `OR_BUF` 의 `ptr` 가 가리키는 첫 바이트 (JSON value type 바이트) 의 값을 확인한다. 정상이라면 `DB_JSON_OBJECT` (=2) 또는 `DB_JSON_STRING` (=4) 같은 작은 enum 값. 비정상이면 두 갈래로 좁힌다: (a) OOS-OID 가 inline value 로 풀리지 않은 채 그대로 넘어왔는지, (b) OOS-OID 는 풀렸지만 값 영역의 시작 위치가 어긋났는지.
- **2단계 — 수정 위치 후보**:
    - `src/storage/heap_file.c::heap_record_replace_oos_oids` (line 7975) — OOS-OID 자리에 inline JSON 페이로드를 채워 넣을 때 type 바이트 + payload 의 직렬화 형식을 유지하는지.
    - `src/storage/oos_file.cpp::oos_read` (line 1372) — 저장 측이 type 바이트를 같이 넣었는지, 또는 OOS file 에는 payload 만 있고 type 은 별도로 보관되는지의 contract.
    - `src/object/object_primitive.c` 의 JSON write/read 경로 — JSON 컬럼이 OOS 로 빠질 때 어디서부터를 OOS 페이로드로 보고 어디서부터를 inline 으로 두는지.
- **검증 기준**: CBRD-26813 + CBRD-26814 패치가 적용된 상태에서 `bigPageSize.sh` 가 OK 로 통과. `csql tdb1 -c "select id, json_pretty(j) from t limit 3"` 가 정상 JSON 을 반환.
- **TBD**:
    - 정확한 fix 위치 (heap_record_replace_oos_oids 의 JSON 페이로드 복원 vs JSON write 경로의 OOS 페이로드 시작 위치): `TBD - ANALYSIS 단계에서 결정`.
    - JSON 외의 다른 가변 길이 type (varchar, string, BLOB, CLOB, JSON) 도 같은 misalignment 가 있는지 점검 필요: `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 가설을 대조해 작성한 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다.

### Summary

- **문제**: `unloaddb` 가 OOS 로 저장된 JSON 컬럼을 읽을 때 type 바이트가 알 수 없는 값이라 `db_json_deserialize_doc_internal` 의 `default:` 분기에서 죽는다.
- **배경**: JSON 직렬화는 `[type:byte][payload]` 구조. OOS 로 빠진 JSON 페이로드를 OOS file 에 저장하고 inline OOS-OID 만 남기는 경로에서, payload 의 첫 바이트 (type) 가 어디에 있는지 write 와 read 가 어긋날 가능성.
- **변경 (예상)**: OOS 페이로드의 시작 위치를 type 바이트로부터로 일관되게 정렬하거나, `heap_record_replace_oos_oids` 의 복원 단계에서 type 바이트를 빠뜨리지 않도록 보정.
- **영향 범위**: OOS-eligible JSON 컬럼을 가진 모든 read 경로 (unloaddb, SELECT, replication). LOB/ELO 클러스터의 마지막 layer.

---

## Description

### 회귀의 위치

`cubrid unloaddb -S tdb1` 의 row 추출 과정 중 JSON 컬럼 값을 역직렬화하는 단계.

`src/compat/db_json.cpp:4220-4260` 의 `db_json_deserialize_doc_internal`:

```cpp
static int
db_json_deserialize_doc_internal (OR_BUF *buf, JSON_VALUE &value,
                                  JSON_PRIVATE_MEMPOOL &doc_allocator)
{
  int rc = NO_ERROR;
  int type = or_get_int (buf, &rc);
  if (rc != NO_ERROR)
    {
      return rc;
    }

  switch (type)
    {
    case DB_JSON_INT:    rc = db_json_unpack_int_to_value (buf, value);    break;
    case DB_JSON_BIGINT: rc = db_json_unpack_bigint_to_value (buf, value); break;
    case DB_JSON_DOUBLE: rc = db_json_unpack_double_to_value (buf, value); break;
    case DB_JSON_STRING: rc = db_json_unpack_string_to_value (buf, value, doc_allocator); break;
    case DB_JSON_BOOL:   rc = db_json_unpack_bool_to_value (buf, value);   break;
    case DB_JSON_NULL:   value.SetNull (); break;
    case DB_JSON_OBJECT: rc = db_json_unpack_object_to_value (buf, value, doc_allocator); break;
    case DB_JSON_ARRAY:  rc = db_json_unpack_array_to_value (buf, value, doc_allocator); break;
    default:
      /* we shouldn't get here */
      assert (false);              /* <-- HIT */
      return ER_FAILED;
    }
  ...
}
```

`type = or_get_int (buf, ...)` 가 8 가지 유효 enum 중 하나가 아닌 값을 읽으면 `default:` 의 `assert(false)` 가 발동한다.

### 왜 OOS 와 관련 있는가

`bigPageSize` 의 schema 에는 `j JSON` 컬럼이 마지막에 있다. `init.sql` 의 첫 row 는 `j = repeat(@j, 780)` (수 MB JSON) 이라 OOS 임계치를 넘어 OOS file 로 빠진다. heap record 본문에는 16바이트 OOS-OID (+ 8바이트 length, 합 18바이트) 만 남는다.

`unloaddb` 가 row 를 읽을 때:

1. `xlocator_fetch_all` -> `heap_next` -> `heap_scan_get_visible_version` -> `heap_get_visible_version_internal` 로 들어가서 record_type 별 분기.
2. `REC_HOME` / `REC_RELOCATION` / `REC_BIGONE` 어느 케이스든 `heap_record_replace_oos_oids` 가 OOS-OID 자리에 OOS file 의 실제 payload 를 inline 으로 채워 넣는다 (CBRD-26813 의 fix 가 BIGONE 케이스를 추가했다).
3. 이렇게 expand 된 record 를 `desc_disk_to_obj` -> `get_desc_current` 가 컬럼별로 walk 하면서 type 별 `data_readval` 호출.
4. JSON 컬럼의 `data_readval` 가 `db_json_deserialize` -> `db_json_deserialize_doc_internal` 호출.
5. 이 시점 buffer cursor 가 JSON value 의 시작 위치를 가리켜야 하는데, OOS 복원이 잘못된 위치에 시작점을 두면 type 바이트가 엉뚱한 값으로 읽히고 `default:` 에서 죽는다.

### 가능한 원인

| 가설 | 검증 방법 |
|---|---|
| OOS file 에 type 바이트 없이 payload 만 저장됐고, expand 시 type 바이트를 빠뜨림 | `oos_read` 로 받은 buffer 의 첫 바이트가 type 인지 확인 |
| OOS 복원이 길이 prefix 를 잘못 넣어 cursor 가 4 바이트 어긋남 | expand 후 record 의 JSON 컬럼 위치에서 처음 16 바이트를 hex dump 해서 정상 build 와 비교 |
| Variable offset table 의 JSON 컬럼 entry 가 alignment padding 누락 | offset 값과 실제 위치 비교 |
| BIGONE 케이스의 CBRD-26813 fix 가 type 바이트를 누락 | `bb1f60687` 의 patch 가 적용된 상태에서만 발생하는지 확인 (단독 발생인지 sibling fix 와 같이 일어나는지) |

### 스택 (예상)

직접 gdb 로 잡지 못했지만 stack 은 다음 흐름:

```
db_json_deserialize_doc_internal     db_json.cpp:4260
  db_json_deserialize                db_json.cpp:~4270
    mr_data_readval_json             object_primitive.c:~?
      readval_*                      object_primitive.c
        data_readval                 (pr_type)
          get_desc_current           load_object.c:657
            desc_disk_to_obj         load_object.c:968
              unload_printer         unload_object.c:1360
                unload_extractor_thread unload_object.c:1432
```

분석 단계 1단계에서 정확한 스택을 gdb 로 잡아 확정한다.

## Test Build

- `CUBRID 11.5.0 (11.5.0.2328-8d7b97a) (64bit debug build for Linux)`.
- 브랜치: `vk/cbrd-26814-oos-write-bounds-check` (HEAD `bb1f60687`).
- 자매 패치 두 개가 모두 적용된 상태에서 재현:
    - `bb1f60687 [CBRD-26814] Check OOS inline metadata fit at value-area position`
    - `6087ed163 [CBRD-26813] Expand OOS OIDs after REC_BIGONE reassembly`
- OS: RHEL 9.6 (5.14.0-570.30.1.el9_6.x86_64).

## Repro

```bash
cubrid service start
cubrid deletedb tdb1 2>/dev/null
cubrid createdb -r tdb1 en_US

CASES=/home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
csql -udba -S -i ${CASES}/createtbl.sql tdb1
csql -udba -S -i ${CASES}/init.sql tdb1     # OK with CBRD-26814: 256 rows
csql -udba -S -c "select count(*) from t;" tdb1   # 256

# 실패 단계:
cubrid unloaddb -S -O /tmp/repro tdb1
```

결과:

```
cubrid: src/compat/db_json.cpp:4260:
  int db_json_deserialize_doc_internal(OR_BUF *, JSON_VALUE &,
  JSON_PRIVATE_MEMPOOL &): Assertion `false' failed.
```

`tdb1_objects` 에 1 row 만 추출되고 SIGABRT.

### TBD - 최소 repro

`init.sql` 첫 row 만 들어가도 재현된다 (그 row 가 OOS 로 빠지는 JSON 컬럼을 포함하므로). 더 작은 schema 로 좁히는 시도는 분석 단계의 첫 작업:

```bash
csql -udba -S tdb1 -c "
create table t (c1 varchar(5000), j json);
insert into t values (repeat('x', 5000), '{\"k\":\"v\"}');
"
cubrid unloaddb -S tdb1
```

위가 재현되면 단위 테스트화 가능.

## Expected Result

```
$ cubrid unloaddb -S -O /tmp/repro tdb1
... (no abort) ...
$ grep -c "^%id" /tmp/repro/tdb1_objects
256
```

## Actual Result

`unloaddb` 가 첫 row 의 JSON 컬럼 역직렬화에서 SIGABRT. `tdb1_objects` 에 1 row 만 기록된 채 종료.

## Additional Information

### 패치 스택과의 관계

본 sub-task 는 LOB/ELO 클러스터 회귀의 3 layer 중 마지막이다.

| Layer | Sub-task | 단계 | 위치 |
|---|---|---|---|
| 1 | CBRD-26814 | WRITE | `heap_attrinfo_transform_variable_to_disk` (`heap_file.c:13013`) — OOS metadata bounds check |
| 2 | CBRD-26813 | READ (HEAP) | `heap_get_visible_version_internal` REC_BIGONE 분기 (`heap_file.c:7934`) — OOS expansion |
| **3** | **CBRD-26815 (본)** | READ (JSON) | `db_json_deserialize_doc_internal` (`db_json.cpp:4260`) — OOS JSON 페이로드 type 바이트 |

세 layer 모두 풀려야 `bigPageSize.sh` 가 OK 로 통과.

### 영향 클러스터

CBRD-26660 의 LOB/ELO 클러스터 9 건. 본 회귀가 풀리는지에 따라 클러스터 전체가 같이 풀리는지 / 별도 fix 가 더 필요한지 결정.

## Implementation

### 1단계: stack 확정

`cubrid unloaddb -S tdb1` 를 gdb 로 실행해 정확한 호출 스택을 잡는다.

```
break db_json.cpp:db_json_deserialize_doc_internal
run unloaddb -S tdb1
# 진입 시점에 buf->ptr 의 첫 바이트, 그 직전 4 바이트, 그 다음 16 바이트를 hex dump
print (int) *(char*)buf->ptr
print/x *((char*)buf->ptr-4)@20
backtrace
```

`buf->ptr` 의 첫 바이트가 8 가지 valid enum (0-7 정도의 작은 값) 중 하나가 맞는지 확인.

### 2단계: write 측 layout 확인

`init.sql` 첫 row 의 JSON 컬럼이 OOS 로 저장되는 시점에 OOS file 에 무엇이 들어가는지 확인.

```
break oos_insert
# is_oos=true 이고 column type 이 JSON 인 호출에서 src buffer 의 첫 16 바이트 hex dump
```

저장된 바이트의 첫 바이트가 type 바이트 (예: `DB_JSON_OBJECT = 2`) 가 맞는지 확인.

### 3단계: 가설별 fix

- **가설 A**: OOS file 에 type 바이트가 누락된 상태로 저장 -> 저장 측에서 type 을 inline 으로 넣도록 fix (`mr_data_writeval_json` 또는 oos write 경로).
- **가설 B**: OOS file 에는 type + payload 가 정상이지만 `heap_record_replace_oos_oids` 가 payload 만 inline 으로 복원 -> 복원 측에 type 바이트도 같이 복원하도록 fix.
- **가설 C**: alignment / offset 보정 누락 -> offset 계산 fix.

가설은 1, 2단계의 hex dump 결과로 한 가지로 좁혀진다.

### 4단계: 검증

```bash
# 본 sub-task 단독
cubrid unloaddb -S -O /tmp/repro tdb1
grep -c "^%id" /tmp/repro/tdb1_objects     # 256 가 나와야 함

# 클러스터 전체와 함께 — bigPageSize.sh 가 OK 가 되는지
just shell-debug /home/vimkim/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize
```

### 5단계: 단위 테스트 (TBD)

`unit_tests/` 에 OOS-eligible JSON 컬럼의 write-read round-trip 단위 테스트 추가. 그 row 가 BIGONE 인 경우와 REC_HOME 인 경우 양쪽 cover.

## Acceptance Criteria

- [ ] `cubrid unloaddb -S tdb1` 가 SIGABRT 없이 256 row 추출.
- [ ] CBRD-26813 + CBRD-26814 + 본 sub-task 패치가 모두 적용된 상태에서 `bigPageSize.sh` 가 OK 로 통과.
- [ ] CBRD-26660 의 LOB/ELO 클러스터 9 건 일괄 재실행 결과를 본 sub-task 댓글에 표로 기록.
- [ ] 1단계의 stack 과 hex dump 결과가 댓글에 기록되어 가설 A/B/C 중 어느 것이 맞았는지 명시.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] PR merge.
- [ ] CBRD-26660 의 클러스터 1 표에 본 sub-task 번호 기록.

## 참고 코드

| 파일:줄 | 역할 |
|---|---|
| `src/compat/db_json.cpp:4260` | **assert 사이트**. JSON type 바이트 unknown 시 default 분기. |
| `src/compat/db_json.cpp:4220-4260` (`db_json_deserialize_doc_internal`) | JSON 역직렬화 switch — type 바이트 검사. |
| `src/compat/db_json.cpp:~677` (`db_json_deserialize`) | 외부에서 부르는 entry. |
| `src/storage/heap_file.c:7975` (`heap_record_replace_oos_oids`) | OOS expansion. JSON inline 복원 정확성 점검 대상. |
| `src/storage/oos_file.cpp:1372` (`oos_read`) | OOS file 에서 페이로드 읽기. 저장 contract 점검 대상. |
| `src/object/object_primitive.c` (JSON read/write) | JSON 컬럼이 OOS 로 분기되는 지점. |

## Remarks

- 부모 epic: CBRD-26583 (OOS M2 epic).
- 자매 sub-task:
    - CBRD-26813 (REC_BIGONE OOS expansion, READ HEAP) — `vk/cbrd-26813-oos-bigone-expand` commit `6087ed163`.
    - CBRD-26814 (OOS WRITE bounds-check) — `vk/cbrd-26814-oos-write-bounds-check` commit `bb1f60687`.
- 동반 sub-task: CBRD-26660 (M2 매뉴얼 회귀 분류).
- 본 회귀가 풀려야 LOB/ELO 클러스터 전체가 검증 가능.
