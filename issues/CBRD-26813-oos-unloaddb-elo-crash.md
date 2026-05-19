# [OOS] [M2] unloaddb 가 OOS BLOB 컬럼을 만나면 peekmem_elo 에서 SIGSEGV

## Issue Triage

**이슈 수행 목적**: BLOB/CLOB 컬럼을 가진 큰 레코드를 `unloaddb` 로 추출할 때 `peekmem_elo` 의 `or_get_int` 에서 죽는 회귀를 고친다. shell 회귀 `bigPageSize.sh` 가 다시 통과한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `feat-oos-m2-manual` 빌드 `11.5.0.2328-8d7b97a` 에서 `cubrid unloaddb -S tdb1` 가 SIGSEGV. 스택 frame #0~#8 은 `or_get_int` (`object_representation.h:1727`) <- `peekmem_elo` (`object_primitive.c:5842`) <- `mr_data_readval_blob` <- `readval_elo_with_type` <- `get_desc_current` (`load_object.c`, 호출 site `:657`, 함수 정의 `:568`) <- `desc_disk_to_obj` (`:968`) <- `unload_printer` <- `unload_extractor_thread` (`unload_object.c:1407`). 256 row 중 1 row 만 추출된 뒤 죽는다.
- **영향**: shell 회귀 `cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/bigPageSize.sh` 가 NOK. 같은 근원으로 묶일 가능성이 있는 LOB/ELO 클러스터 8건 (#2 `cbrd_25446`, #3 `bug_bts_10290`, #4 `bug_bts_7596`, #12·14 `bug_bts_16011`, #17 `cbrd_23349`, #19 `bug_bts_5596`, #22 `bug_xdbms3947`) 도 같이 막혀 있을 가능성이 높다 (CBRD-26660 의 클러스터 1 분류 참조). M2 머지 게이트 차단.

**이슈 수행 방안**:

- **가장 유력한 가설** (코드 검증 후): `heap_get_visible_version_internal` 의 `case REC_BIGONE` (`heap_file.c:7934`) 이 `heap_get_bigone_content` 만 호출하고 `heap_record_replace_oos_oids` 를 부르지 않는다. 같은 dispatch 의 `REC_HOME` (`:7954`), `REC_RELOCATION` (`:7932`) 는 OOS 해소 호출이 있다. 따라서 record 가 BIGONE (overflow 다중 페이지) 으로 분리되었고 동시에 OOS-OID 가 인라인된 경우, expansion 없이 client 로 raw record 가 넘어가서 `peekmem_elo` 가 OOS-OID 의 16 바이트를 ELO 헤더로 오독하고 죽는다.
- **수정 위치**: `src/storage/heap_file.c:7934-7937` 의 `REC_BIGONE` 분기. `heap_get_bigone_content` 호출 결과가 `S_SUCCESS` 인 경우 이어서 `heap_record_replace_oos_oids (thread_p, context)` 를 호출한다. 기존 `REC_HOME` / `REC_RELOCATION` 분기와 동일 패턴을 따른다.
- **검증 기준**: `bigPageSize.sh` 가 OK 로 통과 + CBRD-26660 의 LOB/ELO 클러스터 8건 일괄 재실행해 같이 풀리는지 확인. 풀리는 항목은 본 이슈로 닫고, 안 풀리면 별도 sub-task 로 분리.
- **TBD**:
    - 최소 repro 좁히기 (현재 `varchar(3000) + blob` 1 row 만으로는 재현 안 됨, BIGONE 임계치 또는 multi-thread 조건 필요): `TBD - ANALYSIS 단계에서 결정`.
    - REC_BIGONE 외에 다른 dispatch 분기에도 같은 누락이 있는지 (`heap_file.c:6225`, `:9949`, `:16312` 등 12 개 REC_BIGONE 사이트): `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 실패 로그를 분석해 작성한 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다.

### Summary

- **문제**: `heap_get_visible_version` 의 `REC_BIGONE` 분기에서 OOS 해소가 빠져, BIGONE+OOS record 가 raw 상태로 client 에 넘어가 `peekmem_elo` 가 OOS-OID 를 ELO 헤더로 오독하고 죽는다.
- **배경**: OOS M2 가 가변 컬럼을 외부 OOS 파일로 빼고 record 변수 영역에 16바이트 OOS-OID 를 남긴다. `heap_record_replace_oos_oids` (`heap_file.c:7975`) 가 client 로 record 를 넘기기 전에 OOS-OID 를 inline value 로 되돌리는 역할인데, `REC_BIGONE` 만 이 호출에서 빠져 있다.
- **변경**: `REC_BIGONE` case 에 `heap_record_replace_oos_oids` 호출을 추가한다. signature `(THREAD_ENTRY *, HEAP_GET_CONTEXT *)` 는 이미 인접 case 들과 같은 위치에서 호출되고 있어 추가 작업 없이 끼울 수 있다.
- **영향 범위**: BLOB / CLOB 또는 큰 가변 컬럼을 가진 모든 테이블 — record 가 BIGONE 임계치를 넘기는 순간 영향. 정상 작동하는 master 빌드 대비 회귀.

---

## Description

OOS M2 작업 (`feat-oos-m2-manual` 브랜치) 으로 OOS 가 활성화된 뒤, BLOB / CLOB 컬럼 + 큰 var 컬럼 다수를 가진 record 를 `unloaddb` 로 추출할 때 SIGSEGV.

### 콜 그래프 검증

`unloaddb` 의 server-side fetch 는 다음 경로를 탄다:

```
unload_extractor_thread (unload_object.c:1407)
  └── unload_fetcher → locator_fetch_all (CS) → xlocator_fetch_all (locator_sr.c:2775)
       └── heap_next (heap_file.c:20335, COPY mode)
            └── heap_next_internal (heap_file.c:8258)
                 └── heap_scan_get_visible_version (heap_file.c:26558)
                      └── heap_scan_get_visible_version_impl (..., expand_oos=true) (heap_file.c:26476)
                           └── 만약 record 가 OOS 를 포함하면 shortcut 우회 후
                                heap_get_visible_version_internal (...) 호출
                                 └── case 분기 (heap_file.c:7852)
                                      ├── REC_RELOCATION → heap_record_replace_oos_oids (line 7932)  [OK]
                                      ├── REC_BIGONE     → heap_get_bigone_content (line 7935)       [BUG: OOS 호출 없음]
                                      └── REC_HOME       → heap_record_replace_oos_oids (line 7954)  [OK]
```

`heap_init_get_context` 가 `context->expand_oos = true` 를 기본값으로 세팅하고 (`heap_file.c:26978`), `heap_scan_get_visible_version_impl` 의 shortcut (`:26502`) 도 OOS 포함 record 에 대해서는 우회되어 full path 로 떨어진다 (`:26498-26506` 의 주석 참고). 즉 `REC_HOME` / `REC_RELOCATION` 경로의 OOS 해소는 정상 작동한다. **누락은 `REC_BIGONE` 한 곳뿐.**

### 왜 BIGONE 인가

OOS 와 BIGONE 은 모두 "record 가 한 페이지에 안 들어가는" 상황을 다룬다. OOS 는 가변 컬럼만 OOS 파일로 빼고 record 본문은 한 페이지에 유지, BIGONE 은 record 전체를 다중 페이지로 분리. 두 메커니즘은 상호 배타적이지 않다 — OOS 로 큰 var 컬럼을 빼낸 뒤에도 fixed 컬럼 + bitmap + 남은 small var 컬럼 + bound bits 의 합이 페이지 페이로드 한계를 넘으면 BIGONE 으로 떨어진다.

`bigPageSize.sh` 의 schema 는 fixed 컬럼 14 개 (id, col1..6, d1..8, b1, e enum) + var 컬럼 11 개 (c1 char(4), c2 varchar(10757), c3 string, cl clob, bl blob, s1..3 collections, j json) + bound bits. fixed 만으로도 100+ B 이고, var 의 일부 (c1, c3 가 작은 경우) 가 OOS 임계치 512B 를 넘지 못해 inline 으로 남으면 record 본문이 페이지 페이로드 (DB_PAGESIZE = 16K 기준) 까지 채워질 수 있다. 4K page 면 더 쉽게 BIGONE.

### 크래시 메커니즘

`heap_get_bigone_content` 는 overflow 페이지들을 모아 full record bytes 를 reassemble 해서 `context->recdes_p` 에 넣고 `S_SUCCESS` 를 반환한다. 그 record 는 이미 OOS-OID 가 인라인된 raw 상태다. `REC_BIGONE` case 가 그 뒤에 `heap_record_replace_oos_oids` 를 부르지 않으므로, raw 상태의 record 가 그대로 `xlocator_fetch_all` 의 copyarea 에 들어가 client 로 넘어간다.

client 측 `unload_printer` -> `desc_disk_to_obj` -> `get_desc_current` 가 record 의 variable offset table (VOT) 을 walk 할 때 `OR_VAR_BIT_OOS` 를 검사하지 않고 (`load_object.c:633-660` 부근, `vars[j]` 계산이 `OR_GET_VAR_OFFSET` 마스킹만 함), 16바이트 OOS-OID 슬롯의 길이만큼 `data_readval` 을 호출한다. BLOB type 의 `data_readval` (`mr_data_readval_blob` -> `readval_elo_with_type` -> `peekmem_elo`) 는 `or_get_bigint` 로 첫 8바이트를 `size` 로 읽고, `or_get_int` 로 다음 4바이트를 `locator_len` 으로 읽는다. OOS-OID 구조 `[volid:2 | pageid:4 | slotid:2 | full_length:8]` 의 임의 값이 `locator_len` 으로 해석되고, `or_advance (buf, locator_len)` 가 record 범위를 벗어나 다음 `or_get_int` 에서 SIGSEGV.

## Test Build

- `CUBRID 11.5.0 (11.5.0.2328-8d7b97a) (64bit debug build for Linux)`
- 브랜치: `feat-oos-m2-manual` (commit `8d7b97a88`)
- OS: RHEL 9.6 (5.14.0-570.30.1.el9_6.x86_64)

## Repro

### 전제

`cubrid-testcases-private-ex` 리포가 CTP 환경에 클론돼 있고 `${CTP}` 환경 변수가 설정돼 있어야 한다. 디버그 빌드된 본 브랜치의 CUBRID 가 `$PATH` 에 있고 `cubrid service start` 가 가능해야 한다.

### 단계

```bash
cd ${CTP}/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
. ${CTP}/shell/init_path/init.sh && bash bigPageSize.sh
```

핵심 단계만 따로 실행:

```bash
cd /tmp/repro && cubrid service start
cubrid deletedb tdb1 2>/dev/null
cubrid createdb -r tdb1 en_US

CASES_DIR=${CTP}/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
csql -udba -S tdb1 -i ${CASES_DIR}/createtbl.sql
csql -udba -S tdb1 -i ${CASES_DIR}/init.sql

# 실패 단계:
cubrid unloaddb -S tdb1
```

핵심 스키마 (`createtbl.sql` 발췌):

```sql
CREATE TABLE t (
  id INT AUTO_INCREMENT,
  col1 SMALLINT, col2 INT, col3 BIGINT,
  col4 NUMERIC(4,4), col5 FLOAT, col6 DOUBLE,
  d1 DATE, d2 TIME, d3 TIMESTAMP, d4 DATETIME,
  d5 TIMESTAMPLTZ, d6 TIMESTAMPTZ, d7 DATETIMELTZ, d8 DATETIMETZ,
  b1 BIT, c1 CHAR(4),
  c2 VARCHAR(10757),
  c3 STRING,
  e ENUM ('red', 'yellow', 'blue', 'green'),
  cl CLOB,
  bl BLOB,
  s1 SET (CHAR(1)), s2 MULTISET (CHAR(1)), s3 LIST (CHAR(1)),
  j JSON
);
```

`init.sql` 은 위 25 컬럼에 `c2 = repeat(@j_json,780)`, `bl = BIT_TO_BLOB(X'000001')` 등을 넣고 1 row 를 만든 뒤 8 번 `INSERT INTO t SELECT * FROM t` 로 256 row 로 부풀린다.

### TBD - 최소 repro

`varchar(3000) + blob` 1 row 의 단순 테이블로 시도했으나 SIGSEGV 가 재현되지 않았다 (16KB page + SA mode + default thread count = 1). 재현에는 (a) record 가 REC_BIGONE 으로 넘어가는 BIGONE 임계치, (b) unloaddb 의 `g_multi_thread_mode` 발동 조건이 같이 필요해 보인다. 분석 단계에서 최소 repro 를 좁혀 단위 테스트화하는 것이 첫 작업.

## Expected Result

```
$ cubrid unloaddb -S tdb1
... (no crash) ...
$ wc -l tdb1_objects
... (256 row 분량의 데이터) ...
```

## Actual Result

`cubrid unloaddb -S tdb1` 가 SIGSEGV 로 죽고 core dump 가 생성된다. CI 산출물 stack digest (jenkins build 의 line 번호 기준):

```
#0  or_get_int             src/base/object_representation.h:1727
#1  peekmem_elo            src/object/object_primitive.c:5880
#2  readval_elo_with_type  src/object/object_primitive.c:5999
#3  mr_data_readval_blob   src/object/object_primitive.c:6021
#4  pr_type::data_readval  src/object/object_primitive.h:566
#5  get_desc_current       src/loaddb/load_object.c:657   (per-attribute data_readval call site)
#6  desc_disk_to_obj       src/loaddb/load_object.c:968
#7  unload_printer         src/executables/unload_object.c:1360
#8  unload_extractor_thread src/executables/unload_object.c:1432
#9  start_thread           <EXTERNAL LIBRARY>
#10 clone                  <EXTERNAL LIBRARY>
```

본 브랜치 HEAD 기준 line 번호: `peekmem_elo:5842`, `readval_elo_with_type:5968`, `mr_data_readval_blob:6018`. `get_desc_current` 함수 자체는 `load_object.c:568` 에 정의되고, stack frame #5 의 `:657` 은 함수 안의 per-attribute `att->type->data_readval` 호출 위치.

`tdb1_objects` 파일에는 1 row 만 기록되고 추출이 중단된다.

## Additional Information

### 관련 회귀 (LOB/ELO 클러스터)

| # | Test | 증상 |
|---|---|---|
| 1 | `bigPageSize.sh` | 본 이슈 — SIGSEGV. |
| 2 | `cbrd_25446.sh` | LOB 경로 재배치 후 `SELECT` 결과 *External file `ces_*` was not found*. |
| 3 | `bug_bts_10290.sh` | `CAST(... AS CLOB)` 가 *external storage path invalid* 에러. |
| 4 | `bug_bts_7596.sh` | CLOB/BLOB cast 24개 변형 동일 에러. |
| 12, 14 | `bug_bts_16011.sh` (SA/CS) | `loaddb` OK 인데 read 시 `ces_*` not found. |
| 17 | `cbrd_23349.sh` | BLOB+CLOB+JSON+큰 CHAR 혼합 테이블, *External file 'ces_433/...' not found*. |
| 19 | `bug_bts_5596.sh` | `TRUNCATE` 후 LOB 파일 잔존 (경로 `_25_unstable/`, master HEAD 재현 확인 후 판정). |
| 22 | `bug_xdbms3947.sh` | `INSERT INTO ... clob ...` 후 `lob-base-path` 에 파일 0개. |

본 이슈의 fix 가 BIGONE + OOS 만 풀고 나머지 (#3, 4, 22 의 INSERT 측 LOB-locator 경로 등) 는 별개 fix 를 요구할 수 있다. 클러스터 전체 회귀 재실행이 acceptance 항목.

### 동일 패턴 누락 가능성 점검

`heap_get_visible_version_internal` 외에 `REC_BIGONE` 분기가 있는 dispatch 12 곳 (`heap_file.c:6225, 7685, 7828, 7852, 9949, 16312, 17306, 17371, 17374` 등) 도 OOS-aware 가 필요한지 검토. 본 이슈 범위에서는 `:7934` 하나만 고치고 나머지는 grep 결과를 댓글로 정리한 뒤 별도 sub-task 로 분리 (Triage 의 TBD 항목).

## Implementation

### 1단계: hypothesis 직접 확인

디버그 빌드의 `cub_admin` 에 `gdb` attach. break point:

```
break heap_file.c:heap_get_visible_version_internal
break heap_file.c:heap_record_replace_oos_oids
break object_primitive.c:peekmem_elo
```

`bigPageSize.sh` 의 `cubrid unloaddb -S tdb1` 를 실행해, 첫 번째 SIGSEGV 직전의 record 가:

- `heap_get_visible_version_internal` 의 어느 case 분기로 진입했는지 (`context->record_type` 값) 확인 — `REC_BIGONE` 이면 가설 확정.
- `heap_record_replace_oos_oids` 가 호출 안 됐는지 (break 가 발동 안 함) 확인.
- `peekmem_elo` 진입 시점 `buf->ptr` 의 32 바이트를 hex dump 해 OOS-OID 의 `[volid:2 | pageid:4 | slotid:2 | full_length:8]` 형식인지 (ELO 헤더가 아닌지) 확인.

### 2단계: 수정

`src/storage/heap_file.c:7934-7937` 의 `REC_BIGONE` 분기를 다음 패턴으로 바꾼다.

```c
case REC_BIGONE:
  {
    SCAN_CODE scan = heap_get_bigone_content (thread_p, scan_cache_p, context->ispeeking,
                                              &context->forward_oid, context->recdes_p);
    if (scan != S_SUCCESS)
      {
        return scan;
      }
    return heap_record_replace_oos_oids (thread_p, context);
  }
```

`heap_record_replace_oos_oids` 는 내부에서 `heap_recdes_contains_oos (rec)` 와 `context->expand_oos` 를 모두 검사하므로 OOS 가 없는 BIGONE 에서는 그대로 `S_SUCCESS` 반환 (no-op). 따라서 무조건 호출해도 안전하다.

### 3단계: 회귀 재실행

```bash
# 본 이슈 단독
bash ${CTP}/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/bigPageSize.sh

# 클러스터 1 전체
for tc in bigPageSize cbrd_25446 bug_bts_10290 bug_bts_7596 bug_bts_16011 cbrd_23349 bug_bts_5596 bug_xdbms3947; do
    # 각 테스트 실행, OK/NOK 집계
done
```

`bigPageSize` 가 OK 가 되면 본 이슈는 통과. 다른 LOB/ELO 회귀가 같이 풀리는지에 따라 클러스터 1 의 다른 항목 close-out 여부 결정.

### 4단계: 단위 테스트 (TBD)

`unit_tests/` 에 OOS+BIGONE record 의 round-trip 단위 테스트 추가. 분석 단계에서 최소 repro 가 좁혀지면 그 시나리오를 단위 테스트화. 형식은 기존 `unit_tests/storage/` 하위의 heap 테스트 참고.

## Acceptance Criteria

- [ ] `bigPageSize.sh` 가 OK 로 통과 (256 row 모두 unload + 이어지는 `loaddb -C` 도 OK).
- [ ] 1단계의 gdb 검증으로 `REC_BIGONE` 분기가 OOS expansion 을 건너뛰는 것이 확인된다 (또는 다른 분기로 판명되면 그에 맞게 fix 위치 갱신).
- [ ] CBRD-26660 의 LOB/ELO 클러스터 9 건 일괄 재실행 결과를 본 이슈 댓글에 표로 기록 — 같이 풀리는 항목은 close-out, 남는 항목은 별도 sub-task 로 분리.
- [ ] `REC_BIGONE` 분기의 다른 dispatch site 12 곳 grep 결과를 댓글에 기록, 같은 누락이 더 있으면 별도 sub-task.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] PR merge.
- [ ] CBRD-26660 의 클러스터 1 표에 본 티켓 번호가 채워진다.

## 참고 코드

| 파일:줄 | 역할 |
|---|---|
| `src/storage/heap_file.c:7934-7937` (`case REC_BIGONE`) | **수정 대상**. OOS expansion 호출 누락. |
| `src/storage/heap_file.c:7975` (`heap_record_replace_oos_oids`) | 추가 호출할 함수. signature `(THREAD_ENTRY *, HEAP_GET_CONTEXT *)`, 내부에서 `expand_oos` 와 `heap_recdes_contains_oos` 모두 검사. |
| `src/storage/heap_file.c:7932, 7954` | 동일 dispatch 의 `REC_RELOCATION`, `REC_HOME` 분기 — 호출 패턴 참고. |
| `src/storage/heap_file.c:26476` (`heap_scan_get_visible_version_impl`) | scan 진입점. `expand_oos=true` 가 default 로 propagate 됨. |
| `src/storage/heap_file.c:26978` (`heap_init_get_context`) | `context->expand_oos = true` default 세팅. |
| `src/transaction/locator_sr.c:2906` (`xlocator_fetch_all` scan loop) | server-side unloaddb fetch entry. |
| `src/executables/unload_object.c:1407` (`unload_extractor_thread`) | client-side unloaddb thread. |
| `src/executables/load_object.c:568, 633-660` (`get_desc_current`) | variable-area 컬럼 walker. OOS 비-검사 — 서버 측 expansion 에 의존. |
| `src/object/object_primitive.c:5842` (`peekmem_elo`) | 크래시 사이트. `object_primitive.c` 전체에 `OOS` 참조 0건 (서버가 expansion 을 해 줘야만 정상 작동). |
| `src/base/object_representation.h:441` (`OR_VAR_BIT_OOS`) | OOS 비트 매크로. |

## Remarks

- 부모 epic: CBRD-26583 (OOS M2 epic).
- 동반 sub-task: CBRD-26660 (M2 매뉴얼 회귀 분류).
- 분석 원본: `feat-oos-m2-manual` 브랜치의 `failed-tc-report.md`.
- 본 이슈는 LOB/ELO 클러스터 9 건의 머지 게이트 후보. fix 후 클러스터 전체가 같이 풀리는지에 따라 나머지 회귀의 별도 분기 여부 결정.
