# [TC] [Regression] bigPageSize.sh — ORDER BY 1 DESC LIMIT 1 이 비결정적이라 OOS 빌드에서 NOK

## Issue Triage

**이슈 수행 목적** (필수): Shell test `bigPageSize.sh` 가 page size 나 OOS 동작에 상관없이 항상 같은 결과를 내도록, TC 의 ORDER BY 한 줄에 정렬 기준 컬럼을 하나 더 추가한다.

**이슈 수행 이유** (필수):

### As-Is (현재 동작)

한 줄 요약: *"동일한 데이터를 가진 두 DB 에서 같은 SELECT 를 돌렸는데, 서로 다른 row 가 나온다."*

자세히:

1. **테스트가 하는 일** — `bigPageSize.sh` 는 같은 데이터를 page size 만 다른 두 DB 에 적재한 뒤, 양쪽에서 같은 SELECT 를 돌려 결과 파일을 line-by-line 으로 비교한다.
   - `tdb1`: 기본 16K page, `csql -S` 로 직접 INSERT.
   - `tdb2`: 4K page (`--db-page-size=4k`), `tdb1` 을 `unloaddb` → `loaddb` 로 재적재.

2. **테이블 데이터의 모양** — `init.sql:48-73` 은 row 한 개를 INSERT 한 뒤 `INSERT INTO t SELECT ... FROM t` 를 8 번 반복한다 (1 → 2 → 4 → … → 256). 결과적으로:
   - 256 row 가 만들어지는데, **모든 일반 컬럼 값이 동일** 하다 (`col1..col6, d1..d8, c1..c3, j` 전부 같은 값. 예: `col1 = -32768`).
   - 오직 AUTO_INCREMENT 컬럼인 `id` 만 row 마다 다른 값.

3. **비교에 쓰는 query** (`bigPageSize.sh:21-24`) — `select ... from t order by 1 desc limit 1`. "첫 번째 컬럼(`col1`) 으로 내림차순 정렬한 뒤 맨 위 1 row 만 가져와" 라는 뜻이다.

4. **여기서 문제가 시작된다** — 256 row 의 `col1` 이 전부 같은 값이라, ORDER BY 가 보는 정렬 키만으로는 어떤 row 가 "1 등" 인지 정해지지 않는다 (정렬 키가 tie). 이 경우 어떤 row 가 LIMIT 1 의 winner 가 될지는 **SQL 표준이 약속하지 않는 영역 (implementation-defined)** 이며, CUBRID 도 별도 보장을 두지 않는다. 즉 이 query 의 결과는 처음부터 storage 의 물리 배치 (어떤 row 가 heap 에서 먼저 스캔되는가) 에 의존하는 비결정적 query 다. CUBRID 만의 특성이 아니고 PostgreSQL/MySQL/Oracle/SQL Server 도 동일하다.

5. **OOS 작업이 한 일** — OOS (Out-of-row Storage) 는 큰 컬럼을 외부 page 로 옮겨 저장한다. 이번 OOS 작업이 외부 이관 기준을 바꾸면서, 특히 4K page 인 `tdb2` 의 record 가 heap 안에서 놓이는 page · slot 위치가 달라졌다. heap scan 순서가 바뀌니 tie 상황의 winner 도 바뀌었다.

6. **결과** — `tdb1` 과 `tdb2` 가 256 row 중 *서로 다른* row 를 LIMIT 1 winner 로 골랐고, `compare_result_between_files csql1.log csql2.log` 가 NOK 를 보고한다. 두 log 의 diff 는 `id` 컬럼만 다른 한 row.

7. **develop 에서는 왜 통과했나** — 두 DB 가 우연히 같은 row 를 먼저 내놓던 coincidence. TC 가 본래 가지고 있던 잠재적 비결정성이 OOS 변경에 의해 드러난 것이지, engine regression 이 아니다.

### To-Be (목표 동작)

- 같은 데이터를 가진 두 DB 가 storage layout (page size, OOS 이관 정책) 과 무관하게 LIMIT 1 winner 로 **항상 같은 row** 를 반환 → `bigPageSize.sh` 가 항상 OK.
- Engine 동작 변경 없음. TC 한 파일의 한 줄만 수정.

**이슈 수행 방안**:

- `bigPageSize.sh:24` 를 다음과 같이 변경한다.
  - 현재: `from t order by 1 desc limit 1`
  - 변경: `from t order by 1 desc, id limit 1`
- 정렬 기준에 `id` 를 더하면, `col1` 이 같은 row 끼리는 `id` 로 순서가 정해진다. `id` 는 AUTO_INCREMENT 라 실질적으로 unique 하므로 256 row 에 total order 가 성립 → 결과가 결정적으로 한 row 로 정해진다.
- `unloaddb` / `loaddb` 는 `id` 값을 그대로 직렬화·재적재하므로 (AUTO_INCREMENT 재발급 없음) 두 DB 의 `id` 값이 동일 → 두 DB 가 같은 winner row 를 반환.
- Engine 변경 없음. 사용자 인용: *"Fix (TC-only, no engine change): Add `id` as a tiebreaker"*.
- Follow-up: 다른 shell test 에도 같은 잠재 문제가 있을 수 있어 audit. 실제 grep 명령은 Additional Information 참고.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 testcase 를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 만으로 충분하다. 본문은 구현·리뷰 단계의 reference 다.

### Summary

| 항목 | 내용 |
|---|---|
| 형태 | OOS 빌드에서 `bigPageSize.sh` 가 `compare_result_between_files csql1.log csql2.log` 단계에서 NOK |
| 진짜 원인 | Engine bug 가 아니다. TC 의 ORDER BY 가 tie 를 풀지 않아 LIMIT 1 가 비결정적 |
| Trigger | OOS 작업이 `tdb2` (4K page) 의 record 물리 배치를 바꿔, 이전에 우연히 일치하던 tied row 가 갈렸다 |
| 영향 범위 | TC 한 파일. Engine·spec·매뉴얼 변경 없음. 유사 패턴이 다른 shell test 에 잠재할 수 있다 |
| 호환성 | TC 만 고치므로 engine 회귀 risk 0. develop merge 후에도 그대로 동작 |

### 용어 정의

본문에서 first-use gloss 를 일일이 박으면 흐름이 끊기므로 한 곳에 모은다.

- **OOS** (Out-of-row Storage): heap 의 큰 가변 컬럼을 외부 page 로 분리해 저장하는 방식.
- **CTP** (CUBRID Test Platform): shell test runner. `ctp.sh shell -c <conf>` 로 testcase 한 묶음을 돈다.
- **`cubrid unloaddb`**: DB 를 schema 정의 파일과 row dump 파일 두 개로 추출하는 utility.
- **`cubrid loaddb`**: 위 두 파일을 다른 DB 로 다시 적재하는 utility.
- **`csql -S`**: csql 의 standalone mode — server process 없이 csql 안에서 DB 를 직접 열어 작업한다.
- **`compare_result_between_files`**: CTP shell helper. 두 결과 파일을 line-by-line 비교해 OK/NOK 를 판정한다.
- **`format_csql_output`**: CTP shell helper. csql output 의 timing·session id 등 휘발성 line 을 잘라 비교가 가능한 형태로 정규화한다.
- **`bigPageSize.result`**: CTP 가 매 case 의 pass/fail 을 적는 expected-output 파일. `bigPageSize-1 : OK`, `bigPageSize-2 : OK` 두 line 을 담는다.

### 핵심 사실 한 장 정리

- 1 row INSERT + 8 self-doubling => 256 row. 모든 row 의 `col1..col6, d1..d8, c1..c3, j` 가 동일. `id` (AUTO_INCREMENT) 만 unique.
- `ORDER BY 1 DESC` 의 1 번째 column 은 `col1` => 256-way tie.
- SQL spec: ORDER BY 의 key 가 가리키는 순서 외에는 implementation-defined. tie 면 어떤 row 가 LIMIT N 에 잡힐지는 약속이 아니다.
- Two-DB compare 가 깨진 이유: `tdb1` 은 16K page, `tdb2` 는 4K page + `unloaddb`/`loaddb` 경유. OOS 가 큰 컬럼 (c2 약 12 KB, c3 약 1.2 MB, j 약 1.5 MB) 의 외부 이관 동작을 바꾸면서 `tdb2` 의 heap scan 순서가 바뀌었다.

---

## Description

`bigPageSize.sh` 는 다음을 한다.

1. `tdb1` 생성 — `createtbl.sql` (schema) + `init.sql` (data) 실행.
2. `cubrid unloaddb -S tdb1` 로 `tdb1_schema`, `tdb1_objects` 추출.
3. `tdb2` 를 `--db-page-size=4k` 로 생성, `cubrid loaddb -C -d tdb1_objects -s tdb1_schema -udba tdb2` 로 같은 data 를 다른 DB 에 다시 적재.
4. 같은 SELECT 를 양쪽에서 실행, `format_csql_output` 으로 정규화한 뒤 `compare_result_between_files csql1.log csql2.log` 로 두 결과를 비교.

문제의 query 는 `bigPageSize.sh` line 21-24 (현재 file 상태):

```sql
select col1, col2, col3, col4, col5, col6,
       d1, d2, d3, d4, d5, d6, d7, d8, b1, c1, c2, c3,
       e, cl, bl, s1, s2, s3,
       json_pretty(json_extract(j, '$[500]'))
from t order by 1 desc limit 1
```

**제안하는 변경 (line 24)**: `from t order by 1 desc limit 1` 을 `from t order by 1 desc, id limit 1` 로 바꾼다. 본 ticket 은 그 변경이 왜 정당한지를 기록한다.

`init.sql` 의 INSERT 패턴 (line 48-73 요약):

```sql
INSERT INTO t (col1, ..., j) VALUES (-32768, ..., '<big json>');  -- 1 row
INSERT INTO t SELECT col1, ..., j FROM t;  -- self-double, x8
```

자동 부여되는 `id` 만 다르고 나머지는 동일하다. 즉 `ORDER BY 1 DESC` 가 비교하는 `col1` 의 값은 256 row 모두 `-32768` 이다. 어떤 row 가 LIMIT 1 로 나올지는 SQL spec 이 정하지 않으므로 구현에 맡겨진다.

`tdb1` 과 `tdb2` 는 같은 logical data 를 갖지만 물리 배치가 다르다.

| | `tdb1` | `tdb2` |
|---|---|---|
| Page size | 16K (기본) | 4K (`--db-page-size=4k`) |
| 데이터 적재 경로 | `csql` 의 직접 INSERT | `cubrid unloaddb` => `cubrid loaddb` |
| 실행 모드 | `csql -S` (standalone) | `csql` (server mode) |
| 큰 컬럼 (c2 약 12 KB, c3 약 1.2 MB, j 약 1.5 MB) 의 저장 | OOS 정책에 따라 외부 이관 | 같은 정책이지만 4K page 라 한 page 에 들어갈 수 있는 inline 영역이 좁아 더 많은 row 가 외부 이관 |

실행 모드 차이 (`bigPageSize.sh:26` 의 `csql -udba $db1 -S -l -c` vs `bigPageSize.sh:29` 의 `csql -udba $db2 -l -c`) 자체는 tie 문제와 직교한다.

OOS 이관 정책이 바뀌면 (예: `vk/cbrd-26824-shell-ci-fixes` 가 base 로 둔 `oos-bug-14917` 의 변경) heap 안에서 record 가 놓이는 page · slot 이 달라진다. heap scan 이 page 순으로 도는 한 sort 의 첫 input row 도 그에 따라 갈리고, ORDER BY key 가 전부 tie 인 상황에서는 그 input 순서가 그대로 결과 순서가 된다.

### develop 에서 OK 였던 이유

두 layout 이 우연히 같은 tied row 를 먼저 내놓던 coincidence. 더해서 `tdb1` 은 `csql` 의 직접 INSERT, `tdb2` 는 `unloaddb`/`loaddb` 경유라 두 적재 경로가 이미 자체적으로 layout 분기를 만들고 있었고, 16K vs 4K page 차이가 그 위에 얹혀 있었다. 그 위에 OOS 작업이 얹혀 우연 일치가 깨졌다. 본래 TC 가 가지고 있던 latent non-determinism 이 드러난 것이지, engine 회귀가 아니다.

### Fix 의 효과

`ORDER BY 1 DESC, id` 로 바꾸면 `id` 가 사실상 unique 라 total order 가 된다. `unloaddb` 는 column value 를 그대로 직렬화하고 `loaddb` 는 그 값을 그대로 INSERT 하므로 `tdb1` 과 `tdb2` 의 `id` 값은 동일하다 (AUTO_INCREMENT 가 재발급되지 않는다). 두 DB 가 같은 winner row 를 deterministic 하게 반환한다.

### Spec 근거 (한 줄)

ORDER BY 의 key 가 가리키는 순서 외에는 implementation-defined. 본 동작은 SQL 표준의 implementation-defined 영역이며, CUBRID 도 별도 약속을 두지 않는다. PostgreSQL / MySQL / Oracle / SQL Server 도 같은 입장이다. 즉 본 NOK 는 engine 의 spec 위반이 아니다.

### Test Build

- OS: Linux 5.14.0-570.30.1.el9_6.x86_64
- Build: local debug clang (`/home/vimkim/.cub/install/oos-bug-14917/debug_clang`)
- Branch: `vk/cbrd-26824-shell-ci-fixes`

---

## Repro

```bash
# bigPageSize.sh 1 건만 돌리기 (scenario 만 좁힌 conf 로 CTP 실행)
cp ~/CTP/conf/shell_ci.conf /tmp/shell_bigpage.conf
sed -i "s|^scenario=.*|scenario=$HOME/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize|" /tmp/shell_bigpage.conf
sed -i "s|^testcase_update_yn=.*|testcase_update_yn=false|" /tmp/shell_bigpage.conf
sed -i "s|^testcase_exclude_from_file=.*|#&|"               /tmp/shell_bigpage.conf
sed -i "s|^excluded_scenario=.*|#&|"                        /tmp/shell_bigpage.conf
~/CTP/bin/ctp.sh shell -c /tmp/shell_bigpage.conf
```

CTP 외에 직접 재현 (live trace 가 필요할 때):

```bash
export init_path=~/CTP/shell/init_path
cd ~/cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases
# 이전 run 의 잔여 정리
cubrid service stop 2>/dev/null || true
pkill -9 cub_server cub_master 2>/dev/null || true
rm -rf tdb1* tdb2* lob csql.* *.log *diff
sh bigPageSize.sh
```

비결정성 확인 (`tdb1` 에서 256 row 가 col1 tie 임을 직접 보기):

```sql
select id, col1 from t order by col1 desc limit 5;
-- 기대: col1 모두 -32768, id 는 실행마다 또는 두 DB 간 다를 수 있음
```

---

## Expected Result

- `bigPageSize-1`, `bigPageSize-2` 두 case 가 모두 `OK` 로 닫힌다.
- `csql1.log` 와 `csql2.log` 가 `compare_result_between_files` 에서 일치.

---

## Actual Result

- `compare_result_between_files csql1.log csql2.log` 가 diff 를 보고하며 NOK.
- 두 log 의 차이는 `id` 컬럼만 다른 한 row — `col1..j` 는 모두 같은 값. 즉 두 DB 가 col1 tie 256 row 중 서로 다른 row 를 LIMIT 1 winner 로 골랐다.

---

## Additional Information

- 같은 패턴이 다른 shell test 에 잠재할 수 있다. 한 번 grep 해 두면 follow-up 이 쉽다 (multi-line query 는 별도 검사 필요):
  ```bash
  rg -n 'order by .* limit' ~/cubrid-testcases-private-ex/shell/ \
    | rg -v 'order by .*, *id'
  ```
- 본 ticket 의 root cause 는 TC 비결정성이지, OOS·page-size·sort 동작의 spec 위반이 아니다. 즉 engine 쪽 fix 는 검토하지 않는다.
- Branch context: `vk/cbrd-26824-shell-ci-fixes` 는 CBRD-26824 (`bug_bts_14917` 회귀) 와 별개로 shell-CI 의 다른 NOK 들을 일괄 정리하는 work branch.

---

## 참고 코드

| 파일 / 위치 | 설명 |
|---|---|
| `cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/bigPageSize.sh:21-24` | fix 대상 — 현재 `from t order by 1 desc limit 1`. 본 ticket 의 변경은 line 24 에 `, id` 를 추가해 total order 로 만든다 |
| `cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/init.sql:48-73` | 256 row 가 col1 tie 가 되는 원인 (1 row + 8 self-doubling) |
| `cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/createtbl.sql` | `id INT AUTO_INCREMENT` 컬럼 정의 — fix 의 tiebreaker 근거. PK 선언은 없음 |

---

## Remarks

- 본 fix 는 TC 한 줄 수정. Engine PR 과 묶지 않고 testcase repo 의 별도 PR 로 분리한다.
- Follow-up: 위 `rg` 결과로 잡힌 testcase 들이 동일한 latent non-determinism 을 안고 있는지 audit. hit 가 다수면 별도 ticket 으로 묶는다.
- 사용자 인용: "회피 (test 를 CI 에서 빼거나 결과 비교를 끈다) 는 채택하지 않는다." 본 fix 는 우회가 아니라 query 의 의미를 명확히 하는 방향이라 그 정책과 충돌하지 않는다.
