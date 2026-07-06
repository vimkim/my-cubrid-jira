# [OOS] heap fetch 기본 expand 계약 복구로 raw-record 소비자의 OOS 스텁 노출 방지

## Issue Triage

**이슈 수행 목적**: OOS 레코드를 raw `RECDES` 바이트로 받는 호출자가 일반 객체 조회 API 에서 확장된 레코드를 받도록 한다. 속성 단위로 읽는 query/scan 경로는 명시적 skip API 로 중복 `oos_read` 를 피한다.

**이슈 수행 이유**:

| 항목 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | `heap_init_get_context` 의 기본값이 `expand_oos=false` 이고, `heap_next`, `heap_prev`, `heap_next_sampling`, `heap_scan_get_visible_version` 도 일반 API 에서 OOS expand 를 건너뛰었다. 따라서 raw `RECDES` 소비자는 별도 `_expand_oos` API 를 정확히 골라 쓰지 않으면 `OR_OOS_INLINE_SIZE`(16B) 인라인 OOS OID 슬롯을 실제 컬럼 값으로 받았다. |
| **TO-BE (목표 상태 / 기대 동작)** | `heap_next`, `heap_prev`, `heap_next_sampling`, `heap_scan_get_visible_version`, `heap_get_visible_version` 는 OOS 인라인 슬롯을 실제 값으로 펼친 record image 를 반환한다. `heap_attrinfo_read_dbvalues` 로 곧장 들어가는 호출자만 `*_skip_oos_expand` 를 명시적으로 사용한다. |
| **영향** | QA 실패 및 데이터 정합성 위험 -- `unloaddb`/`compactdb`/copy 계열 경로처럼 `RECDES.data` 를 직접 직렬화하거나 파싱하는 호출자가 OOS OID 슬롯을 값으로 오해할 수 있다. CBRD-26948 의 실측 예에서는 `DISK_SIZE=50008` 인 OOS 컬럼이 unload 결과에서 `X''` 로 떨어졌다. |

**이슈 수행 방안**:

`b35b67eba [CBRD-27029] Expand OOS records by default for heap fetches` 기준으로 다음 계약을 적용한다.

- `heap_init_get_context` 의 `context->expand_oos` 기본값을 `true` 로 둔다.
- `heap_next`, `heap_prev`, `heap_next_sampling`, `heap_scan_get_visible_version`, `heap_get_visible_version` 은 기본적으로 OOS 를 expand 한다. 기존 `*_expand_oos` 함수는 같은 동작의 호환 alias 로 유지한다.
- `heap_next_skip_oos_expand`, `heap_next_sampling_skip_oos_expand`, `heap_prev_skip_oos_expand`, `heap_get_visible_version_skip_oos_expand`, `heap_scan_get_visible_version_skip_oos_expand` 를 제공한다.
- `scan_manager.c`, `query_executor.c`, parallel non-covering index scan 처럼 바로 `heap_attrinfo_read_dbvalues` 로 가는 경로만 skip API 로 전환한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/heap_file.c`, `src/storage/heap_file.h`, `src/query/scan_manager.c`, `src/query/query_executor.c`, `src/query/parallel/px_scan/index/px_scan_index_leaf_slot_walker.cpp` 의 내부 heap fetch API contract 를 조정한다. SQL 문법, catalog, OOS on-disk layout, WAL format 은 바뀌지 않는다.

---

## Description

`OOS` (Out-of-row Storage -- heap 의 큰 가변 컬럼을 별도 OOS file 에 저장하고 heap record 에는 16바이트 OOS OID 슬롯만 남기는 저장 방식) 는 읽기 경로를 두 층으로 나눈다.

첫 번째는 record-level expand 다. 호출자가 `RECDES` (record descriptor -- 디스크 record bytes 와 길이를 담는 구조체) 를 그대로 클라이언트에 보내거나 다른 디코더에 넘기면, heap fetch 단계에서 OOS OID 슬롯을 실제 값 bytes 로 바꿔야 한다. 이 호출자는 OOS 포맷을 모르는 raw-record 소비자다.

두 번째는 attribute-level resolve 다. query scan 처럼 곧바로 `heap_attrinfo_read_dbvalues` 로 들어가는 경로는 record 전체를 먼저 펼치지 않아도 된다. `heap_attrinfo` (class representation 과 attribute 위치를 담는 캐시 구조) 가 필요한 column 만 읽으면서 OOS column 을 `oos_read` 로 해결한다.

회귀는 이 두 층의 기본값이 뒤집히면서 생겼다. OOS 를 모르는 raw-record 소비자는 수가 많고, 일부는 `heap_next` 같은 표준 API 를 오래전부터 호출해 왔다. 이쪽에 "expand 가 필요하면 별도 API 를 골라라" 라는 opt-in 계약을 걸면 누락이 반복된다. 반대로 attribute-reader 경로는 `heap_attrinfo_read_dbvalues` 호출이 코드에 바로 보이므로, skip 계약을 명시적으로 유지하기 쉽다.

### 호출 흐름

```text
[raw-record 소비자: 기본 expand 필요]
unloaddb / compactdb / copyarea fetch / 로그 계열 파서
  -> heap_next 또는 heap_get_visible_version
     -> heap_get_record_data_when_all_ready
        -> heap_record_replace_oos_oids
           -> inline OOS OID 슬롯을 실제 value bytes 로 치환

[attribute-reader 소비자: skip 이 맞음]
scan_manager / query_executor / parallel non-covering index scan
  -> heap_*_skip_oos_expand
     -> heap_attrinfo_read_dbvalues
        -> 필요한 attribute 단위로 OOS resolve
```

이 이슈의 수정은 "일반 객체 조회 API 는 안전한 raw-record contract 를 제공하고, 최적화 경로만 skip 을 고른다"는 방향이다. raw-record 소비자를 빠뜨리는 위험을 줄이면서, scan 핫 패스에서는 record-level expand 와 attribute-level resolve 의 중복 I/O 를 피한다.

## Test Build

- 대상 worktree: `/home/vimkim/gh/cb/cbrd-27029-oos-expand-raw-records`
- 커밋: `b35b67ebaa51dd466b8d3464b441f16a1c8393d9`
- 기준 브랜치: `origin/feat/oos` (`21ba36978`)
- 로컬 검증: debug GCC 빌드와 설치가 완료됐다. OOS test suite 23개가 23/23 passed 로 끝났고, 최종 SQL 검사는 `TEST passed!` 를 출력했다.

## Repro

```sh
cubrid createdb testdb en_US

csql -S -u dba testdb <<'SQL'
CREATE TABLE t (id INT PRIMARY KEY, big BIT VARYING);
INSERT INTO t VALUES (1, REPEAT(X'CD', 10));
INSERT INTO t VALUES (2, REPEAT(X'AB', 50000));
COMMIT;
SELECT id, DISK_SIZE(big) FROM t ORDER BY id;
SQL

cubrid server start testdb
cubrid unloaddb testdb
cubrid server stop testdb

cat testdb_objects
```

## Expected Result

`testdb_objects` 에서 id=2 의 `big` 값이 INSERT 한 `REPEAT(X'AB', 50000)` 에 대응하는 긴 `X'abab...'` 값으로 나온다. OOS 를 모르는 unload 디코더는 이미 확장된 record image 를 받아야 한다.

## Actual Result

수정 전 기본 fetch 계약에서는 id=2 의 `big` 값이 OOS 인라인 슬롯 상태로 전달될 수 있다. CBRD-26948 의 재현에서는 OOS 행만 빈 값으로 출력됐다.

```text
%id [public].[t] 74
%class [public].[t] ([id] [big])
1 X'cdcdcdcdcdcdcdcdcdcd'
2 X''
```

## Additional Information

### 구현 포인트

| 파일 | 변경 |
|------|------|
| `src/storage/heap_file.c:20290` | `heap_next` 가 `heap_next_internal(..., true, ...)` 로 들어가 기본 expand 를 수행한다. |
| `src/storage/heap_file.c:20313` | `heap_next_skip_oos_expand` 가 `expand_oos=false` 로 들어가는 명시적 skip API 를 제공한다. |
| `src/storage/heap_file.c:26527` | `heap_get_visible_version` 은 `heap_init_get_context` 기본값을 따른다. |
| `src/storage/heap_file.c:26566` | `heap_get_visible_version_skip_oos_expand` 는 context 생성 직후 `context.expand_oos=false` 로 바꾼다. |
| `src/storage/heap_file.c:26716` | `heap_scan_get_visible_version` 이 `expand_oos=true` 로 scan 구현에 들어간다. |
| `src/storage/heap_file.c:27169` | `heap_init_get_context` 의 기본값이 `context->expand_oos=true` 다. |
| `src/query/scan_manager.c:5930` | normal heap scan 이 `heap_next_skip_oos_expand` 로 전환된다. |
| `src/query/scan_manager.c:6815` | index heap lookup 이 `heap_get_visible_version_skip_oos_expand` 로 전환된다. |
| `src/query/query_executor.c:10729, 11539` | UPDATE/DELETE LOB cleanup 이 skip API 로 읽은 뒤 `heap_attrinfo_read_dbvalues` 로 LOB 값을 추출한다. |
| `src/query/query_executor.c:12374` | duplicate-key update 가 skip API 로 읽은 뒤 attribute 값으로 해석한다. |
| `src/query/parallel/px_scan/index/px_scan_index_leaf_slot_walker.cpp:455` | parallel non-covering index heap fetch 가 skip API 를 사용한다. |

### 관련 이슈

- CBRD-26729: class repr 없이 OOS OID 를 치환하고 `expand_oos` 옵션을 도입한 선행 작업.
- CBRD-26847: `heap_get_visible_version_expand_oos` 호출처 전수조사.
- CBRD-26948: unloaddb/compactdb raw-record 경로에서 OOS 값이 손실되는 구체 회귀.
- CBRD-27029: 본 sub-task. raw-record 소비자 누락을 줄이기 위해 기본 계약을 expand 로 되돌리고, attribute-reader 경로만 opt-out 으로 명시한다.
