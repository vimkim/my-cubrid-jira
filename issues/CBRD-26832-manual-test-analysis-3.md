# [OOS] [M2] [Regression] [Top Level] 매뉴얼 테스트 결과 분석 및 실패 케이스 이슈화 3

## Issue Triage

**이슈 수행 목적**: CBRD-26660 / CBRD-26817 의 round-3 follow-up. `feature/oos-m2` 브랜치 빌드 `11.5.0.2338-404b396` 의 manual QA shell 결과 19건 NOK 를 OOS (Out-of-row Overflow Storage, 가변 컬럼을 별도 파일로 떼어내는 본 M2 의 핵심 기능) 회귀, 환경 / flaky, round-2 회귀 복귀의 세 갈래로 분류해 M2 머지 차단 항목만 작업 큐에 남긴다.

**이슈 수행 이유**:

- **현재 동작 / 배경**:
    - HEAD 빌드 `11.5.0.2338-404b396` 의 manual QA 결과 (`shellTestId=56510`, `resultType=NOK`) 에서 shell 19건 NOK 가 잔존한다.
    - round-2 (CBRD-26817, build `11.5.0.2334-e2a5d2b`) 의 16건 대비 NOK 절대수는 늘었지만, 코어 덤프는 0건이고 round-1 의 `peekmem_elo` SIGSEGV 도 사라졌다. LOB / ELO (External LOB Object) 클러스터 7건 (`bug_xdbms3947`, `bug_bts_16011` SA/CS, `bug_bts_7596`, `bug_bts_10290`, `cbrd_23349`, `cbrd_24103`) 이 자취를 감췄다.
    - 이 변화는 CBRD-26815 (OOS JSON deserialize), CBRD-26813 (`REC_BIGONE` reassembly 후 OOS OID 확장), CBRD-26814 (OOS inline metadata fit 검사) 머지의 효과로 보인다.
    - 동시에 round-2 의 "fixed 16건" 목록에 들어 있던 5건 (`bigPageSize.sh`, `tbl_enc_08.sh`, `multi_queries_2.sh`, `cbrd_23843_3.sh`, `check_option.sh`) 이 round-3 에서 다시 NOK 로 잡힌다.
- **영향**: M2 머지 게이트가 막힌다. round-2 에서 통과로 분류해 후속 회귀 추적에서 빠진 5건이 round-3 에서 다시 NOK 가 되면, 다음 라운드에서도 "정말 고쳐졌나" 를 매번 다시 확인해야 한다. 본 sub-task 에서 이번 회귀 복귀가 진짜 코드 회귀인지, answer 파일 drift 인지, 환경 차이인지 가르지 않으면 M2 마감 결정이 지연되고 회귀가 OOS 무관 잡음에 묻혀 production 까지 새어 나갈 위험이 있다.

**이슈 수행 방안**:

- 19건 NOK 를 6 버킷으로 가른다. A) OOS 회귀 의심 3건, B) dblink (CUBRID 의 원격 DB 링크 문법, parser 가 별도 분기를 탄다) 포맷 / locale 6건, C) stat 카운터 flaky 4건, D) 결과셋 / 옵션 drift 4건, E) PL/CSQL trace 카운터 1건, F) medium 회귀 rollup 1건. 버킷별 매핑과 evidence 는 `## AI-Generated Context` 의 분류 절 (Bucket A 표 + 후속 산문) 에서 단일 canonical 으로 다룬다.
- 버킷 A (OOS 회귀 의심) 3건은 본 sub-task 의 핵심 대상이다. TC#1 `tbl_enc_08`, TC#2 `tbl_enc_14`, TC#11 `cbrd_24916_check_index_ovfps`. 가설과 의심 사이트의 본 분석은 아래 `### Bucket A` 산문에 모았다.
- round-2 회귀 복귀 5건 (`bigPageSize`, `tbl_enc_08`, `multi_queries_2`, `cbrd_23843_3`, `check_option`) 은 6 버킷 분류 위에 별도 플래그를 단다. 셋 중 하나다: round-2 fix 가 round-3 에서 다시 깨졌거나, 머지 충돌 시점의 build artifact 차이거나, answer 파일 의도 차이. 5건 모두 develop HEAD 에서 단발 재현해 baseline 을 다시 확인한다 (Recommended Next Steps 의 단일 지시).
- 버킷 C (stat flake) 4건 (`cbrd_25278_option`, `cbrd_20145_1`, `cbrd_22803`, `bug_bts_5342`) 은 본 sub-task 범위 밖. CBRD-26817 에서도 같은 분류였고, round-3 도 같은 패턴 (run-to-run counter drift 또는 archive-log timing) 이라 develop baseline 재실행 또는 answer 파일 갱신으로 분리한다.
- 버킷 B / D / E / F 는 round-2 와 비교한 변화량만 짚고 본 sub-task 에서는 회귀 여부 판정을 보류한다. 다만 B 의 TC#14 `cbrd_24501_cubrid` -12 (`count(*) = 900000` vs 답안 `0`) 는 단순 locale / formatting 이 아니라 "remote `cub_server` kill 도중 dblink 가 보고있던 행이 격리되지 않고 노출" 류의 semantic 회귀라 OOS 와 무관하더라도 별도 plain-bug 티켓 후보로 둔다.
- 분석 원본: 본 분석가의 로컬 작업 트리에만 존재하는 `tc/SUMMARY.md`, `tc/PROMPT.md`, `tc/raw/tc_NN_*.txt`. PR / branch 에는 포함되지 않는다.

---

## AI-Generated Context

> 아래 내용은 AI 가 `shellTestId=56510` 결과 페이지와 `feature/oos-m2` 소스 트리를 대조해 작성한 분류 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만 보면 충분하다. 본문은 후속 티켓 작성과 리뷰 단계에서 참고용으로 쓴다.

### Summary

- **문제 / 목적**: round-3 manual QA 의 19 NOK 분류. OOS 회귀와 환경 잡음, round-2 회귀 복귀를 가른다.
- **원인 / 배경**: CBRD-26815 / CBRD-26813 / CBRD-26814 머지 이후 LOB / ELO 클러스터 7건과 SIGSEGV 1건이 해소됐고, 잔존 OOS 의심은 TDE x OOS heap dump 와 catalog-driven script 쪽으로 좁혀졌다. 같은 라운드에서 round-2 의 fixed 5건이 다시 NOK 로 돌아왔다.
- **제안 / 변경**: 6 버킷 분류 + round-2 회귀 복귀 5건 플래그. OOS 회귀 의심 3건만 M2 차단 항목으로 남기고, 회귀 복귀 5건은 develop baseline 재현 후 재분류.
- **영향 범위**: M2 마감 일정, OOS 회귀 fix 후속 sub-task 발행 여부, round-2 fix 안정성 재평가. 정량 분포는 아래 `### Tally` 가 단일 canonical.

---

## Description

### Test Build / Scope

- **Build**: `11.5.0.2338-404b396` (2026-05-21)
- **Branch**: `feature/oos-m2` (HEAD `ca3e7d522`, `cub/develop` merge 직후)
- **TC branch**: `feature/oos-m2`
- **Test categories (수행 범위)**: `shell`, `shell_debug`, `ha_repl`, `ha_repl_debug`, `ha_shell`
- **본 sub-task 가 다루는 결과 페이지**: `https://qahome.cubrid.org/qaresult/viewShellTestResult.nhn?shellTestId=56510&resultType=NOK` (test_shell 19 NOK).
- **용어 단축**: heap = 행 데이터를 담는 페이지 모음, B-tree 가 아닌 본문 저장소. recdes = record descriptor, heap slot 안의 직렬화된 한 행. HFID = Heap File ID, `(volume|file|page)` 로 한 heap 을 식별. MULTIPAGE_OBJECT_HEAP = 가변 큰 컬럼이 일반 heap slot 으로 안 들어갈 때 별도 multi-page 파일로 spill 되는 overflow heap chain (`enum FILE_TYPE` 정의 `src/storage/file_manager.h:43`).
- **Crashes / core dumps**: 0건. `[CORE ANALYZER]`, `SIGSEGV`, `Internal Error` 모두 없음. round-1 (CBRD-26660) 의 `bigPageSize` `peekmem_elo` SIGSEGV 는 본 라운드에서 사라졌다.

### Round-over-round 진척

| Round | Sub-task | Build | NOK | Crashes | OOS-suspected (Bucket A) |
|-------|----------|-------|-----|---------|--------------------------|
| 1 | CBRD-26660 | `11.5.0.2328-8d7b97a` | 32 | 1 (`peekmem_elo` SIGSEGV) | 12 (부모 sub-task tally 의 high-confidence OOS 의심 합계, 본 분석가 재산정 아님) |
| 2 | CBRD-26817 | `11.5.0.2334-e2a5d2b` | 16 | 0 | 11 (A 9 + B 2, round-2 sub-task tally 의 still-OOS 합계) |
| **3** | **CBRD-26832** (본 sub-task) | **`11.5.0.2338-404b396`** | **19** | **0** | **3** |

OOS 회귀 의심 건수는 round-2 의 still-OOS 11건에서 round-3 의 Bucket A 3건으로 줄었다 (round-1 의 high 12건 + round-2 의 still-OOS 11건 = 본 분석의 Bucket A 3건과 직접 비교 가능). 늘어난 잡음은 주로 카운터 flaky, dblink locale, round-2 fix 회귀 복귀에서 온다.

### Bucket A — OOS 회귀 의심 (3건)

heap overflow 체인 walker 와 catalog-driven script 의 OOS-side 변화 가능성. M2 차단 핵심.

| # | Test | Sub-case | Evidence (diff hunk) | 비고 |
|---|------|----------|---------------------|------|
| 1 | `shell/_36_damson/cbrd_23608_tde/tbl_enc_08` | -1 | `8a9,12`. `result.log` 가 4 줄 누락: `vfid = |`, `tde_algorithm: AES`, `time_creation = ?, type = MULTIPAGE_OBJECT_HEAP`, `Overflow for HFID: ...`. schema 는 `ttt (a int, b varchar(20000)) encrypt;`, payload 는 `rpad('big', 20000)` 한 행. (TC#14-16 같은 본문 truncate 아님 — diff hunk 가 답안 헤더에 들어 있어 확인됨) | round-2 의 fixed 목록에 들어 있던 항목이 다시 NOK |
| 2 | `shell/_36_damson/cbrd_23608_tde/tbl_enc_14` | -1 | `10a11,13`. TC#1 과 같은 방향. `result.log` 가 3 줄 누락: `time_creation = ?, type = MULTIPAGE_OBJECT_HEAP`, `Overflow for HFID: ...`, `tde_algorithm: AES`. schema 는 `ttt (a varchar(20000) primary key, b int) encrypt;`, payload 는 `RPAD('0', 20000, ' ')`. locale 은 `ko_KR.utf8` | round-2 의 Bucket A #8 carry-over |
| 11 | `shell/_25_unstable/_38_fig/cbrd_24916_check_index_ovfps` | -5, -6 | sub-case 2 부터 catalog SQL 자체가 깨지며 `g.x is a varchar type, not an object type` 가 매번 출력된다. 5/6 만 NOK 인 이유는 expected 값 비교에서 비-빈 값 (`idx 3blank`, `15`) 이 요구되는 sub-case 가 5/6 뿐이기 때문 (sub-case 3, 7-13 은 빈 expected 라 빈 출력과 우연히 일치) | 의심 위치는 `share/scripts/check_index_ovfps.sh` 의 catalog 조인 SQL 의 `g.x` reference |

TC#1 과 TC#2 는 한 가설로 묶을 수 있다. 두 테스트 모두 `varchar(20000)` 컬럼에 20 KB payload 한 행을 넣는다. AES 암호화 후 페이로드는 DB_PAGESIZE (기본 16 KB) 안에 못 들어가서 multi-page overflow chain (`FILE_MULTIPAGE_OBJECT_HEAP`) 한 번을 거쳐야 정상이다. round-2 까지 답안은 정확히 그 second chain 을 기대했다. round-3 의 log 는 그 chain 을 안 보여준다.

- 가설 A (OOS write 임계치 변화): OOS 가 이 시나리오에서 second multi-page chain 자체를 생성하지 않는다. 가변 데이터 크기가 `DB_PAGESIZE / 8` (16 KB 페이지 기준 약 2 KB) 임계치를 넘으면 OOS 로 빠지는 분기가 `src/storage/heap_file.c:12466` 에 있고 (`if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8)`), 이 판정이 AES wrapping 전 / 후 어느 시점에서 일어나는지에 따라 답안 chain 생성 여부가 갈린다. OOS 가 inline OID 슬롯 (`OR_OOS_INLINE_SIZE = OR_OID_SIZE + OR_BIGINT_SIZE` = 16 B, `src/base/object_representation.h:455`) 으로 만족시키면 더 이상 `FILE_MULTIPAGE_OBJECT_HEAP` 파일을 만들 일이 없어진다. 이 경우 새 표현이 옳고 answer 가 stale 이지만, TDE 테스트의 본래 의도 (overflow chain 도 AES 암호화되는지 확인) 가 사라진다.
- 가설 B (dump walker 누락): chain 은 있는데 `heap_dump` / `heap_overflow_dump` 가 OOS 가 만든 chain 까지 walk 하지 못한다. `Overflow for HFID:` 와 `MULTIPAGE_OBJECT_HEAP` 출력 사이트는 `src/storage/file_manager.c:1433-1445` 의 `case FILE_MULTIPAGE_OBJECT_HEAP` 분기에 있다. OID 치환 경로는 `heap_record_replace_oos_oids` (`src/storage/heap_file.c:7982`, 호출처 `:7932, :7942, :7961`, 헤더 `src/storage/heap_file.h:384`) 인데, dump walker 가 inline OOS OID 치환 후 chain 을 따라가지 못할 가능성. 이 경우 dump 워커 수정이 필요하다.
- TC#11 (catalog 가설): raw body 를 보면 `check_index_ovfps.sh` 의 sub-case 2 부터 모든 invocation 이 같은 `g.x is a varchar type, not an object type` 를 뱉는다 (3, 5-13). `share/scripts/check_index_ovfps.sh` 가 만드는 catalog 조인 SQL 의 `g.x` reference (= `_db_class` 또는 `_db_attribute` 의 path expression) 가 OOS 브랜치에서 해당 컬럼 타입이 object 에서 varchar 로 바뀐 자리를 만난다는 가설. `src/object/schema_system_catalog_install.cpp` 와 `*_install_query_spec.cpp` 의 최근 컬럼 타입 변경 자리를 본다.

검증 순서는 `cubrid diagdb -d1` 의 `Overflow for HFID:` 출력 사이트를 따라가서, sub-case 1 의 DB 를 보존한 상태로 `FILE_MULTIPAGE_OBJECT_HEAP` 파일이 실제 존재하는지 (`file_dump`, `cubrid spacedb`) 본다.

### Bucket B — dblink 포맷 / locale (6건)

dblink 결과 포맷 또는 parser 에러 wording 차분. OOS 데이터 경로와는 직접 관계 없음.

| # | Test | Sub-case | Evidence |
|---|------|----------|----------|
| 9 | `_25_unstable/_37_elderberry/cbrd_23843_dblink/cbrd_23843_3` | `_07_server_check-9` | `_07_server_check.log` 의 한 줄이 `In line ?, column ? before 'srv (HOST=...` 형태로 답안보다 prefix 가 더 붙어 있다. round-2 fixed 목록에서 회귀 복귀 |
| 12 | `_25_unstable/_37_elderberry/cbrd_23843_dblink/cbrd_24420_oracle` | `_09_scalar_subquery-11` | 빈 줄 1줄 누락 (`65d64`) |
| 14 | `_25_unstable/_38_fig/cbrd_24501_dblink_dml/cbrd_24501_cubrid` | -12, -16 | -16: 한글 날짜 출력 회귀 가능성 (추정 — body truncated at 131 KB QA cap, 답안 파일에서 영어 날짜 포맷 기대를 확인했으나 result.log 의 실제 한글 출력 라인은 미확보). -12: `count(*) = 900000` vs 답안 `0` (추정 — body truncated, assertion 메시지만 확보됨). 두 sub-case 모두 로컬 재현으로 raw diff 확보 필요 |
| 15 | `_25_unstable/_38_fig/cbrd_24501_dblink_dml/cbrd_24501_mysql` | `_03_mysql_dblink_dml-4` | `difference_cnt1` 컬럼 tab padding reformat |
| 16 | `_25_unstable/_38_fig/cbrd_24501_dblink_dml/cbrd_24501_mariadb` | `_04_mariadb_dblink_trigger-5` | body truncated (131 KB QA cap) — 같은 family 추정 |
| 17 | `_25_unstable/_38_fig/cbrd_24501_dblink_dml/cbrd_24501_oracle` | `_04_oracle_dblink_trigger-5` | body truncated — 같은 family 추정 |

TC#14 -12 의 `count(*)=900000` 가설 (kill remote `cub_server` 도중 격리돼야 할 행이 노출) 은 raw diff 가 확보되면 단순 locale / formatting 이 아닌 semantic 회귀라 별도 plain-bug 티켓 후보. OOS 와 무관해 보이더라도 본 sub-task close 전에 minimal repro 를 한 번 시도한다.

### Bucket C — Stat / counter 플레이키 (4건)

서버 카운터나 메모리 합계가 run-by-run 으로 흔들리는 항목. CBRD-26660 / CBRD-26817 와 같은 패턴.

| # | Test | Sub-case | Evidence |
|---|------|----------|----------|
| 4 | `_25_unstable/_39_fig_cake/cbrd_25278_memmon/cbrd_25278_option` | -3 | `first total memory [956127616] != repeated total memory [956127600]` (16 B drift). 테스트 자체가 에러 메시지에 "varies each time" 를 박아둔 자가-신고 flaky |
| 5 | `_06_issues/_17_1h/cbrd_20145_1` | -1 | `MNT_SERVER_COPY_STATS` recv size `86400` vs `90864` (round-1 에서는 +4,464 였다). `MNT_SERVER_COPY_STATS` 는 `cubrid statdump` 가 호출하는 NET_SERVER 요청 id (`src/communication/network.h:168`, 서버 핸들러 `network_sr.c:502`, 클라 진입 `network_interface_cl.c:7882`) 로 서버 측 perfmon 카운터 blob 을 클라로 복사한다. 직렬화된 카운터 블롭 크기가 run-to-run 으로 흔들리는 게 정상이라 byte 카운트는 본질적으로 drift 한다 |
| 7 | `_06_issues/_20_2h/cbrd_22803` | -2 | `Num_hit: 701 vs 700`, `Num_page_request: 778 vs 777`. round-2 Bucket A #9 의 "OOS metaclass 추가 fetch 의 정당한 회계 변화" 추정이 round-3 에서도 그대로 유효. answer 갱신 후보 |
| 18 | `_25_unstable/bug_bts_5342` | -9 | `the archive logs are not 3 after a long time`. 1-20 sub-case 중 9 만 timing flake |

### Bucket D — 결과셋 / 옵션 drift (4건)

| # | Test | Sub-case | Evidence |
|---|------|----------|----------|
| 6 | `_25_unstable/_35_cherry/issue_22015_QEWC/multi_queries_2` | -1, -2 | log 에 `4 ddd` 행이 추가로 보이고, 답안에는 있는 `4 eee` 행이 log 에 빠진다. 같은 차분이 2 hunk. MVCC (Multi-Version Concurrency Control, CUBRID 의 가시성 모델) 가시성 또는 result ordering 회귀 가능성 |
| 8 | `_03_itrack/_itrack_1000316` | -2 | `trim(both substring(t1.b from 1 for 1) from 'xx yy xx')`. QA 페이지가 131 KB 에서 잘려 diff 본체 미확보 |
| 10 | `_35_cherry/issue_21654_server_side_loaddb/bigPageSize` | -1 | 테스트 (`cubrid-testcases-private-ex/shell/_35_cherry/issue_21654_server_side_loaddb/bigPageSize/cases/bigPageSize.sh`) 는 `tdb1` 을 unload 한 뒤 server-side `loaddb` 로 `tdb2` (더 큰 page size) 에 적재하고, 같은 SELECT 를 양쪽에서 돌려 `csql1.log` (tdb1) 과 `csql2.log` (tdb2) 를 `diff` 한다. 페이지 크기 round-trip 이 깨끗했으면 diff 가 비어야 한다. 본 라운드는 비지 않다 (`diff csql1.log csql2.log failed`). 실제 hunk 는 131 KB body truncate 의 꼬리 쪽이라 로컬 재현 필요. round-2 의 fixed 목록 항목 회귀 복귀 (SIGSEGV 는 사라졌지만 csql 결과 비교가 깨짐) |
| 19 | `_25_unstable/_39_fig_cake/cbrd_25282/check_option` | -21, -23 | `unloaddb --process` valid value 36/36 두 sub-case 만 NOK. 1-20, 22, 24-47 모두 OK. CLI 옵션 파싱 회귀 가능성. round-2 fixed 목록에서 회귀 복귀 |

### Bucket E — PL/CSQL trace 카운터 (1건)

| # | Test | Sub-case | Evidence |
|---|------|----------|----------|
| 3 | `_25_unstable/_10_plcsql/cbrd_25619` | -5 | `SELECT (... fetch: 4)` / `FUNC (... fetch: 3, calls: 3)` 가 답안의 `fetch: 6` / `fetch: 5` 대신 출력. 같은 차분 2 hunk. trace counter 가 줄어든 방향이라 planner 최적화 또는 PL bridge trace 이벤트 누락 양쪽 다 가능 |

### Bucket F — medium rollup (1건)

| # | Test | Sub-case | Evidence |
|---|------|----------|----------|
| 13 | `_25_unstable/_06_issues/_20_1h/cbrd_23613_6/medium` | -1 | 단일 sub-case 가 `ctp_medium` 전체 970 SQL 실행. NOK 4건: `medium/_02_xtests/cases/6980.sql`, `medium/_05_err_x/cases/drop1.sql`, `medium/_05_err_x/cases/member1.sql`, `medium/_05_err_x/cases/pass1.sql`. 3건이 `_05_err_x` 라 에러 메시지 wording 차분일 가능성이 높지만 별도 재현 필요 |

### Round-2 회귀 복귀 5건

CBRD-26817 의 "round-1 대비 fixed 16건" 목록에 들어 있던 항목이 round-3 에서 다시 NOK 로 잡혔다. round-2 fix 의 안정성을 별도로 평가해야 한다.

| Test | Round-2 분류 | Round-3 (본 sub-task) bucket |
|------|--------------|-----------------------------|
| `bigPageSize.sh` | fixed (round-1 의 SIGSEGV 해소) | **Bucket D #10** — csql1/csql2 diff 가 비지 않음. SIGSEGV 는 안 보임 |
| `tbl_enc_08.sh` | fixed | **Bucket A #1** — TDE x OOS heap dump 누락 |
| `multi_queries_2.sh` | fixed | **Bucket D #6** — 행 ordering 차분 |
| `cbrd_23843_3.sh` | fixed | **Bucket B #9** — parser 에러 wording 차분 |
| `check_option.sh` | fixed | **Bucket D #19** — `unloaddb --process` 두 sub-case |

분포는 A 1건, B 1건, D 3건. 한 건 (`tbl_enc_08`) 이 Bucket A 의 OOS 회귀 의심으로 올라가 본 sub-task 의 핵심 조사 대상이 된다. 나머지 4건은 Recommended Next Steps 의 develop HEAD 재실행 지시에 따라 분리한다.

### Tally

- Bucket A (OOS 회귀 의심): 3
- Bucket B (dblink 포맷 / locale): 6 (그중 TC#14 -12 의 semantic 회귀는 별도 후속 후보)
- Bucket C (stat / counter 플레이키): 4
- Bucket D (결과셋 / 옵션 drift): 4 (그중 3건이 round-2 회귀 복귀)
- Bucket E (PL/CSQL trace): 1
- Bucket F (medium rollup): 1
- **Round-2 회귀 복귀 플래그**: 5건 (A 1 + B 1 + D 3)

### Recommended Next Steps

1. Bucket A 3건은 `tc/PROMPT.md` 의 작업 지침대로 진행. TC#1 / TC#2 는 한 가설로 묶어 한 번에 본다. payload 크기를 측정해 OOS 임계치 (`heap_file.c:12466` 의 `> DB_PAGESIZE/8`) 와 AES wrapping 후 record 크기의 관계를 먼저 확인하고, `FILE_MULTIPAGE_OBJECT_HEAP` 파일이 실제 생성되는지 (`cubrid spacedb`) 본 다음 `heap_overflow_dump` walker 분기로 들어간다.
2. TC#11 은 `share/scripts/check_index_ovfps.sh` 의 catalog SQL 을 csql 에 직접 붙여 `g.x` 가 어떤 catalog 컬럼을 가리키는지 잡고, 그 컬럼이 OOS 브랜치에서 type 이 바뀌었는지 `src/object/*_install_query_spec.cpp` 의 git blame 으로 본다.
3. round-2 회귀 복귀 5건 (`bigPageSize`, `tbl_enc_08`, `multi_queries_2`, `cbrd_23843_3`, `check_option`) 을 develop HEAD 단발 재실행해 진짜 코드 회귀인지 환경 차이 / answer drift 인지 분리한다 (`tbl_enc_08` 은 Bucket A 의 가설 검증과 병행).
4. Bucket B TC#14 -12 (`count(*)=900000`) 의 raw diff 를 로컬 재현으로 확보해 가설 (kill remote `cub_server` 도중 격리돼야 할 행 노출) 을 확인한다. 가설이 맞으면 별도 plain-bug minimal repro 시도, 1-row dblink + kill 시나리오로 단축 가능한지 확인.
5. Bucket B 의 truncated body 3건 (TC#14, TC#16, TC#17), Bucket D 의 truncated body 2건 (TC#8, TC#10) 은 본 브랜치에서 로컬 재현해 전체 diff 를 확보한다. QA 페이지의 131 KB cap 때문에 후반 diff 가 잘렸다.
6. Bucket C / E / F 는 본 sub-task 범위 밖. develop baseline 비교 또는 answer 갱신으로 별도 처리.

---

## 참고 파일

아래 `tc/*` 파일은 본 분석가의 로컬 작업 트리에만 존재한다. PR / branch 에는 포함되지 않는다.

- `tc/SUMMARY.md` — 19건 NOK 의 분류 요약.
- `tc/PROMPT.md` — Bucket A 3건 fix 진행을 위한 작업 지침.
- `tc/raw/tc_NN_*.txt` — 19건 TC 의 raw body, QA HTML 으로부터 추출.
- `tc/raw/shellTestId_56510_NOK.html` — 원본 QA 결과 페이지 캡처.

### 주요 의심 소스 (Bucket A)

| 파일:줄 | 성격 | 역할 |
|---|---|---|
| `src/storage/file_manager.c:1433-1445` | output site | `case FILE_MULTIPAGE_OBJECT_HEAP` 분기의 dump 출력 (`Overflow for HFID:`, `MULTIPAGE_OBJECT_HEAP`). TC#1 / TC#2 의 답안이 기대하는 줄을 실제로 찍는 자리. |
| `src/storage/heap_file.c` `heap_dump`, `heap_overflow_dump` | 의심 위치 | TC#1 / TC#2 의 overflow chain walker 진입점. OOS overflow 체인을 끝까지 walk 하는지 확인. |
| `src/storage/heap_file.c:7982` `heap_record_replace_oos_oids` | 의심 위치 | recdes 안의 inline OOS OID 슬롯을 실제 값으로 치환하는 경로. 호출처 `:7932, :7942, :7961`. 헤더 `src/storage/heap_file.h:384`. dump walker 가 같은 치환 후 chain 을 따라가지 못할 가능성. |
| `src/storage/heap_file.c:12466` | threshold 정의 | OOS write 분기의 `if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8)` 판정. AES wrapping 전 / 후 어느 시점 입력인지에 따라 second chain 생성 여부가 갈린다. |
| `src/base/object_representation.h:455` `OR_OOS_INLINE_SIZE` | threshold 정의 | OOS inline OID 슬롯 크기 매크로 (`OR_OID_SIZE + OR_BIGINT_SIZE` = 16 B). 임계치 분석의 보조 상수. |
| `src/storage/file_manager.h:43` `FILE_MULTIPAGE_OBJECT_HEAP` | threshold 정의 | `enum FILE_TYPE` 값. dump 출력 분기와 매칭 키. |
| `share/scripts/check_index_ovfps.sh` | 의심 위치 | TC#11 의 catalog 조인 SQL 빌드 사이트. `g.x` path expression 의 origin. |
| `src/object/schema_system_catalog_install.cpp`, `*_install_query_spec.cpp` | 의심 위치 | TC#11 의 `g.x` 가 가리키는 catalog 컬럼 타입 (object 에서 varchar 로 바뀐 자리 후보). |

## Remarks

- 부모 epic: CBRD-26583 (OOS M2).
- 선행 sub-task: CBRD-26660 (round-1, build `11.5.0.2328-8d7b97a`, 32 NOK), CBRD-26817 (round-2, build `11.5.0.2334-e2a5d2b`, 16 NOK).
- Round-3 fix 들어간 sub-task (round-2 와의 차이): CBRD-26815 (OOS JSON deserialize), CBRD-26813 (`REC_BIGONE` reassembly 후 OOS OID 확장), CBRD-26814 (OOS inline metadata fit 검사) 등. round-2 의 still-OOS 11건 중 LOB / ELO 클러스터 7건 + `json_long_body.sh` + `cbrd_23430.sh` (round-2 의 Bucket B 신규 OOS 의심 2건) 가 본 라운드에서 모두 사라졌다.
- 관련 티켓: CBRD-26516 (UPDATE 가 `heap_record_replace_oos_oids` 를 3x 호출), CBRD-26517 (OOS TODO), CBRD-26830 (OOS TDE plaintext leak), CBRD-26831 (numerable file with OOS).
- 본 sub-task 자체는 분석 / triage 추적용. Bucket A 의 OOS 회귀 fix PR 은 별도 sub-task 또는 본 sub-task 산하 후속 티켓에서 다룬다.
- 본 빌드의 다른 카테고리 (`shell_debug`, `ha_repl`, `ha_repl_debug`, `ha_shell`) 결과는 본 sub-task 에서 수집하지 않았다.
