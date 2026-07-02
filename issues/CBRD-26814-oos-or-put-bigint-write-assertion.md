# [OOS] [M2] OOS inline stub 공간 검사 위치 오류로 INSERT 계열 크래시가 발생한다

## Issue Triage

**이슈 수행 목적**: OOS inline stub을 heap record에 쓸 때 실제 쓰기 위치 기준으로 공간을 검사하도록 고친다. `bigPageSize.sh` 와 `bug_xdbms3693.sh` 가 `or_put_bigint` 또는 `or_put_oid` assert 없이 INSERT 경로를 통과해야 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | OOS Demotion이 발생한 row를 disk format으로 만들 때 16바이트 inline stub의 공간 검사를 record 앞쪽 cursor 기준으로 수행한다. `bigPageSize.sh` 는 `or_put_bigint`, `bug_xdbms3693.sh` 는 `or_put_oid` 에서 debug assert로 서버가 종료된다. |
| **TO-BE (목표 상태 / 기대 동작)** | inline stub이 실제로 기록되는 variable value area 기준으로 16바이트 여유를 확인하고, 부족하면 `S_DOESNT_FIT` 을 반환해 기존 resize-and-retry 흐름으로 복구한다. |
| **영향** | QA 실패 - OOS M2 manual run에서 `bug_xdbms3693` 서버 core가 발생하고, release 빌드에서는 같은 out-of-bounds write가 assert 없이 heap 메모리를 오염시킬 수 있다. |

**이슈 수행 방안**: `heap_attrinfo_transform_variable_to_disk` 의 OOS 분기에서 `OR_OOS_INLINE_SIZE` 검사 기준을 `buf->ptr` 가 아니라 `*ptr_varvals` 로 바꾼다. `bigPageSize.sh` 기존 재현과 `bug_xdbms3693.sh` manual 재현을 모두 회귀 검증에 포함한다. BLOB/CLOB locator를 OOS 후보에서 제외할지는 이번 bounds-check 필수 수정과 분리된 storage policy 판단이므로 `TBD - 합의 미확인` 으로 둔다.

---

## AI-Generated Context

> 아래는 AI 가 코드와 로컬 분석 자료를 대조해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 요약

- **변경 범위 / 영향**: 핵심 수정 파일은 `src/storage/heap_file.c` 다. `src/base/object_representation.h` 의 OOS inline layout 정의와 debug assert는 참조 대상이며, on-disk format 자체는 바꾸지 않는다.
- **호환성**: heap record 안의 OOS inline stub은 계속 `OR_OOS_INLINE_SIZE` 16바이트를 사용한다. WAL(Write-Ahead Logging) format, OOS file format, replication log format 변경은 필요하지 않다.
- **검증 표면**: INSERT, INSERT ... SELECT, UPDATE처럼 `heap_attrinfo_transform_variable_to_disk` 를 거쳐 OOS inline stub을 쓰는 경로가 대상이다.

## Description

OOS (Out-of-row Storage - heap의 큰 가변 컬럼을 OOS file로 분리하고 heap record에는 OOS OID와 길이만 남기는 저장 방식)는 write 시점에 큰 가변 컬럼을 OOS record로 보낸다. heap record 안에는 원래 값 대신 16바이트 inline stub이 남는다.

```
OOS inline stub
  OOS OID        8 bytes
  full_length    8 bytes
  ----------------------
  total          16 bytes = OR_OOS_INLINE_SIZE
```

heap record builder는 가변 컬럼 하나를 쓸 때 두 위치를 오간다.

| cursor | 의미 |
|--------|------|
| `buf->ptr` | 현재 작업 cursor다. VOT(Variable Offset Table - 가변 컬럼의 시작 offset 표)를 쓸 때는 record 앞쪽을 가리키고, 값을 쓸 때는 뒤쪽으로 이동한다. |
| `*ptr_varvals` | variable value area 전용 cursor다. 다음 가변 값 또는 OOS inline stub이 실제로 기록될 위치를 가리킨다. |

현재 OOS 분기는 VOT entry를 쓴 직후의 `buf->ptr` 로 16바이트 여유를 검사한다. 이때 `buf->ptr` 은 record 앞쪽 VOT 근처에 남아 있다. 그 다음에야 `buf->ptr = *ptr_varvals` 로 실제 값 영역으로 이동하고 `or_put_oid`, `or_put_bigint` 를 호출한다.

```
heap_attrinfo_transform_variable_to_disk

  [1] buf->ptr = VOT entry 위치
  [2] VOT entry 기록
  [3] buf->ptr + OR_OOS_INLINE_SIZE 로 공간 검사     <- record 앞쪽 기준
  [4] buf->ptr = *ptr_varvals                         <- 실제 write 위치로 이동
  [5] or_put_oid / or_put_bigint                      <- record 뒤쪽에 write
```

검사 위치와 쓰기 위치가 다르므로, 실제 값 영역 끝에 공간이 부족해도 [3]은 통과한다. 이 경로는 원래 `S_DOESNT_FIT` 을 반환해야 한다. `heap_attrinfo_transform_to_disk_internal` 은 이 값을 받으면 record buffer를 키워 처음부터 다시 조립한다. 그러나 잘못된 검사 때문에 retry 신호가 나오지 않고, debug 빌드에서는 `or_put_oid` 또는 `or_put_bigint` 의 assert가 마지막에 잡는다.

`bug_xdbms3693` 는 이 문제를 LOB locator drift로 드러낸다. BLOB/CLOB의 in-row 값은 LOB payload가 아니라 외부 LOB 파일을 가리키는 locator 문자열이다. `heap_attrinfo_transform_variable_to_disk` 의 LOB 분기는 write 중 `db_elo_copy_with_prefix` 로 새 locator를 만들고 DB_VALUE를 교체한다. 그러면 layout 산정 시점에 본 locator 길이와 실제 write 시점의 locator 길이가 달라질 수 있다.

```
layout 산정: 복사 전 locator 길이로 inline_size_after_oos 추정
record 작성: prefix가 붙은 새 locator를 DB_VALUE에 넣고 기록
결과: inline으로 남은 LOB locator들이 예상보다 길어져 *ptr_varvals가 더 빨리 전진
```

이 drift 자체는 `S_DOESNT_FIT` retry 계약 안에서 처리될 수 있다. 일반 non-OOS 값 쓰기 경로는 `buf->ptr = *ptr_varvals` 로 실제 쓰기 위치를 먼저 잡은 뒤 크기를 검사하므로 공간 부족을 정상적으로 반환한다. OOS inline stub 경로만 VOT 쪽 cursor로 검사했기 때문에 같은 계약에서 벗어났다.

`bigPageSize.sh` 의 기존 CBRD-26814 재현은 여러 OOS 컬럼의 16바이트 stub이 누적되다가 `or_put_bigint` 에서 assert가 났다. `bug_xdbms3693.sh` 의 manual 재현은 50개 BLOB + 50개 CLOB locator가 섞인 row에서 낮은 index의 inline LOB locator들이 drift를 만들고, 이후 OOS inline stub을 쓰는 index 47 부근에서 `or_put_oid` 가 assert로 종료됐다. 두 증상은 crash site만 다르고 같은 write-position bug다.

## Test Build

- 기존 CBRD-26814 재현: `CUBRID 11.5.0.2328-8d7b97a`, 64-bit debug build, RHEL 9.6.
- manual run 재현: `CUBRID 11.5.0.2434-4ddbc7c`, branch `feature/oos-m2`, 64-bit debug build. OS 상세는 `TBD - ANALYSIS 단계에서 결정`.

## Repro

### 기존 CBRD-26814 재현

```bash
cubrid service start
cubrid deletedb tdb1 2>/dev/null
cubrid createdb -r tdb1 en_US

TESTCASE_ROOT=/path/to/cubrid-testcases-private-ex
CASES="${TESTCASE_ROOT}/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases"

csql -u dba -S -i "${CASES}/createtbl.sql" tdb1
csql -u dba -S -i "${CASES}/init.sql" tdb1
csql -u dba -S -c "select count(*) from t;" tdb1
```

### 매뉴얼 run 추가 재현

`ctp.sh` 를 사용하는 경우 `shell_ci.conf` 의 scenario를 아래 test case로 좁힌 뒤 shell suite를 실행한다.

```text
cubrid-testcases-private-ex/shell/_06_issues/_10_2h/bug_xdbms3693/cases/bug_xdbms3693.sh
```

직접 실행할 경우 test case checkout 위치만 환경에 맞게 지정한다.

```bash
TESTCASE_ROOT=/path/to/cubrid-testcases-private-ex
bash "${TESTCASE_ROOT}/shell/_06_issues/_10_2h/bug_xdbms3693/cases/bug_xdbms3693.sh"
```

## Expected Result

```text
bigPageSize init.sql:
  - csql abort 없음
  - select count(*) from t; 결과가 256

bug_xdbms3693.sh:
  - server core 없음
  - client-side css_readn core 같은 2차 증상 없음
```

## Actual Result

기존 CBRD-26814 재현은 첫 INSERT 중 `or_put_bigint` assert로 종료된다.

```text
csql: src/base/object_representation.h:1745:
  int or_put_bigint(OR_BUF *, DB_BIGINT):
  Assertion `buf->ptr + OR_BIGINT_SIZE <= buf->endptr' failed.
```

manual run의 `bug_xdbms3693` 는 OOS inline stub의 OOS OID를 쓰는 중 `or_put_oid` assert로 서버 core가 발생한다.

```text
or_put_oid
heap_attrinfo_transform_variable_to_disk(... is_oos=true, oos_length=88, index=47 ...)
heap_attrinfo_transform_columns_to_disk
heap_attrinfo_transform_to_disk_internal
```

## Additional Information

### 크래시 위치가 둘로 보이는 이유

OOS inline stub은 `or_put_oid` 8바이트와 `or_put_bigint` 8바이트를 순서대로 쓴다. `*ptr_varvals` 가 buffer 끝에서 얼마나 가까운지에 따라 첫 8바이트에서 죽으면 `or_put_oid`, 두 번째 8바이트에서 죽으면 `or_put_bigint` 가 crash site가 된다.

```
남은 공간 < 8 bytes       -> or_put_oid assert
8 bytes <= 남은 공간 < 16 -> or_put_bigint assert
```

따라서 `or_put_oid` 와 `or_put_bigint` 는 서로 다른 bug가 아니라 같은 16바이트 stub write의 서로 다른 실패 지점이다.

### 릴리스 빌드 위험

`or_put_oid` 와 `or_put_bigint` 의 마지막 bounds check는 debug `assert` 다. release 빌드에서는 assert가 제거되므로 같은 상황에서 `S_DOESNT_FIT` 없이 record buffer 밖 8-16바이트를 쓸 수 있다. debug core는 조기 탐지이며, release에서는 더 늦은 crash나 데이터 오염으로 나타날 수 있다.

### BLOB/CLOB locator OOS 후보 정책

`bug_xdbms3693` 는 BLOB/CLOB locator가 많은 schema라 BLOB/CLOB OOS 후보 정책도 같이 드러낸다. LOB payload는 이미 외부 LOB storage에 있고 heap에는 locator만 남으므로, locator를 다시 OOS로 보내면 다음 구조가 된다.

```text
heap row -> OOS inline stub -> OOS record -> LOB locator -> LOB file
```

이 정책은 storage design 판단이다. BLOB/CLOB locator를 OOS 후보에서 제외하면 `bug_xdbms3693` 는 OOS path 자체를 피할 수 있지만, 이 이슈의 crash-safety 수정은 그래도 필요하다. LOB가 아닌 미래의 크기 추정 mismatch도 같은 위치 검사를 지나기 때문이다.

### 관련 이슈

| 이슈 | 관계 |
|------|------|
| CBRD-26813 | READ side에서 REC_BIGONE/OOS expansion을 다루는 자매 회귀다. CBRD-26814가 막히면 `bigPageSize.sh` 가 READ side 검증까지 가지 못한다. |
| CBRD-26822 | LOB prefix 누락으로 LOB 파일이 만들어지지 않는 별도 LOB 경로 회귀다. 같은 LOB/ELO cluster에 있지만 본 write-position bug와 직접 원인은 다르다. |
| CBRD-26660 | OOS M2 shell/manual 실패를 묶어 분류한 상위 분석 맥락이다. |

## Implementation

### 패치 방향

OOS 분기에서 실제 write 위치를 지역 변수로 먼저 잡고, 그 위치 기준으로 16바이트 여유를 검사한다.

```c
if (is_oos)
  {
    char *oos_stub_ptr = *ptr_varvals;

    if (oos_stub_ptr + OR_OOS_INLINE_SIZE > buf->endptr)
      {
        return S_DOESNT_FIT;
      }

    buf->ptr = oos_stub_ptr;
    or_put_oid (buf, oos_oid);
    or_put_bigint (buf, oos_length);
    *ptr_varvals = buf->ptr;
  }
```

VOT entry 자체의 공간 검사는 기존처럼 VOT 위치에서 유지한다. 바꾸는 것은 OOS inline stub write의 검사 기준뿐이다.

### 검증 포인트

`gdb` 로 확인할 때는 `heap_attrinfo_transform_variable_to_disk` 의 OOS 분기에서 다음 값을 비교한다.

```text
buf->endptr - buf->ptr       # VOT write 직후 cursor 기준 잔여 공간
buf->endptr - *ptr_varvals   # 실제 OOS inline stub write 위치 기준 잔여 공간
```

재현이 맞으면 기존 코드는 첫 값이 16 이상이라 통과하고, 두 번째 값은 16 미만이라 실제 write가 buffer 끝을 넘는다. 수정 후에는 두 번째 값이 16 미만일 때 `S_DOESNT_FIT` 이 반환되어 retry 경로로 들어간다.

## Acceptance Criteria

- [ ] `bigPageSize.sh` 의 `init.sql` 단계가 debug assert 없이 끝나고 `select count(*) from t;` 가 256을 반환한다.
- [ ] `bug_xdbms3693.sh` 가 `or_put_oid` server core 없이 통과한다.
- [ ] OOS inline stub write에서 `S_DOESNT_FIT` 이 발생하면 기존 buffer resize-and-retry 경로로 재조립된다.
- [ ] release 빌드에서 OOS inline stub write가 record buffer 밖으로 쓰지 않는다.
- [ ] BLOB/CLOB locator OOS 후보 제외 여부는 PR 설명 또는 후속 이슈에 명시한다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족.
- [ ] OOS 관련 SQL/shell 회귀를 재실행하고 결과를 PR 또는 JIRA comment에 기록.
- [ ] 필요하면 `bug_xdbms3693` 형태의 many LOB locator regression을 추가.

## Code References

| 파일:줄 | 역할 |
|---------|------|
| `src/storage/heap_file.c:12786` | `heap_attrinfo_transform_variable_to_disk` 진입점. |
| `src/storage/heap_file.c:12846` | 기존 OOS inline stub bounds check가 `buf->ptr` 기준으로 수행되는 위치. |
| `src/storage/heap_file.c:12851` | 실제 write 위치인 `*ptr_varvals` 로 이동하는 위치. |
| `src/storage/heap_file.c:12852` | `or_put_oid` 호출. `bug_xdbms3693` 의 crash site로 이어진다. |
| `src/storage/heap_file.c:12853` | `or_put_bigint` 호출. 기존 CBRD-26814 `bigPageSize.sh` 의 crash site로 이어진다. |
| `src/storage/heap_file.c:12888` | LOB locator를 `db_elo_copy_with_prefix` 로 재생성하는 위치. |
| `src/base/object_representation.h:455` | `OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE`, 현재 16바이트. |
| `src/base/object_representation.h:3049` | `or_put_oid` debug assert. |
| `src/base/object_representation.h:2029` | `or_put_bigint` debug assert. |

## Remarks

- JIRA metadata 기준 이 이슈는 CBRD-26835의 Sub-task이며, bug-fix 내용상 Correct Error template로 정리했다.
- 기존 CBRD-26814 본문에는 `OR_OOS_INLINE_SIZE` 를 18바이트로 적은 부분이 있었으나, 현재 `feature/oos-m2` 코드와 OOS context 기준으로는 16바이트가 맞다.
