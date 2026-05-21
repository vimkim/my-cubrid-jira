# [OOS] [Regression] bug_bts_14917 shell test 가 OOS 모드에서 NOK

## Issue Triage

**이슈 수행 목적** (필수): `bug_bts_14917` shell test 가 OOS 빌드에서도 CTP timeout 안에 OK 로 닫히도록 한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 외부 page 로 분리해 저장하는 방식) 가 들어온 뒤 이 test 는 두 단계로 무너진다. 한 testcase 의 시간 상한은 CTP `shell_ci.conf` 의 `testcase_timeout_in_secs = 720` 초다.
  - 1 단계 (해소됨): iter 1 에서 deterministic 하게 false `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2` 가 떠 test 가 약 18 초 만에 죽었다. [CBRD-26815] 두 commit 으로 닫혔다. 자세한 메커니즘은 아래 "1 단계 fix" 절을 본다.
  - 2 단계 (미해소): row 한 줄 INSERT 가 iter 진행에 따라 iter 0 297 ms 에서 iter 9 1033 ms 로 약 3.5 배 증가한다. 그래서 100 iter 가 720 초 안에 못 끝난다. 측정과 가설은 아래 "2 단계 측정 결과", "Suspects" 절을 본다.
- **영향**:
  - QA: OOS 가 켜진 CircleCI shell stage 가 항상 빨강이다. 이 한 testcase 가 NOK 로 닫힌다.
  - Gating: 단일 test 의 NOK 가 PR 전체를 막는다.

**이슈 수행 방안**:

- 1 단계는 이미 [CBRD-26815] 의 두 commit 으로 fix 했다. 본 ticket 에서는 회귀 검증만 한다.
  - `scan_next_index_lookup_heap` 의 두 번째 fetch 직전에 `recdes.data = NULL` 을 넣는다.
  - `locator_lock_and_get_object_with_evaluation` 에 `bool skip_oos_expand` parameter 를 추가한다. 이 caller 만 `true` 로 부른다. 나머지 caller (UPDATE force / DELETE force / `qexec_execute_selupd_list` / `scan_next_heap_scan`) 는 호환을 위해 `false` 로 둔다.
- 2 단계는 dominant cost 후보를 한 가지로 좁혀서 시작한다 — `oos_stats_sync_bestspace` (`src/storage/oos_file.cpp:634`) 의 per-chunk 호출 빈도와 page-fix cost. 자세한 근거와 측정 계획은 아래 "2 단계 측정 결과", "Suspects" 절에 둔다.
- 회피책은 채택하지 않는다. timeout 을 올리거나 본 test 를 CI 에서 빼는 식으로 닫지 않는다.
- 2 단계의 구체적 fix 형태 (cache 정책 변경, 대용량 blob 전용 fast-path, file allocation hint 등): `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 hand-off 문서를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 만으로 충분하다. 본문은 구현·리뷰 단계의 reference 다.

### Summary

| 항목 | 내용 |
|---|---|
| 형태 | OOS 켠 뒤 `bug_bts_14917` 이 두 단계로 실패 |
| 1 단계 | iter 1 에서 false `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2`. [CBRD-26815] 두 commit 으로 해소 |
| 2 단계 | OOS 파일이 커질수록 row 당 INSERT 시간이 늘어 720 초 timeout 에 걸림. 미해소 |
| 영향 | OOS 가 켜진 CircleCI shell stage 가 항상 빨강. 기능 정합성에는 영향 없음 |
| 호환성 | [CBRD-26815] patch 의 새 parameter `skip_oos_expand` default 가 `false` 라 비-OOS 경로 동작은 그대로 |

### 용어 정의 (workload 단위)

본문에서 unit 을 헷갈리지 않도록 한 곳에 모은다.

- **loop**: Java workload 의 outer 반복. 1 loop = INSERT 20 row + DELETE 1 회. 100 loop 가 한 testcase.
- **iter**: probe script 의 측정 단위. 1 iter = 1 loop 와 같다. 본문에서는 동의어로 쓴다 (probe 가 곧 workload 의 한 loop 를 모사).
- **chunk**: 한 OOS record 를 page 단위로 쪼갠 조각. 3 MB blob 1 건 = 약 200 chunk.

---

## Description

이 ticket 은 `feat/oos` 도입 후 `bug_bts_14917` (`cubrid-testcases-private-ex/shell/_06_issues/_14_2h/bug_bts_14917`) 가 NOK 로 돌아선 회귀를 추적한다. Test workload 는 Java client 에서 다음을 100 회 반복한다.

```
image table: PK (doc_id, image_id), image column BIT VARYING(83886080)
loop 100:
  INSERT 20 rows, image = 3 MB blob, all doc_id = 'aaaaa'
  DELETE WHERE doc_id = 'aaaaa'
```

3 MB blob 한 건은 `oos_insert` -> `oos_insert_across_pages` 경로를 따라 page 여러 개에 chunk 단위로 쪼개져 들어간다. chunk 수는 정확히는 `oos_get_max_chunk_size_within_page()` (`src/storage/oos_file.cpp:1805-1811`) 가 돌려주는 값에 좌우되는데, 이 값은 `DB_ALIGN_BELOW(spage_max_record_size(), OOS_ALIGNMENT) - sizeof(OOS_RECORD_HEADER)` 로, 16 KB page 에서 page header / slot table / OOS record header 를 뺀 나머지다. 따라서 3 MB / 16 KB = 192 는 **하한** 이고, 실제 chunk 수는 overhead 만큼 더 늘어 약 195~200 사이다. 본문에서 "약 200 chunk" 라고 쓴다. 실측은 statdump 의 `Num_data_page_fetches` delta 로 가능하다.

회귀는 두 결함이 직렬로 노출되는 형태다. 두 결함을 따로 본다.

### 1 단계 — false btree-heap inconsistency (해소)

**한 줄 요약**: index scan 이 OOS 확장에 실패하면서 그 실패를 "btree 가 깨졌다" 로 잘못 보고했다. Buffer 재할당이 막힌 게 진짜 원인이었다.

메커니즘은 다음과 같다.

1. `scan_next_index_lookup_heap` 이 같은 OID 를 두 번 읽는다. 첫 번째는 visibility check 용 `heap_get_visible_version_skip_oos_expand` (`scan_manager.c:6311`), 두 번째는 lock 을 잡고 다시 가져오는 `locator_lock_and_get_object_with_evaluation` (`scan_manager.c:6375`) 다.
2. 두 호출은 같은 `RECDES recdes` 를 공유한다. `recdes.data` 초기화는 `scan_manager.c:6305-6308` 에서 하지만, `scan_id->fixed == false` 일 때만 한다. PEEK 경로 (`scan_id->fixed == true`) 에서는 첫 fetch 가 끝나면 `recdes.data` 가 scan_cache buffer 안쪽을 가리킨 채 남는다.
3. 그 leftover 가 두 번째 fetch 로 흘러간다. 내부 `heap_init_get_context` (`heap_file.c:27024`) 는 `recdes->data != NULL` 을 보고 `data_externally_positioned = true` 로 굳힌다. "이 buffer 는 caller 가 직접 잡은 거니 건드리지 마라" 는 뜻이다.
4. 그 상태에서 3 MB OOS 확장이 필요해지면 `heap_record_replace_oos_oids` (`heap_file.c:8184-8188`) 가 재할당을 거부하고 `S_DOESNT_FIT` (caller 가 넘긴 buffer 가 record 를 담기에 작을 때의 SCAN_CODE) 을 반환한다.
5. 호출 stack 위에서 이 코드가 `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2` 로 오역돼 "btree-heap inconsistent" false positive 가 표면화된다.

**Fix 두 줄 요약**: (a) PEEK 경로에서도 두 번째 fetch 직전에 `recdes.data = NULL` 을 박는다. (b) 이 caller 는 어차피 record 전체 확장본을 안 쓰므로 `skip_oos_expand = true` 로 우회한다.

#### Call site 표

`skip_oos_expand` parameter 가 새로 생긴 caller 목록이다.

| Caller | 값 | 근거 |
|---|---|---|
| `scan_next_index_lookup_heap` (`scan_manager.c:6375`) | `true` | hot path. 다음 단계 `heap_attrinfo_read_dbvalues` (attribute 단위 fetch 진입점) 가 attribute 별로 OOS 를 확장하므로 caller 는 record 전체 확장본을 쓸 일이 없다. 매 row 마다 3 MB+ blob 을 복사하지 않아도 된다 |
| `scan_next_heap_scan` (`scan_manager.c:5545`) | `false` | 이 경로는 `locator_lock_and_get_object_with_evaluation` 호출 직전에 `recdes.data = NULL` 을 명시적으로 reset 한다 (`scan_manager.c:5540` 부근). 그래서 1 단계 bug 패턴은 노출되지 않는다. `skip_oos_expand=true` 로 바꾸면 record-level 확장 비용을 아낄 수 있으나 별도 ticket 에서 평가한다 |
| `qexec_execute_selupd_list` (`query_executor.c:14079`) | `false` | SELECT FOR UPDATE 경로. 보수 유지 |
| UPDATE force (`locator_sr.c:5796`) | `false` | index update 에 full record 가 필요 |
| DELETE force (`locator_sr.c:6285`) | `false` | index update 에 full record 가 필요 |

### 2 단계 — INSERT time growth (미해소)

**한 줄 요약**: OOS 파일이 자랄수록 row 한 줄 INSERT 가 점점 느려진다. iter 9 에서는 iter 0 의 약 3.5 배다. 100 iter 를 720 초 안에 끝낼 수 없다.

#### 측정 결과

세 가지 controlled probe 의 per-row INSERT 시간. 단위는 ms/row 다.

| iter | 20 m log, with DELETE | 100 m log, with DELETE | 20 m log, INSERT only |
|---:|---:|---:|---:|
| 0 | 297 | 299 | 286 |
| 1 | 600 | 588 | 570 |
| 2 | 727 | 707 | 669 |
| 5 | 888 | 869 | 857 |
| 9 | 1033 | 1017 | 1012 |

본 ticket 의 canonical baseline 은 `with DELETE` column 의 iter 0 = 297 ms 다 — 운영 workload 가 DELETE 를 포함하기 때문이다. INSERT-only column 의 iter 0 = 286 ms 는 DELETE 부재로 약 11 ms 낮을 뿐 곡선 형태는 같다.

증가 형태는 iter index 에 대해 sub-linear 다 (iter 9 까지 약 3.5 배). 정확한 함수형은 미정이지만, 형태 자체가 "OOS 파일이 클수록 더 비싸지는 동작" 의 존재를 시사한다.

위 data 로 다음 의심들을 정리한다.

| 의심 | 상태 | 근거 |
|---|---|---|
| WAL rotation 빈도 | 배제 | log 를 20 MB -> 100 MB 로 5 배 키워도 iter 9 차이가 5 % 미만 |
| DELETE-induced tombstone fragmentation | 배제 | DELETE 빼고 매 iter unique `doc_id` 로 INSERT-only 돌려도 동일한 곡선 |
| VACUUM cost on INSERT-only workload | 미검증 | INSERT-only probe 는 MVCC tombstone 자체가 안 생기므로 VACUUM hypothesis 를 testing 하지 않는다. 별도 probe 필요 |

남는 가설은 **OOS-insert 경로 자체가 OOS 파일 page 수에 따라 비싸진다** 이다. 이 동작이 chunk 마다 호출되므로 3 MB blob 1 건당 약 200 회 곱해진다.

#### Hot path

```
oos_insert  (src/storage/oos_file.cpp:1048)
└── oos_insert_across_pages  (oos_file.cpp:1108)
    └── chunk 약 200 회:
        └── oos_insert_within_page  (oos_file.cpp:1205)
            ├── oos_find_best_page  (oos_file.cpp:1460)
            │   ├── phase A: hash cache lookup
            │   ├── phase B: best[] array scan
            │   ├── phase C: conditional latch try
            │   └── fallback: oos_stats_sync_bestspace  (oos_file.cpp:634)
            ├── spage_insert
            ├── oos_log_insert_physical  (WAL)
            └── oos_stats_add_bestspace  (hash insert)
```

`oos_stats_sync_bestspace` 한 번이 fix 하는 page 수는 `min(total_pages * 0.2, oos_Find_best_page_limit)`, floor 10 이다 (`oos_file.cpp:659-667`). `oos_Find_best_page_limit` 은 100 이다. 즉 OOS 파일이 500 page 를 넘으면 cap 이 100 에 걸린다.

#### Suspects (우선순위 순)

본 ticket 의 분석 출발점은 suspect 1 이다. Suspect 2~4 는 #1 이 dominant 가 아닐 때를 위한 **fallback hypotheses** 다 (Issue Triage 의 "한 가지로 좁힌다" 와 정렬).

1. **`oos_stats_sync_bestspace` 호출 빈도가 dominant** — 본 workload 의 OOS chunk 는 page 를 거의 꽉 채운다. 한 번 cache 에 들어간 page 는 남은 free space 가 page 크기의 30 % 이하로 떨어지면 bestspace cache 에서 drop 되는 cutoff (`OOS_DROP_FREE_SPACE = DB_PAGESIZE * 0.3`) 에 걸려 evict 된다. 그래서 cache 가 iter 사이에 cold 로 남고 sync 가 자주 일어난다.
   - 비용 모형: `oos_find_best_page` 의 `while (try_find < 2)` loop (`oos_file.cpp:1495`) 에서 sync 가 호출된다. Sync 1 회는 위 cap 공식대로 최대 100 page 에 `pgbuf_fix` 호출을 건다 (page 를 buffer pool 에 고정해 access 권한을 잡는 호출). latch mode 는 READ + CONDITIONAL 이라 다른 latch holder 와 충돌하면 skip 된다.
   - chunk 당 sync 빈도 추정: phase A (hash) + phase B (best[]) 가 둘 다 miss 일 때만 sync 가 돈다. 연속된 chunk 는 직전 chunk 가 막 insert 한 page 에 hash 가 hit 할 가능성이 높으므로, page 1 장이 가득 찰 때 한 번씩 miss 가 나는 모형이 더 현실적이다. 3 MB blob 1 건이 약 200 chunk = 약 200 distinct page 에 떨어진다고 보면, sync 호출의 현실적 상한은 blob 1 건당 200 회보다 훨씬 작은 수십 회 수준이다. "chunk 마다 sync 100-page fix" 는 절대 worst case 이고, 실제는 statdump 의 `Num_data_page_fetches` delta 와 sync 호출 counter (없으면 추가) 로 측정해 좁힌다.
   - 1 loop (20 row, 3 MB row 당 200 chunk) 면 chunk 수만 약 4 000 회다. sync hit rate 가 5 % 라도 sync 1 회당 100 page-fix 이므로 loop 당 20 000 추가 page-fix 가 더 붙는다.
2. **`file_alloc` 의 sector bitmap scan** — OOS 파일이 10 iter 사이에 0 에서 약 38 000 page 까지 자란다. `file_alloc_in_volume` 의 free-page 탐색이 file 크기에 linear 한 cost 라면 본 곡선과 일치한다. `src/storage/file_manager.cpp` 의 `file_alloc` callee 들을 small vs large 비교로 확인한다.
3. **Page buffer churn** — `PRM_ID_PB_NBUFFERS` default 가 약 20 K page (16 KB x 20 K = 320 MB) 다. OOS 파일 단독이 iter 4 에서 240 MB 에 도달하므로 working-set 이 pool 에 근접한다. `cubrid statdump` 의 `Num_data_page_dirty_to_disk`, `Num_data_page_victims` 추세로 검증한다.
4. **WAL append bookkeeping** — Rotation 빈도는 배제됐지만 append path 자체 (LSA — `LOG_LSA`, WAL record 위치 = (page_id, offset) 쌍) 가 log volume 누적에 따라 비용이 늘 수 있다. 우선순위는 낮다.

### Test Build

- OS: Linux 5.14.0-570.30.1.el9_6.x86_64
- Build: local debug, clang (`/home/vimkim/.cub/install/oos-bug-14917/debug_clang`)
- Branch: `vk/cbrd-26824-shell-ci-fixes`, base HEAD `b19f88f70`
- Patches: [CBRD-26815] 두 변경 (현재 worktree, uncommitted)

---

## Repro

CTP 전체 재현:

```bash
ctp.sh shell -c shell_ci.conf
# shell_ci.conf 의 scenario 를 다음 한 경로로 좁힌다:
#   /home/vimkim/cubrid-testcases-private-ex/shell/_06_issues/_14_2h/bug_bts_14917
```

CTP 외 minimal probe (INSERT-only growth 만 보고 싶을 때):

```bash
ITERS=10 bash /tmp/probe_insert_only.sh
# 또는
LOG_SIZE=20m ITERS=10 bash /tmp/probe_oos_insert.sh
```

Probe script 는 3 MB BIT VARYING blob 20 row INSERT (선택적으로 DELETE WHERE doc_id) 를 ITERS 회 반복하고 row 당 ms 를 출력한다.

statdump diff (slow iter 의 어떤 counter 가 fast iter 대비 증가했는지):

```bash
cubrid statdump -i 0 probe                # 기준
ITERS=2 bash /tmp/probe_oos_insert.sh &
sleep 5;  cubrid statdump probe > /tmp/sd_iter0.txt
sleep 8;  cubrid statdump probe > /tmp/sd_iter1.txt
diff /tmp/sd_iter0.txt /tmp/sd_iter1.txt | head -200
```

위 명령은 raw diff 의 앞 200 줄을 그대로 보여 준다. statdump 는 `Num_data_page_fetches: 12345` 같은 줄을 찍으므로 raw diff 를 한 번 훑어 어떤 counter 가 늘었는지 직접 보는 게 안전하다 (counter 줄에 ':' 가 있어 단순 regex 로 거르면 누락이 난다).

`perf` profile (debug build 라 symbol 이 있다):

```bash
perf record -F 999 -g -p $(pgrep cub_server) -- sleep 30
perf report --stdio | head -60
```

---

## Expected Result

- `bug_bts_14917` 가 OOS 빌드 + CTP `shell_ci.conf` 의 720 초 timeout 안에서 `pass=1 fail=0` 으로 닫힌다.
- Pre-OOS develop branch 와 동일한 deterministic OK 상태로 회복한다.

---

## Actual Result

- Pre-fix: iter 1 에서 deterministic 하게 `cubrid.jdbc.driver.CUBRIDException: Internal error: INDEX pk_image_doc_id_image_id ... entry on B+tree: 1|512|513 is incorrect. The object does not exist.` 로 fail. Test 종료까지 약 18 초.
- [CBRD-26815] patch 후: false inconsistency 가 사라진다. 다만 row 당 INSERT 가 iter 0 약 297 ms 에서 iter 9 약 1033 ms 까지 단조 증가하므로, iter 20~25 부근에서 CTP 가 720 초 timeout 으로 process 를 죽인다.
- 진행 로그 예시 (loop 한 번 = 20 row INSERT 한 batch 의 총합 시간):

| loop | INSERT 총합 | DELETE 총합 | INSERT row 당 환산 |
|---:|---:|---:|---:|
| 0 | 5.7 s | 0.08 s | 285 ms |
| 10 | 21.0 s | 0.06 s | 1050 ms |
| 20 | 34.1 s | 0.09 s | 1705 ms |

위 row-당 환산은 5.7 / 20 = 285 ms 식으로 계산한 값이며 측정 표 (iter 0 = 297 ms) 와 일치한다.

---

## Additional Information

- Probe data: `/tmp/probe_20m.log`, `/tmp/probe_100m.log`, `/tmp/probe_insert_only.log`
- Probe scripts: `/tmp/probe_oos_insert.sh`, `/tmp/probe_insert_only.sh`, `/tmp/min_repro_14917/repro.sh`
- 관련 ticket: [CBRD-26815] (1 단계 engine fix 의 commit tag), [CBRD-26658] (OOS 3-tier bestspace 메커니즘 — suspect #1 이 이 구조를 다룬다), [CBRD-26583] (M2 epic, parent)

---

## 참고 코드

| 파일 / 위치 | 설명 |
|---|---|
| `src/query/scan_manager.c:6305-6308 (PEEK 분기 reset 누락), 6311 (first fetch), 6370 (두 번째 fetch 전 reset 추가), 6375 (skip_oos_expand=true 전달)` | 1 단계 fix 의 call site |
| `src/transaction/locator_sr.h:119`, `locator_sr.c:13257..13300` | `skip_oos_expand` parameter 신설과 `context.expand_oos = false` 설정부 |
| `src/storage/heap_file.c:8184-8188 (재할당 거부 gate), 27024 (data_externally_positioned set)` | 1 단계 원인 site |
| `src/storage/oos_file.cpp:87 (OOS_DROP_FREE_SPACE 정의), 118 (oos_Find_best_page_limit), 634..760 (sync 본체), 659-667 (cap 공식 min(0.2*N, 100), floor 10), 1805-1811 (max_chunk_size impl)` | 2 단계 suspect #1 의 핵심 |
| `src/storage/oos_file.cpp:1048 (oos_insert), 1108 (across_pages), 1205 (within_page), 1460 (find_best_page), 1495 (sync loop)` | OOS insert hot path |
| `src/storage/file_manager.cpp` (`file_alloc`, `file_alloc_in_volume`) | 2 단계 suspect #2 |

---

## Remarks

- 1 단계 engine fix 의 commit tag 는 [CBRD-26815] 다 (밑단의 OOS work 시리즈와 같은 계열). 본 ticket 은 shell-CI regression 추적 sub-task 로 유지하고, 1 단계 회귀 검증과 2 단계 fix 두 가지를 닫는다.
- 사용자 정책: "분석을 계속한다" 가 "timeout 을 올린다" 또는 "NOK 를 수용한다" 보다 우선이다. 회피책은 채택하지 않는다는 위 방안 bullet 의 근거다.
- 2 단계 fix 가 알고리즘에 내재한 비용으로 결론나면 그 시점에 사용자에게 재상신해 (a) test workload 조정, (b) timeout 상향, (c) 본 ticket close + 별도 long-term tracking 중 결정한다.
- Local-only note: CTP 는 `~/.bash_profile` -> `~/.bashrc` 의 `$CUBRID = ~/CUBRID` 를 쓴다. rebuild 후에는 `~/CUBRID` 와 `~/.CUBRID_SHELL_FM` (CTP shell test 가 사용하는 fixture / work directory) 을 새 빌드 결과와 다시 맞춰야 한다. 안 맞추면 옛 binary 가 그대로 돈다.
