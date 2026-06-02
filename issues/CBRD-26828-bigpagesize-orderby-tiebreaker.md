# [TC] [Regression] bigPageSize.sh — ORDER BY 1 DESC LIMIT 1 이 비결정적이라 OOS 빌드에서 NOK

## Issue Triage

**이슈 수행 목적** (필수): Shell test `bigPageSize.sh` 의 비결정적 ORDER BY 한 줄을 고쳐, page size/OOS 저장방식/적재 경로와 무관하게 항상 같은 결과가 나오게 한다. TC 한 줄 수정이며 engine 변경은 없다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: TC 의 비교 query 가 `select ... from t order by 1 desc limit 1` 인데, 1 번 컬럼 `col1` 이 256 row 전부 같은 값이라 정렬 키가 256-way tie 다. tie 일 때 LIMIT 1 winner 는 heap 물리 scan 순서로 정해지는 implementation-defined 동작이라, 이 query 는 처음부터 storage 물리 배치에 의존하는 비결정적 query 다.
- **영향**: QA 실패 — OOS 빌드에서 4K DB 의 heap 저장 표현이 바뀌며 (8 바이트 overflow 포인터 -> 약 656 바이트 inline, 상세는 AI-Generated Context 의 vpid 계측 참조) tie winner 가 row 1 에서 row 256 으로 역전돼 `compare_result_between_files` 가 NOK. engine bug 가 아니라, TC 가 본래 가진 비결정성이 OOS 변경으로 드러난 것이다.

**이슈 수행 방안**:

- `bigPageSize.sh:24` 의 `from t order by 1 desc limit 1` 을 `from t order by 1 desc, id limit 1` 로 바꾼다.
- `id` 는 AUTO_INCREMENT 라 실질 unique -> 256 row 에 total order 성립 -> winner 가 결정적으로 한 row 로 고정된다. `unloaddb`/`loaddb` 는 `id` 값을 그대로 재적재하므로 (AUTO_INCREMENT 재발급 없음) 두 DB 의 winner 가 일치한다.
- Engine/spec/매뉴얼 변경 없음. 사용자 인용: *"Fix (TC-only, no engine change): Add `id` as a tiebreaker"*.
- Follow-up: 같은 패턴 (`order by ... limit` + tie) 이 다른 shell test 에 잠재할 수 있어 audit. grep 명령은 Additional Information 참고.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 testcase 를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 만으로 충분하다. 본문은 구현/리뷰 단계의 reference 다.

### Summary

| 항목 | 내용 |
|---|---|
| 형태 | OOS 빌드에서 `bigPageSize.sh` 가 `compare_result_between_files csql1.log csql2.log` 단계에서 NOK |
| 진짜 원인 | Engine bug 가 아니다. TC 의 ORDER BY 가 tie 를 풀지 않아 LIMIT 1 가 비결정적 |
| Trigger | OOS 가 큰 행의 heap home record 를 8 바이트 포인터 (`REC_BIGONE`) 에서 약 656 바이트 inline (`REC_HOME`) 으로 바꿔, 4K 헤더 page 에 마지막 행이 놓이며 tie winner 가 역전됐다 (코드 계측으로 `vpid` 단위 확정) |
| 모드 의존성 | CS 모드 (`loaddb -C`) 에서만 회귀. SA 모드 (`loaddb -S`) 는 develop/OOS 동일 — OOS inline 저장은 server-side insert 에서만 작동 |
| 영향 범위 | TC 한 파일. Engine/spec/매뉴얼 변경 없음. 유사 패턴이 다른 shell test 에 잠재할 수 있다 |
| 호환성 | TC 만 고치므로 engine 회귀 risk 0. develop merge 후에도 그대로 동작 |

### 용어 정의

본문에서 first-use gloss 를 일일이 박으면 흐름이 끊기므로 한 곳에 모은다.

- **OOS** (Out-of-row Storage): heap 의 큰 가변 컬럼을 외부 page 로 분리해 저장하는 방식.
- **CTP** (CUBRID Test Platform): shell test runner. `ctp.sh shell -c <conf>` 로 testcase 한 묶음을 돈다.
- **`cubrid unloaddb`**: DB 를 schema 정의 파일과 row dump 파일 두 개로 추출하는 utility.
- **`cubrid loaddb`**: 위 두 파일을 다른 DB 로 다시 적재하는 utility.
- **`csql -S`**: csql 의 standalone mode — server process 없이 csql 안에서 DB 를 직접 열어 작업한다.
- **`compare_result_between_files`**: CTP shell helper. 두 결과 파일을 line-by-line 비교해 OK/NOK 를 판정한다.
- **`format_csql_output`**: CTP shell helper. csql output 의 timing/session id 등 휘발성 line 을 잘라 비교가 가능한 형태로 정규화한다.
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

### 근본 원인 — 코드 계측으로 vpid 단위 확정

이전에는 "OOS 가 물리 배치를 바꿨다" 수준까지만 알았는데, 이번에 계측 빌드로 어느 행이 어느 page/slot 에 놓이는지 직접 측정해 `vpid` (volume id + page id, 디스크 page 의 식별자) 단위로 원인을 확정했다.

**계측 방법** — `src/storage/heap_file.c` 의 `heap_insert_physical()` (행의 home record 를 heap page 에 배치하는 함수) 에 insert 순서별 `vpid|slot` 로깅을 한 줄 넣고 develop / OOS 두 빌드를 재빌드한 뒤, 같은 데이터를 `loaddb -C` 로 적재하며 각 행의 착지 위치를 기록했다.

```c
/* spage_insert_at 직후 */
fprintf (hins_fp, "#%d oid=%d|%d|%d len=%d\n", ++ctr,
         res_oid.volid, res_oid.pageid, res_oid.slotid, recdes->length);
```

**실측 결과** (256 건, 적재 순서 = `id` 1 -> 256, 예시 db 기준):

| insert 순서 | DEVELOP | OOS |
|---|---|---|
| #1 = row 1 | `page 4673, slot 1`, len 8 | `page 4674, slot 1`, len 656 |
| #2 ... #255 | `4673` slot 2 ... 255 (len 8) | `4674 ... 4724` (len 656) |
| #256 = row 256 (마지막) | `4673, slot 256` (len 8) | `4673, slot 1` (len 656) |
| 가장 낮은 page (scan 시작점) `slot 1` | row 1 | row 256 |
| 첫 scan row | 1 (16K 와 동일) -> OK | 256 -> NOK |

핵심은 home record (행이 heap page 에 차지하는 본체 레코드) 크기다.

- **develop** 은 큰 행을 통째로 외부 overflow 에 저장하고 home 에는 8 바이트 포인터 (`REC_BIGONE` — 행 전체가 overflow 에 있음을 나타내는 레코드 타입) 만 남긴다. 8 바이트라 256 건이 4K 헤더 page (`4673`) 한 장에 적재 순서대로 다 들어가 `slot 1 = row 1` 이다.
- **OOS** 는 큰 컬럼만 OOS 파일로 빼고 행을 inline (`REC_HOME` — 행 본체가 heap 에 그대로 있는 일반 레코드 타입, 약 656 바이트) 으로 heap 에 유지한다. 656 바이트라 4K page 에 몇 건 못 들어가 row 1~255 가 새 page (`4674~4724`) 로 밀리고, 헤더 page 에 남은 656 바이트 한 자리를 맨 마지막 insert (row 256) 가 차지해 `slot 1 = row 256` 이 된다.

heap scan 은 가장 낮은 pageid 인 헤더 page 부터 돈다. 따라서 home record 가 8 바이트에서 656 바이트로 커진 것만으로 scan 의 첫 행이 row 1 에서 row 256 으로 뒤집히고, 256-way tie 라 그 첫 행이 그대로 LIMIT 1 winner 가 된다.

> **한 줄 근본 원인**: OOS 가 큰 행의 heap 저장 표현을 8 바이트 포인터에서 656 바이트 inline 으로 바꿈 -> 4K 헤더 page 에 마지막 행만 들어감 -> 가장 낮은 page (scan 시작) 에 마지막 행이 놓임 -> tie 쿼리 winner 역전.

### 모드별 매트릭스 (develop vs OOS x 적재 경로)

같은 데이터에서 4K DB 의 첫 scan row (16K 는 항상 `1,2,3...`):

| 4K 적재 경로 | develop (OOS 이전) | OOS |
|---|---|---|
| `csql -S` 직접 INSERT | `1 2 3 ...` | `1 2 3 ...` |
| `loaddb -S` (SA 모드) | `256 255 254 ...` | `256 255 254 ...` (동일) |
| `loaddb -C` (CS 모드, TC 가 쓰는 방식) | `1 2 3 ...` (OK) | `256 1 2 3 ...` (NOK) |

회귀 (통과 -> 실패) 는 **CS 모드에서만** 발생한다. OOS 의 inline 저장 경로는 server-side insert 에서만 작동하므로 SA 모드는 develop/OOS 가 동일하게 동작한다. 즉 16K vs 4K 차이가 아니라 4K + OOS + CS 적재 세 조건이 겹칠 때만 깨진다.

### 배제한 가설 (모두 실측으로 무관 확인)

| 가설 | 검증 방법 | 결과 |
|---|---|---|
| loaddb 멀티스레드 (`loaddb_worker_count`) | 256 row < `periodic_commit` (10240) -> 단일 batch -> worker 1 개. 재적재 2 회 동일 | 결정적, 무관 |
| `unloaddb -t` (멀티스레드 dump) | TC 기본 `-t 1` 은 legacy `-t 0` 과 dump 순서 동일 (`1,2,...,256`). `-t >= 2` 라야 뒤섞임 | TC 와 무관 |
| 조회 시 parallel heap scan | `/*+ PARALLEL(0) NO_PARALLEL_HEAP_SCAN */` vs 기본 비교 | 결과 동일, 무관 |

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
- 본 ticket 의 root cause 는 TC 비결정성이지, OOS/page-size/sort 동작의 spec 위반이 아니다. 즉 engine 쪽 fix 는 검토하지 않는다.
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
