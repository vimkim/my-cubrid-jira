# [PARTITION] 파티션 재분배가 초기 오류 경로에서 초기화되지 않은 scan_cache page watcher를 해제하려 한다

**한 줄 요약**: [CUBRID/cubrid PR #8690](https://github.com/CUBRID/cubrid/pull/8690)(CBRD-28274) 리뷰([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28274/pr-8690-review.md) P-2)에서 PR 이전부터 있던 결함으로 분류된 문제다. 서버의 파티션 재분배 함수 `redistribute_partition_data ()` 가 첫 파티션의 scan cache를 시작하기 전에 오류가 나면, 정리 코드가 초기화되지 않은 스택 변수 `scan_cache.page_watcher` 를 검사해 해제를 시도한다. 이 이슈는 그 오류 경로가 원래 오류를 정상적으로 반환하도록 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: `ALTER TABLE ... REORGANIZE PARTITION`, `COALESCE PARTITION`, `REMOVE PARTITIONING` 의 데이터 재분배가 첫 파티션 scan을 시작하기 전에 실패해도, 페이지 버퍼를 건드리지 않고 원래 오류 코드를 클라이언트에 돌려준다.

**이슈 수행 이유**: `src/transaction/locator_sr.c` 의 `redistribute_partition_data ()` 는 `HEAP_SCANCACHE scan_cache` 를 스택에 선언만 하고, 파티션 루프 안의 `heap_scancache_start ()` 에서 처음 초기화한다. 그러나 함수 끝의 `exit:` 정리 코드는 시작 여부와 관계없이 `scan_cache.page_watcher.pgptr != NULL` 이면 `pgbuf_ordered_unfix ()` 를 호출한다. 그 전에 `goto exit` 하는 오류 경로가 다섯 곳 있다. release/11.4 와 develop 모두 소스에서 확인했다. 2015년 커밋 `0b4182f42ef` 부터 있던 코드이고, PR #8690은 이 경로를 바꾸지 않았다.

**영향**: 서버가 재분배 도중 오류를 만나면 `pgptr` 자리에 남은 스택 쓰레기 값에 따라 동작이 달라진다. 값이 우연히 NULL이면 원래 오류가 그대로 반환된다. NULL이 아니면 고정하지 않은 페이지를 unfix하려 한다. debug 빌드에서는 `pgbuf_ordered_unfix ()` 의 watcher magic 검사 assertion(11.4 `src/storage/page_buffer.c:12258`)에 걸릴 가능성이 높고, release 빌드에서는 서버 비정상 종료나 페이지 버퍼 상태 손상이 날 수 있다. 소스 분석만으로 찾은 결함이고 재현하지 않았다. 각 오류 경로가 실제 운영에서 얼마나 자주 발생하는지와 release 빌드의 실제 결과는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: release/11.4 `065c452fe8` (PR #8690의 base), PR #8690 head `46e71173c0`, develop `6f5ac7a9f9` (2026-11-26). 세 리비전 모두 아래 구조가 같다. 줄 번호는 release/11.4 base 기준이고, 괄호 안은 develop 기준이다. PR head에서는 선언이 `:12709`, 해당 검사가 `:12948` 이다.

### 문제가 되는 코드

```c
  HEAP_SCANCACHE parent_scan_cache, scan_cache;      /* :12709 (15177) - 초기화하지 않음 */
  ...
  PGBUF_INIT_WATCHER (&old_page_watcher, ...);      /* old_page_watcher 는 함수 시작에서 초기화 */
  ...
exit:
  if (old_page_watcher.pgptr != NULL) { pgbuf_ordered_unfix (thread_p, &old_page_watcher); }
  if (scan_cache.page_watcher.pgptr != NULL)         /* :12895 (15401) */
    {
      pgbuf_ordered_unfix (thread_p, &scan_cache.page_watcher);
    }
  ...
  if (is_part_scancache_started == true) { (void) heap_scancache_end (thread_p, &scan_cache); }
```

`old_page_watcher` 는 함수 시작에서 `PGBUF_INIT_WATCHER` 로 초기화하고, `scan_cache` 의 나머지 정리는 `is_part_scancache_started` 플래그로 보호한다. `scan_cache.page_watcher` 만 이 두 가지 보호가 모두 없다. `HEAP_SCANCACHE` 와 `PGBUF_WATCHER` 에는 생성자가 없으므로(`heap_file.h` 의 `struct heap_scancache` 에는 "todo - add constructor/destructor" 주석만 있다), 스택 선언만으로는 `pgptr` 가 초기화되지 않는다.

### `scan_cache` 초기화 전에 `exit:` 에 도달하는 경로

| 위치 (11.4 base / develop) | 조건 | 반환 값 |
|---|---|---|
| `:12725-12730` / `:15193-15197` | 부모 클래스의 HFID 조회 실패 (`heap_get_class_info` / `heap_get_class_hfid`) | 오류 |
| `:12733-12737` / `:15200-15204` | 부모 클래스 insert용 `heap_scancache_start_modify ()` 실패 | 오류 |
| `:12742-12746` / `:15209-15213` | `partition_load_pruning_context ()` 실패 | 오류 |
| `:12756-12759` / `:15223-15226` | 첫 번째 `oid_list[0]` 가 NULL OID | `NO_ERROR` |
| `:12761-12766` / `:15228-15232` | 첫 파티션의 HFID 조회 실패 | 오류 |

그 밖에 `heap_scancache_start_internal ()` (11.4 `src/storage/heap_file.c:6794-6799`, develop `:6763-6768`)도 클래스 정보 조회에 실패하면 watcher를 초기화하지 않고 바로 반환한다. 다만 같은 OID의 HFID를 바로 앞에서 조회해 성공했으므로, 이 경로에 도달할 가능성은 낮다. `heap_scancache_start ()` 의 나머지 오류 경로(`exit_on_error`)는 watcher를 초기화한다(11.4 `heap_file.c:6856`).

호출 경로는 `do_remove_partition_post ()`, `do_coalesce_partition_post ()`, `do_reorganize_partition_post ()` → `do_redistribute_partitions_data ()` (`src/query/execute_schema.c`) → `locator_redistribute_partition_data ()` → `xlocator_redistribute_partition_data ()` 이다. CS 모드에서는 클라이언트(`network_interface_cl.c`)와 서버(`slocator_redistribute_partition_data ()`)가 모두 `no_oids < 1` 을 거부한다. SA 모드 경로에는 이 검사가 없지만, 정상적인 호출자는 항상 하나 이상의 파티션을 넘긴다.

### 근거의 수준

- **확인함**: 위 코드 구조와 다섯 경로를 release/11.4 base, PR #8690 head, develop 소스에서 확인했다. PR #8690이 추가한 `heap_attrinfo_start ()` 오류 경로는 `heap_scancache_start ()` 성공 이후에 있으므로, 이 결함과 관계없다.
- **확인하지 않음**: 오류 주입으로 실제 오류 경로를 실행하지 않았다. 각 경로가 어떤 실제 조건(메모리 부족, 동시 DDL, 카탈로그 읽기 오류 등)에서 발생하는지, 그때 스택에 남는 값과 release 빌드의 결과는 ANALYSIS에서 확인한다.

### 수정 방향 후보 (리뷰 제안, 미결정)

리뷰에서는 함수 시작에서 `scan_cache.page_watcher` 를 `PGBUF_INIT_WATCHER` 로 초기화하거나, `exit:` 의 unfix를 시작 여부 플래그로 보호하는 방법을 제안했다. 이는 ANALYSIS의 후보이고 결정된 방안이 아니다. 네 번째 경로(NULL OID에서 `NO_ERROR` 반환)를 오류로 바꿀지도 함께 판단할 수 있다.

## Expected Result

- 재분배가 첫 파티션 scan 시작 전에 실패하면 페이지 버퍼를 건드리지 않고 원래 오류 코드를 반환한다.

## Actual Result

- 소스상 `exit:` 가 초기화되지 않은 `scan_cache.page_watcher.pgptr` 를 읽고, 그 값이 NULL이 아니면 `pgbuf_ordered_unfix ()` 에 넘긴다. 실행으로 재현하지는 않았다.

## Additional Information

- **출처**: [CUBRID/cubrid PR #8690](https://github.com/CUBRID/cubrid/pull/8690) 리뷰 중 systems/storage 리뷰어가 소스 분석으로 발견했다([리뷰 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28274/pr-8690-review.md) P-2). 리뷰는 이 결함을 PR 이전부터 있던 것으로 분류했다.
- **중복 확인** (`cubrid-jira-dup candidate-find`, 2026-11-26, 인덱스 8,407건 완전 동기화, 후보 20건, JQL 키워드 검색 `redistribute_partition_data` 병행): 중복 이슈 없음.
- **관련 이슈**:
  - [CBRD-28274](https://jira.cubrid.org/browse/CBRD-28274): 이 결함이 발견된 PR #8690의 대상 이슈다. 같은 함수를 수정하지만 이 경로는 바꾸지 않는다.
  - [CBRD-28107](https://jira.cubrid.org/browse/CBRD-28107): 같은 파티션 재분배 경로의 다른 결함이다(재분배 redo 로그의 DELID 미초기화).
