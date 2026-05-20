# [OOS] [M2] 매뉴얼 테스트 32개 NOK 분류 및 후속 티켓 분기

## Issue Triage

**이슈 수행 목적**: `feat-oos-m2-manual` 빌드(`11.5.0.2328-8d7b97a`) 의 매뉴얼 CI 결과 32개 NOK 를 회귀 클러스터별로 분류한다. M2 머지를 막아야 할 OOS 회귀와, OOS 와 무관한 환경/답안 차분을 갈라 후속 티켓으로 보낸다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: 32 NOK 가 한 파일(`failed-tc.txt`, 1.9 MB / 37,489 lines) 에 한꺼번에 묶여 있다. 어느 것이 진짜 OOS 회귀이고 어느 것이 기존 `_25_unstable` flaky 인지 분류돼 있지 않다. 코어 덤프는 한 건만 있고 (`peekmem_elo` 의 `or_get_int` 에서 SIGSEGV — 자세한 스택은 클러스터 1 #1 참조), 나머지는 *diff* 만 남았다. 사전 분석 결과 high 12건은 모두 LOB/ELO 직렬화 또는 OOS 읽기 경로에서 깨지는 공통 패턴을 보인다 — `OR_VAR_BIT_OOS` 가 켜진 컬럼의 16바이트 OOS-OID 슬롯을 ELO read 가 길이 필드로 오독한다는 가설이 가장 유력하다.
- **영향**: M2 머지 게이트가 막힌다. 빠른 분류 없이는 회귀가 환경 잡음에 묻혀 머지가 지연되거나, 반대로 회귀를 놓친 채 통과되어 운영 단계에서 LOB/CLOB 데이터 손실로 번질 수 있다.

**이슈 수행 방안**:

- **버킷 분류**: 32 NOK 를 세 버킷으로 가른다 — high (OOS 회귀 추정 12), medium (OOS 추정 4), low (OOS 무관 추정 16). 매핑 표는 `## AI-Generated Context` 의 분류 표.
- **분류 규칙**: 코어 덤프 스택 또는 *"External file `ces_*` not found"* 같은 OOS-specific 증상이 잡힌 항목은 `_25_unstable/*` 경로에 있어도 high. 코드 경로 증거가 답안 파일 차분 수준에 그치면 medium/low. `_25_unstable` 라벨 하나만으로는 high 에서 빼지 않는다.
- **후속 티켓**: high 12건은 한 건씩 따로 만들지 않고 근원이 같은 단위로 묶어 3개 티켓으로 분기.
    - 클러스터 1 — LOB/ELO 외부 저장소 손상 (9건: #1, 2, 3, 4, 12, 14, 17, 19, 22)
    - 클러스터 2 — 대용량 VARCHAR/JSON 의 OOS 읽기 누락 (1건: #29 `cbrd_25481`)
    - 클러스터 3 — TDE 와 OOS overflow page 가 같이 쓰일 때의 충돌 (2건: #8, #9)
    - 티켓 번호는 `## 후속 작업` 체크리스트에 채운다.
- **재실행 확인**: `_25_unstable/*` 와 dblink/`SUBQUERY_CACHE` 트레이스 차분 (#10, 13, 16, 18, 20, 21, 23, 24, 25, 26, 27, 28, 30, 31, 32) 은 master HEAD 에서 재현되는지 먼저 본다. 재현되면 본 M2 게이트에서 제외하고, 재현되지 않으면 별도 회귀로 재분류한다.
- **답안 갱신 후보**:
    - #6 (`MNT_SERVER_COPY_STATS` 가 정확히 +4,464 B): OOS 와 무관한 별도 commit 의 프로토콜 카운터 증가로 보인다. answer 갱신 PR 만 발행.
    - #11 (buffer pool stat 이 정확히 +1): OOS metaclass fetch 한 번이 추가됐을 가능성. 의도된 비용이 맞으면 answer 갱신, 아니면 회귀로 다시 본다.
- **분석 원본**: 본 브랜치 `feat-oos-m2-manual` 의 `failed-tc-report.md`. 다른 머신에서 보는 사람을 위해 sub-task 첨부 또는 PR 링크로도 공유한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 `failed-tc.txt` 와 `feat-oos-m2-manual` 소스 트리를 대조해 작성한 분류 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다. 본문은 후속 티켓 작성과 리뷰에서 참고용으로 쓴다.

### Summary

- **문제**: NOK 32건의 회귀 여부 분류.
- **배경**: 한 파일에 다 묶인 diff/코어를 단일 분류 패스로 처리하지 않으면 머지 결정이 지연된다.
- **변경**: 세 회귀 클러스터로 묶어 후속 티켓을 분기, `_25_unstable` 항목은 master 재현 확인 후 분기.
- **영향 범위**: M2 릴리스 게이트. 후속 티켓 발행 후 본 sub-task 는 close.

---

## Description

`feat-oos-m2-manual` 브랜치 빌드 `11.5.0.2328-8d7b97a` 의 외부 CI (`cubrid-testcases-private-ex/shell`) 에서 32개 NOK 가 발생했다. 원본 결과는 브랜치 작업 디렉터리의 `failed-tc.txt` (37,489 lines, 1.9 MB). 본 sub-task 의 산출물은 32 NOK 의 클러스터 분류와 후속 티켓 분기 결정 — 상세 분석은 `failed-tc-report.md` 가 source of truth.

### 분류 결과

| 버킷 | 갯수 | TC 번호 |
|---|---|---|
| high — OOS 회귀 추정 | 12 | 1, 2, 3, 4, 8, 9, 12, 14, 17, 19, 22, 29 |
| medium — OOS 추정 | 4 | 5, 7, 11, 15 |
| low — OOS 무관 추정 | 16 | 6, 10, 13, 16, 18, 20, 21, 23, 24, 25, 26, 27, 28, 30, 31, 32 |

high 12건의 클러스터 내역: 클러스터 1 (9건) `#1, 2, 3, 4, 12, 14, 17, 19, 22` / 클러스터 2 (1건) `#29` / 클러스터 3 (2건) `#8, 9`.

### 클러스터 1 — LOB / ELO 외부 저장소 (high 9건)

테스트가 BLOB/CLOB 컬럼을 다룰 때, 외부 저장소 파일 `ces_*` 가 생성되지 않거나, 읽을 때 *"External file not found"* 가 나거나, ELO 헤더를 읽다가 죽는다.

| # | Test | 증상 (요약) |
|---|---|---|
| 1 | `bigPageSize.sh` | `cub_admin` SIGSEGV: `or_get_int` <- `peekmem_elo` <- `mr_data_readval_blob` <- `get_desc_current` (`load_object.c:657`). `unloaddb` 가 256개 중 1개만 추출. |
| 2 | `cbrd_25446.sh` | LOB 경로 재배치 후 `SELECT` 결과가 *External file `ces_*` was not found*. |
| 3 | `bug_bts_10290.sh` | `CAST(... AS CLOB)` 가 *Path for external storage 'file:ces_763/...' is invalid* 반환. |
| 4 | `bug_bts_7596.sh` | CLOB/BLOB 24개 cast 변형 전부 동일 *external storage path invalid* 에러. |
| 12 | `bug_bts_16011.sh` (SA loaddb) | `loaddb` 는 OK 인데 `clob_to_char(content)` 가 *`ces_202/public.doc_t.0000...1575` was not found*. |
| 14 | `bug_bts_16011.sh` (CS loaddb) | 동일 결함, server-side `loaddb` 경로. 외부 파일이 아예 생기지 않는다. |
| 17 | `cbrd_23349.sh` | BLOB + CLOB + JSON + 큰 CHAR 혼합 테이블, `SELECT *` 가 *External file 'ces_433/...' was not found*. |
| 19 | `bug_bts_5596.sh` | `TRUNCATE` 후 10초 GC 대기에도 LOB 파일 2/4/6개 잔존. (경로는 `_25_unstable/`. 증상은 BLOB GC 누락이라 high 유지하되 master HEAD 재현 확인이 선결 조건인 경계 항목.) |
| 22 | `bug_xdbms3947.sh` | `INSERT INTO xoo (clob) ...` 후 `lob-base-path` 에 파일 0개. CLOB 가 외부 저장소로 가지 못한다. |

**원인 후보 (우선순위 순)**:

1. **ELO 헤더 직렬화 레이아웃 어긋남 (가설)**. `peekmem_elo` 가 `or_get_int` 로 처음 읽는 길이 슬롯과, OOS 가 끼워 넣은 16바이트 OOS-OID variable-area 슬롯이 어긋나 있을 가능성. 검증: `mr_data_writeval_blob` / `mr_data_readval_blob` (`object_primitive.c:6018` 부근) 의 `OR_VAR_BIT_OOS` 분기가 write/read 대칭인지 그렙으로 확인 + 디버그 빌드에서 #1 재현 후 buffer cursor 바이트를 master 와 비교.
2. **INSERT 경로에서 외부 파일이 생성되지 않는다**. `lob_locator.cpp` -> `src/storage/es.c` (`es_posix_*`) 핸드오프 직전에 OOS 가 large var 컬럼을 가로채면, OOS OID 만 기록되고 `ces_*` 파일은 만들어지지 않는다. #2, 3, 4, 12, 14, 17, 22 의 "missing file" 패턴과 일치.
3. **DELETE 경로에서 LOB unlink 가 빠진다 (가설)**. 새 OOS delete 경로 (`heap_record_replace_oos_oids` at `heap_file.c:7975`, `oos_delete`) 가 OOS 로 저장된 BLOB/CLOB 포인터를 만났을 때 `lob_locator_remove` / `es_delete_file` 을 호출하는지 확인이 필요하다. 호출이 빠지면 #19 의 GC 잔존이 설명된다.

**추적 시작점**: 디버그 빌드에서 `bigPageSize.sh` 를 재현하고, `peekmem_elo` 진입 시 buffer cursor 의 바이트를 master 와 diff. 한 자리만 어긋났다면 그 자리가 OOS 와 클래식 ELO 가 갈리는 지점이다.

### 클러스터 2 — 대용량 VARCHAR / JSON 의 OOS 읽기 누락 (high 1건)

**#29 `cbrd_25481.sh`** — 28개 sub-case 중 12개 NOK.

`loaddb` 는 성공하는데 `SELECT` 에서 컬럼 길이가 NULL 로 떨어지거나, CS 모드에서 행 자체가 사라진다. 1 MB ~ 7 MB 크기의 VARCHAR / JSON 컬럼을 다룰 때만 깨진다.

| Sub-case | 기대 `char_length(a)` | 실측 |
|---|---|---|
| `predfined` (SA/CS/split) | 1,108,895 | NULL |
| `random_single_row` (SA) | 6,990,515 | NULL |
| `random_single_row` (CS, split) | row 존재 | *"There are no results."* |
| `random_many_rows` row 1–5 | 1,398,116 x 5 | 앞에 NULL NULL 3행 추가, row 1 OK, row 2 NULL, row 3–5 누락 |
| `multiple_large_json_columns` | 세 컬럼 각 1,398,116 | 한 컬럼 4, 나머지 NULL / no results |

쓰기 측이 아니라 **읽기 측 OOS 회귀** 다. 의심 경로:

- 대용량 값의 OOS multi-chunk chain 을 끝까지 따라가지 않을 가능성.
- CS 모드 fetch (`xs_send_method_call_info_to_client` / `qmgr_get_query_result`) 에서 OOS OID 가 변환되지 않은 채 클라이언트로 넘어가는 가능성 — `heap_record_replace_oos_oids()` 가 `locator_fetch_all` 외 경로에서 빠졌을 수 있다. CBRD-26516 의 "UPDATE 3x 중복 호출" 수정이 과도하게 깎인 변종일 가능성.
- 6.9 MB 단일 행은 `RECDES` length 4-byte 한계 (2 GB) 와는 거리가 멀어 INT 오버플로 가능성은 낮지만, OOS chunk header 의 길이 필드는 한 번 확인할 가치가 있다 (OOS-CONTEXT 의 "RECDES length 4-byte limit" 메모 참조).

### 클러스터 3 — TDE 와 OOS 가 같이 쓰일 때의 overflow page 충돌 (high 2건)

| # | Test | 증상 |
|---|---|---|
| 8 | `tbl_enc_14.sh` (TDE + `varchar(20000)`) | `diagdb` 출력에서 `MULTIPAGE_OBJECT_HEAP / Overflow for HFID / tde_algorithm: AES` 블록이 **누락**. |
| 9 | `tbl_enc_08.sh` (TDE + `varchar(20000)`) | 반대로 `MULTIPAGE_OBJECT_HEAP` 레코드가 **하나 더** 등장. |

#8 (overflow 페이지 **누락**) 과 #9 (overflow 페이지 **추가**) 는 방향이 반대다. 가설은 — AES wrapping 후 페이로드 크기가 한쪽 테스트에서만 512 B 경계를 넘어, OOS 임계치 (`record > DB_PAGESIZE/8` AND `column > 512B`) 판정이 측정 시점에 따라 갈린다. 즉 OOS 와 `HEAP_OVF_*` 가 상호 배타적이지 않은 채로 임계치 평가가 양쪽으로 엇갈린다. 두 테스트가 진짜 같은 근원인지(혹은 서로 다른 회귀 두 건인지) 는 후속 티켓에서 확인.

### 클러스터 4 — OOS 추정 medium (4건)

| # | Test | 메모 |
|---|---|---|
| 5 | `cbrd_24103.sh` | `db24103/lob/.../ces_*` 파일 누락 — 증상은 클러스터 1 과 같지만, 동일 cell 에서 file-permissions assert 와 file-count assert 가 같이 깨져 신호 분리가 안 된다. high 로 올리려면 두 assert 를 분리 재현해야 한다. |
| 7 | `multi_queries_2.sh` | `4 ddd` 추가 / `4 eee` 누락. MVCC 가시성 회귀 가능성. OOS 가 `OR_MVCC_FLAG_HAS_OOS` 로 MVCC 헤더를 건드리기 때문에 후보로 둔다. |
| 11 | `cbrd_22803.sh` | `Num_hit`, `Num_page_request` 가 답안 대비 정확히 +1. OOS metaclass fetch 한 번이 추가됐을 가능성. 코드 회귀라기보다 답안 갱신이 맞을 수 있다. |
| 15 | `bug_bts_8199.sh` | LOB lifecycle, #19 와 같은 family. diff 가 충분히 캡처되지 않았다. |

### OOS 무관 추정 low (16건)

| # | Test | 무관으로 본 근거 |
|---|---|---|
| 6 | `cbrd_20145_1.sh` | `MNT_SERVER_COPY_STATS` recv size 가 정확히 +4,464 B. 별도 commit 의 프로토콜 카운터 증가로 보인다. answer 갱신 후보. |
| 10 | `cbrd_23843_3.sh` | dblink 문법. diff 가 사실상 비어 있다. |
| 13 | `_itrack_1000316.sh` | TRIM / 문자열 처리, diff 가 시각적으로 동일. trailing whitespace 차분일 가능성. |
| 16 | `bug_xdbms3845.sh` | DB copy. 진단할 만큼 diff 가 캡처되지 않았다. |
| 18 | `cbrd_26111.sh` | 설정 파일 token (`cub_server.err` vs `cub_client.err`). `_25_unstable` 영역의 config drift. |
| 20 | `cbrd_24046.sh` | `SUBQUERY_CACHE` hit/miss 카운트. optimizer cache 변경, 저장소 무관. |
| 21 | `bug_bts_9617.sh` | 브로커 access log 파일이 생성되지 않는다. 브로커는 OOS write 경로를 거치지 않으므로 OOS 회귀로는 연결되지 않는다. 환경 / 권한 문제로 추정. |
| 23, 24, 26 | dblink `_09_scalar_subquery` | `SUBQUERY_CACHE (hit:?, miss:?, ...)` trace 한 줄 추가, 세 케이스 모두 동일. upstream answer drift. |
| 25, 27, 28, 30 | dblink DML (CUBRID/MySQL/MariaDB/Oracle) | 원격 호환성 + locale. 예: #25 `_31_intl_date_lang` 은 영어 vs 한국어 날짜 포맷 차분. |
| 31 | `check_option.sh` | 유틸리티 옵션 파싱. data path 무관. |
| 32 | `bug_bts_16030.sh` | suite-init timeout. 49개 sub-test 가 개별적으로는 모두 통과. 인프라 / 슬로우 러너 문제. |

### 후속 작업

- [ ] 클러스터 1 (LOB/ELO) 회귀 티켓 발행 (`TBD - 신규 CBRD-`). 본 분석의 클러스터 1 표를 그대로 첨부.
- [ ] 클러스터 2 (대용량 OOS 읽기) 회귀 티켓 발행 (`TBD - 신규 CBRD-`). `cbrd_25481` CS 모드 `random_single_row` 의 7 MB JSON 한 줄을 최소 재현으로 제시.
- [ ] 클러스터 3 (TDE x OOS) 회귀 티켓 발행 (`TBD - 신규 CBRD-`). `tbl_enc_08` / `tbl_enc_14` 의 `diagdb` 출력 차분 첨부.
- [ ] master HEAD 에서 OOS 무관 추정 16건 일괄 재실행. 재현되는 항목은 M2 게이트에서 제외, 그렇지 않으면 다시 분류.
- [ ] #6, #11 의 답안 갱신 PR (필요시 별도 sub-task 로 분리).

## Acceptance Criteria

- [ ] 세 회귀 클러스터 (LOB/ELO, 대용량 OOS read, TDE x OOS) 에 대해 별도 CBRD-XXXXX 가 각각 생성되고, 본 sub-task 의 Remarks 와 `failed-tc-report.md` 의 클러스터 표 양쪽에 티켓 번호가 채워진다.
- [ ] OOS 무관 추정 16건 (특히 `_25_unstable/*` 9건) 의 master baseline 재현 여부가 본 sub-task 코멘트에 표 형태로 정리된다.
- [ ] `failed-tc-report.md` 가 본 sub-task 첨부 또는 git-tracked 경로 (`feat-oos-m2-manual` 브랜치) 로 도달 가능하다.

## Definition of done

- [ ] 위 A/C 모두 충족.
- [ ] 후속 회귀 티켓 3건이 M2 머지 게이트에 등록된다.
- [ ] OOS 무관 추정 16건은 본 sub-task 에 명시적으로 close-out.

## 참고 파일

- `failed-tc.txt` (브랜치 `feat-oos-m2-manual` 작업 디렉터리) — 원본 NOK 출력.
- `failed-tc-report.md` (브랜치 `feat-oos-m2-manual` 작업 디렉터리) — 본 분류의 상세 분석 보고서.

### 주요 의심 소스 (LOB/ELO 클러스터)

| 파일:줄 | 역할 |
|---|---|
| `src/object/object_primitive.c:5880` (`peekmem_elo`) | #1 SIGSEGV 사이트. OOS 와 클래식 ELO 가 처음 갈리는 지점. |
| `src/object/object_primitive.c:5999` (`readval_elo_with_type`) | `peekmem_elo` 호출자. BLOB / CLOB ELO read 진입. |
| `src/base/object_representation.h:1727` (`or_get_int`) | 정확한 크래시 명령. buffer cursor / 잔여 길이 확인이 필요. |
| `src/loaddb/load_object.c:657` (`get_desc_current`) | `unloaddb` 가 컬럼 단위로 순회하는 곳. ELO read 의 비-라이브러리 최초 호출자. |
| `src/object/lob_locator.cpp` | LOB locator API, insert 시 `es.c` 핸드오프. |
| `src/storage/es.c` (`es_posix_*`) | 실제 `ces_*` 외부 파일 생성. |
| `src/storage/oos_file.cpp` | OOS chunk write / read, 대용량 값의 chain. |
| `src/storage/heap_file.c` (`heap_record_replace_oos_oids`) | 모든 read 경로에 호출돼야 한다. CS 모드 fetch 누락 가능성. |

## Remarks

- 본 sub-task 자체는 분석 / triage 추적용. 회귀 수정 PR 은 위 후속 티켓 3건에서 다룬다.
- 부모 epic: CBRD-26583 (OOS M2 epic).
