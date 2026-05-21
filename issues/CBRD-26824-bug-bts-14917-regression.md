# [OOS] [Regression] bug_bts_14917 shell test 가 OOS 모드에서 NOK

## Issue Triage

**이슈 수행 목적** (필수): `bug_bts_14917` shell test 가 OOS enabled 빌드에서도 CTP timeout 안에 OK 로 닫히도록 한다.

**이슈 수행 이유** (필수):

- **현재 동작 / 배경**: OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 외부 page 로 분리하는 저장 방식) 도입 이후 본 test 는 두 단계로 무너진다.
  - 1 단계 (deterministic, iter 1 에서 실패): `scan_next_index_lookup_heap` (`src/query/scan_manager.c:6375`) 가 직전에 호출한 `heap_get_visible_version_skip_oos_expand` 가 채워 놓은 `recdes.data` 를 비우지 않은 채 `locator_lock_and_get_object_with_evaluation` 로 넘긴다. 내부의 `heap_init_get_context` (`src/storage/heap_file.c:27024`) 가 `recdes->data != NULL` 을 보고 `data_externally_positioned = true` 로 고정해 버리므로, 3 MB OOS 확장이 필요해진 순간 `heap_record_replace_oos_oids` (`src/storage/heap_file.c:8184-8188`) 가 buffer 재할당을 거부하며 `S_DOESNT_FIT` (record 가 들어갈 자리가 없을 때의 SCAN_CODE) 를 반환한다. 호출 stack 위에서 이 코드가 `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2` 로 오역돼 "btree-heap inconsistent" 라는 false positive 가 표면화된다.
  - 2 단계 (1 단계 patch 후): row 단위 INSERT 시간이 OOS 파일 크기에 따라 단조 증가한다. 측정상 iter 0 에서 297 ms 이던 것이 iter 9 에서 1033 ms 까지 약 3.5x 로 늘어났다.
- **영향**: QA 실패 — CTP `shell_ci.conf` 의 `testcase_timeout_in_secs = 720` (한 testcase 의 시간 상한, 초 단위) 안에 Java workload 의 100 iter 가 끝나지 못하므로 본 test 는 NOK 로 닫히고, OOS 가 활성화된 CircleCI shell stage 가 지속적으로 빨강에 머문다. 본 test 만 단독으로 timeout 을 넘기지만 CI gating 효과는 PR 전체에 미친다.

**이슈 수행 방안**:

- 1 단계 (deterministic engine bug) 는 [CBRD-26815] 의 두 변경으로 이미 해소했으므로, 본 ticket 에서는 재발 방지 회귀로만 검증한다.
  - `scan_next_index_lookup_heap` 의 두 번째 heap fetch 직전에 `recdes.data = NULL` reset 을 박는다.
  - `locator_lock_and_get_object_with_evaluation` 에 `bool skip_oos_expand` parameter 를 신설한다. UPDATE force / DELETE force / `qexec_execute_selupd_list` / `scan_next_heap_scan` 는 `false` 로, `scan_next_index_lookup_heap` 만 `true` 로 호출한다 (다운스트림 `heap_attrinfo_read_dbvalues` 가 attribute 단위로 OOS 확장을 처리하므로 caller 가 record 단위 확장본을 쓸 일이 없기 때문이다).
- 2 단계 (INSERT-time growth) 는 dominant cost 부터 식별한 뒤 수정한다. 측정 출발점은 합의된 가설 한 가지로 좁힌다 — `oos_find_best_page` (`src/storage/oos_file.cpp:1460`) 가 hash cache 와 best[] 양쪽에서 miss 한 뒤 호출하는 `oos_stats_sync_bestspace` (`src/storage/oos_file.cpp:634`) 의 per-chunk 호출 빈도와 page-fix cost. DB_PAGESIZE 가 16 KB 인 기본 환경에서 3 MB blob 한 건은 약 192 chunk 로 쪼개지고, sync 1 회는 최대 100 page 까지 `pgbuf_fix(... PGBUF_LATCH_READ, PGBUF_CONDITIONAL_LATCH)` (page 를 buffer pool 에 고정해 access 권한을 잡는 호출) 를 수행하므로, 최악의 경우 chunk 당 100 추가 page-fix 가 발생할 수 있다. 본 workload 의 OOS chunk 는 page 를 거의 꽉 채워 `OOS_DROP_FREE_SPACE` (free space 가 page 의 30 % 이하로 떨어지면 cache 에서 제외되는 cutoff) 아래로 곧장 떨어지므로 cache 가 iter 사이에 cold 상태로 남는다는 점이 호출 빈도 가설을 뒷받침한다.
- 위 가설이 dominant 가 아닐 경우 후순위 의심 (file manager 의 sector bitmap scan in `file_alloc`, page buffer 의 working-set thrash, log-append 의 archive bookkeeping) 으로 옮겨 간다. 각 단계마다 statdump diff 와 `perf record` 로 evidence 를 모은 뒤 fix 한다.
- 회피책은 채택하지 않는다 — 즉 `testcase_timeout_in_secs` 상향이나 본 test 의 CI 제외로 닫지 않는다 (사용자 인용: "keep digging" over "bump the timeout" or "accept NOK"). 단, 분석 결과 cost 가 algorithmically inherent 로 판명되면 그 시점에 사용자에게 재상신한다.
- 2 단계의 구체적 fix 형태 (cache 정책 변경, 대용량 blob 전용 fast-path, 새 file allocation hint 등): `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 hand-off 문서를 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현과 리뷰 단계의 reference 로 참고하면 된다.

### Summary

- **문제 형태**: OOS 활성화 후 `bug_bts_14917` 이 두 단계로 실패한다 — (1) iter 1 에서 false `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2`, (2) patch 후에도 OOS 파일이 커질수록 row 당 INSERT 시간이 단조 증가해 CTP 720 s timeout 에 걸린다.
- **현재 진척**: 1 단계는 [CBRD-26815] commit 두 건으로 해소했다. 2 단계는 미해결.
- **영향 범위**: OOS 활성화 CircleCI shell stage 가 본 test 때문에 항상 빨강이다. 기능 정합성에는 영향이 없고 QA gating 만 차단한다.
- **호환성**: [CBRD-26815] patch 는 기존 비-OOS 경로 동작을 바꾸지 않도록 `skip_oos_expand = false` 를 default 로 둔다.

---

## Description

본 ticket 은 `feat/oos` 도입 이후 `bug_bts_14917` (`cubrid-testcases-private-ex/shell/_06_issues/_14_2h/bug_bts_14917`) 가 NOK 로 바뀐 회귀를 추적한다. Test workload 는 Java client 에서 다음을 100 회 반복한다.

```
image table: PK (doc_id, image_id), image column BIT VARYING(83886080)
loop 100:
  INSERT 20 rows, image = 3 MB blob, all doc_id = 'aaaaa'
  DELETE WHERE doc_id = 'aaaaa'
```

3 MB blob 한 건은 `oos_insert` -> `oos_insert_across_pages` 경로를 따라 약 192 chunk 로 쪼개져 OOS 파일에 기록된다 (DB_PAGESIZE 16 KB 기준).

회귀는 두 결함이 직렬로 노출되는 형태다.

**1 단계 — false btree-heap inconsistency (해소).** OOS 확장 직전 `recdes.data` 가 leftover non-NULL 인 채 `locator_lock_and_get_object_with_evaluation` 로 전달돼 inner reallocation 이 막히고, `S_DOESNT_FIT` 반환이 호출자에서 `ER_LC_INCONSISTENT_BTREE_ENTRY_TYPE2` 로 오역된다. Root cause 와 fix 는 [CBRD-26815] 에서 다룬다.

**2 단계 — INSERT time growth (미해소).** 1 단계 patch 후 test 는 iter 1 에서 죽지는 않지만, row 당 INSERT cost 가 OOS 파일 크기를 따라 선형 또는 그 이상으로 증가하므로 CTP 720 s 안에 100 iter 를 끝낼 수 없다.

### 1 단계 fix 의 call site

`scan_next_index_lookup_heap` 안에서 `heap_get_visible_version_skip_oos_expand` 다음에 같은 `recdes` (record descriptor — heap 에서 읽은 raw record 의 buffer 와 크기를 들고 다니는 구조체) 를 재사용하는 두 번째 fetch (`locator_lock_and_get_object_with_evaluation`) 직전에 `recdes.data = NULL` 을 reset 한다. 동시에 `locator_lock_and_get_object_with_evaluation` 에 `skip_oos_expand` parameter 를 추가해, OOS 확장이 불필요한 caller 가 명시적으로 우회할 수 있도록 한다.

| Caller | `skip_oos_expand` | 근거 |
|---|---|---|
| `scan_next_heap_scan` (`scan_manager.c:5545`) | `false` | 보수 유지. recdes 가 다운스트림으로 흘러간다. |
| `scan_next_index_lookup_heap` (`scan_manager.c:6375`) | `true` | hot path. caller 는 확장본을 쓰지 않고, `heap_attrinfo_read_dbvalues` (attribute 단위 fetch 진입점) 가 attribute 단위로 OOS 를 확장한다. |
| `qexec_execute_selupd_list` (`query_executor.c:14079`) | `false` | SELECT FOR UPDATE 경로. 보수 유지. |
| UPDATE force (`locator_sr.c:5796`) | `false` | index update 위해 full record 가 필요. |
| DELETE force (`locator_sr.c:6285`) | `false` | index update 위해 full record 가 필요. |

### 2 단계 측정 결과

`/tmp/probe_oos_insert.sh` (WAL — Write-Ahead Log, 20 MB), `/tmp/probe_100m.log` (WAL 100 MB), `/tmp/probe_insert_only.sh` (DELETE 제거, unique `doc_id`) 의 세 가지 controlled probe 로 측정한 per-row INSERT 시간이다.

| iter | 20 m log, with DELETE | 100 m log, with DELETE | 20 m log, INSERT only |
|---:|---:|---:|---:|
| 0 | 297 ms | 299 ms | 286 ms |
| 1 | 600 ms | 588 ms | 570 ms |
| 2 | 727 ms | 707 ms | 669 ms |
| 5 | 888 ms | 869 ms | 857 ms |
| 9 | 1033 ms | 1017 ms | 1012 ms |

두 가지 의심을 위 data 로 배제했다.

- **WAL rotation 빈도는 dominant 가 아니다.** 20 MB -> 100 MB 로 log 를 5 배 키워도 (rotation 빈도가 약 1/5 로 줄어듦) iter 9 의 차이가 5 % 미만이다.
- **DELETE / VACUUM / tombstone fragmentation 도 dominant 가 아니다.** DELETE 를 빼고 매 iter 마다 unique `doc_id` 로 INSERT-only 만 돌려도 동일한 증가 곡선이 나오기 때문이다.

남은 가설은 **OOS-insert 경로 자체가 OOS 파일의 page count 에 따라 cost 가 늘어나는 동작을 갖는다** 이다. 그 동작이 chunk 당 호출되므로 3 MB blob 1 건당 약 192 회 곱해진다.

### Hot path

```
oos_insert  (src/storage/oos_file.cpp:1048)
└── oos_insert_across_pages  (oos_file.cpp:1108)
    └── chunk 약 192 회:
        └── oos_insert_within_page  (oos_file.cpp:1205)
            ├── oos_find_best_page  (oos_file.cpp:1460)
            │   ├── phase A: hash cache lookup
            │   ├── phase B: best[] array scan
            │   ├── phase C: conditional latch try
            │   └── fallback: oos_stats_sync_bestspace  (oos_file.cpp:634, up to 100 page-fix per call)
            ├── spage_insert
            ├── oos_log_insert_physical  (WAL)
            └── oos_stats_add_bestspace  (hash insert)
```

### Suspects (우선순위 순)

1. **`oos_stats_sync_bestspace` 호출 빈도** — 본 workload 의 OOS chunk 는 약 16 KB 라 page 를 거의 꽉 채운다. cache 에 등록된 page 는 `OOS_DROP_FREE_SPACE` (30 % of page) 아래로 떨어져 다음 lookup 에서 evict 된다. 결과적으로 cache 가 iter 사이에 cold 로 남고 sync 가 자주 발생한다. Sync 1 회당 최대 100 page 에 대해 `pgbuf_fix` -> `spage_max_space_for_new_record` -> `spage_collect_statistics` -> unfix 가 일어나므로, chunk 당 sync 1 회 가정 시 3 MB blob 1 건 = 192 chunk x 100 fix = 최대 19 200 추가 page-fix 다. 20 row/iter 이면 iter 당 최대 384 000 추가 fix.
2. **`file_alloc` 의 sector bitmap scan** — OOS 파일이 10 iter 사이에 0 에서 약 38 000 page 로 자라므로, `file_alloc_in_volume` 의 free-page 탐색이 file 크기에 linear 한 cost 를 갖는다면 본 곡선과 일치한다. `src/storage/file_manager.cpp` 의 `file_alloc` callees 를 small vs large 비교로 확인한다.
3. **Page buffer churn** — `PRM_ID_PB_NBUFFERS` default 가 약 20 K page (16 KB x 20 K = 320 MB) 다. OOS 파일 단독이 iter 4 에서 240 MB 에 도달하므로 working-set 이 pool 에 근접한다. `cubrid statdump` 의 `Num_data_page_dirty_to_disk`, `Num_data_page_victims` 추세로 검증한다.
4. **WAL append bookkeeping** — Rotation 빈도는 배제됐지만 append path 자체 (LSA — Log Sequence Address table, archive page tracking) 가 log volume 누적에 따라 비용이 늘 수 있다. 우선순위는 낮다.

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
diff /tmp/sd_iter0.txt /tmp/sd_iter1.txt | grep -E "[0-9]+$"
```

`perf` profile (debug build 라 symbol 이 있다):

```bash
perf record -F 999 -g -p $(pgrep cub_server) -- sleep 30
perf report --stdio | head -60
```

---

## Expected Result

- `bug_bts_14917` 가 OOS enabled 빌드 + CTP `shell_ci.conf` 의 720 s timeout 안에서 `pass=1 fail=0` 으로 닫힌다.
- Pre-OOS develop branch 와 동일한 deterministic OK 상태로 회복한다.

---

## Actual Result

- Pre-fix: iter 1 에서 deterministic 하게 `cubrid.jdbc.driver.CUBRIDException: Internal error: INDEX pk_image_doc_id_image_id ... entry on B+tree: 1|512|513 is incorrect. The object does not exist.` 로 fail. Test 종료까지 약 18 s.
- [CBRD-26815] patch 후: false inconsistency 가 사라진다. 다만 row 당 INSERT 가 iter 0 ≈ 297 ms 에서 iter 9 ≈ 1033 ms 까지 단조 증가하므로, iter 20~25 부근에서 CTP 가 720 s timeout 으로 process 를 죽인다. 실측 progress 예시 — loop 0: insert 5.7 s / delete 0.08 s, loop 10: 21.0 / 0.06, loop 20: 34.1 / 0.09.

---

## Additional Information

- Probe data: `/tmp/probe_20m.log`, `/tmp/probe_100m.log`, `/tmp/probe_insert_only.log`
- Probe scripts: `/tmp/probe_oos_insert.sh`, `/tmp/probe_insert_only.sh`, `/tmp/min_repro_14917/repro.sh`
- Hand-off 문서: `/home/vimkim/gh/cb/oos-bug-14917/prompt-cbrd-26824-handoff.md` (1 단계 분석), `prompt-cbrd-26824-handoff-v2.md` (2 단계 분석)
- 관련 ticket: [CBRD-26815] (1 단계 engine fix 의 commit tag 대상), [CBRD-26658] (OOS 3-tier bestspace 메커니즘 — 본 ticket 의 suspect #1 이 이 구조를 다룬다), [CBRD-26583] (M2 epic, 본 ticket 의 parent)
- 환경 주의: CTP 는 `~/.bash_profile` -> `~/.bashrc` 의 `$CUBRID = ~/CUBRID` 를 쓰므로 rebuild 후 `~/CUBRID` 와 `~/.CUBRID_SHELL_FM` 재동기화가 필요하다. 자세한 gotcha 는 hand-off v1 의 "Environment gotchas" 5 항을 본다.

---

## 참고 코드

| 파일 / 위치 | 설명 |
|---|---|
| `src/query/scan_manager.c:6311, 6370, 6375` | 1 단계 fix 의 call site (`heap_get_visible_version_skip_oos_expand` 호출 후 `recdes.data = NULL` reset 과 `skip_oos_expand = true` 전달) |
| `src/transaction/locator_sr.h:119`, `locator_sr.c:13257..13300` | `skip_oos_expand` parameter 신설과 `context.expand_oos = false` 설정부 |
| `src/storage/heap_file.c:8184-8188`, `27024` | 1 단계 원인 site (`data_externally_positioned` gate 와 그것을 set 하는 init) |
| `src/storage/oos_file.cpp:634..760` | `oos_stats_sync_bestspace` — 2 단계 suspect #1 의 핵심 |
| `src/storage/oos_file.cpp:1048..1265, 1460..1610` | OOS insert hot path |
| `src/storage/file_manager.cpp` (`file_alloc`, `file_alloc_in_volume`) | 2 단계 suspect #2 |

---

## Remarks

- 1 단계 engine fix 의 commit tag 는 [CBRD-26815] 로 한다 (밑단의 OOS work 시리즈와 같은 계열). 본 ticket 은 shell-CI regression 추적 sub-task 로 유지하고, 1 단계 회귀 검증과 2 단계 fix 두 가지를 닫는 목적으로 쓴다.
- 2 단계 fix 가 algorithmically inherent 한 한계로 결론나면 그 시점에 사용자에게 재상신해 (a) test workload 조정, (b) timeout 상향, (c) 본 ticket close + 별도 long-term tracking 으로 전환 중 결정한다.
