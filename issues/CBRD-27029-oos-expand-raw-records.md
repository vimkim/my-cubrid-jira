# [OOS] heap fetch API 에 OOS Expand 정책 인자를 추가해 raw record 계약 명시

## Issue Triage

**이슈 수행 목적**: develop merge 후 약 300건의 shell test 실패로 드러난 OOS heap fetch 회귀를 전수 조사하고 수정한다. OOS 적용 후 heap fetch 호출자가 record-level Expand 여부를 호출 지점에서 명시하도록 public API 계약을 바꾼다.

**이슈 수행 이유**:

| 항목 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 근본 원인은 `heap_next()` 같은 public heap fetch API signature 를 유지한 데 있다. `*_expand_oos()` / `*_skip_oos_expand()` wrapper 를 나눠도 develop 에서 들어온 새 `heap_next()` 호출자는 OOS 정책을 고르지 않은 채 컴파일되므로, 누락된 call site 가 runtime 회귀로만 드러난다. |
| **TO-BE (목표 상태 / 기대 동작)** | `heap_next()`, `heap_next_sampling()`, `heap_prev()`, `heap_get_visible_version()`, `heap_scan_get_visible_version()` 호출 시 `HEAP_OOS_EXPAND_POLICY` 를 반드시 넘긴다. develop 에 OOS 관련 인자 처리 없이 새 호출자가 들어오면 무조건 빌드 실패가 나고, reviewer 가 `HEAP_WITH_OOS_EXPAND` / `HEAP_WITHOUT_OOS_EXPAND` 를 명시해야 한다. |
| **영향** | QA 실패 및 데이터 정합성 위험 -- `unloaddb`/`compactdb`/`LC_COPYAREA` 처럼 `RECDES.data` 를 직접 직렬화하거나 `or_*` parser 로 읽는 경로가 16B OOS OID 슬롯을 컬럼 값으로 내보낼 수 있다. 반대로 query scan hot path 에서 중복 Expand/Resolve 가 발생하면 불필요한 OOS I/O 가 생긴다. |

**이슈 수행 방안**:

- 기존 public heap fetch 함수 이름은 유지하되, `HEAP_OOS_EXPAND_POLICY` enum 인자를 추가한다.
- `HEAP_GET_CONTEXT` 와 `heap_init_get_context()` 에 기본 OOS 정책을 두지 않고, 모든 호출자가 `HEAP_WITH_OOS_EXPAND` 또는 `HEAP_WITHOUT_OOS_EXPAND` 를 직접 넘기게 한다.
- `*_expand_oos()` / `*_skip_oos_expand()` wrapper 는 제거한다. 의미를 함수 이름으로 우회하지 않고 기존 call site 의 인자에서 드러낸다.
- develop merge 로 발생한 OOS 회귀 call site 를 전수 조사해 raw `RECDES` 소비 경로와 attribute-layer 소비 경로로 다시 분류한다.
- raw `RECDES` 소비 경로는 `HEAP_WITH_OOS_EXPAND`, `heap_attrinfo_read_dbvalues()` 로 곧장 들어가는 경로는 `HEAP_WITHOUT_OOS_EXPAND` 로 분류한다.
- visible-version fast path 가 expanded raw record 요청을 우회하지 않도록, OOS 포함 record 에서 `HEAP_WITH_OOS_EXPAND` 가 필요하면 full path 로 내려간다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **이슈 유형 / 범위**: JIRA metadata 는 CBRD-26835 의 Sub-task 이며, 내용상 storage heap public C/C++ API 계약 개선이다.
- **변경 범위 / 영향**: `src/storage/heap_file.h`, `src/storage/heap_file.c`, `src/storage/heap_oos.cpp` 와 server-side heap fetch 호출부가 대상이다.
- **호환성**: SQL 문법, catalog schema, OOS on-disk layout, WAL format, 사용자 노출 동작은 바꾸지 않는다. 내부 C/C++ API signature 만 바뀐다.

---

## Description

`OOS` (Out-of-row Storage -- heap 의 큰 가변 컬럼을 별도 OOS file 에 저장하고 heap record 에는 pointer 만 남기는 저장 방식) 는 읽기 경로에서 두 가지 의미를 가진다.

`OOS Expand` 는 record-level eager 동작이다. heap record 의 variable area 에 들어 있는 inline OOS OID 슬롯을 실제 컬럼 bytes 로 모두 바꾼 뒤, 호출자에게 확장된 `RECDES` (record descriptor -- record bytes 와 길이를 담는 구조체) 를 돌려준다. `LC_COPYAREA` 로 client 에 record image 를 실어 보내거나 `or_class_name()` 같은 `or_*` parser 로 class record 를 직접 읽는 코드는 이 형태가 필요하다.

`OOS Resolve` 는 column-level lazy 동작이다. `heap_attrinfo_read_dbvalues()` 가 class representation 과 attribute 위치를 보고 필요한 column 을 읽을 때 `oos_read()` 로 OOS 값을 가져온다. query scan, index key generation, metadata lookup 처럼 record 를 받은 직후 attribute layer 로 들어가는 경로는 전체 record 를 먼저 Expand 하지 않아도 된다.

처음에는 기존 `heap_next()` 같은 함수는 그대로 두고 `heap_next_expand_oos()` / `heap_next_skip_oos_expand()` 류 wrapper 로 의미를 나누는 접근을 썼다. 이 방식은 기존 call site 를 고칠 때는 읽기 쉬워 보이지만, develop merge 에 취약하다. 다른 팀 변경이 기존 `heap_next()` signature 로 들어오면 OOS branch 에서도 컴파일되므로, merge 하는 사람이 해당 호출자가 raw record 를 소비하는지 attribute layer 로 넘어가는지 보지 않고 지나칠 수 있다.

CBRD-27029 는 그 누락 가능성을 compile break 로 바꾼다. heap fetch API signature 에 `HEAP_OOS_EXPAND_POLICY` 를 넣으면 새 호출자는 정책을 선택하기 전까지 빌드되지 않는다. merge 작업자는 실패한 call site 를 보고, `RECDES.data` 를 직접 해석하는지 또는 `heap_attrinfo_*` 계층으로 넘기는지 확인한 뒤 enum 을 추가해야 한다.

## Specification Changes

정책 enum 은 `src/storage/heap_file.h` 에 둔다.

| Enum | 의미 | 사용할 때 |
|------|------|-----------|
| `HEAP_WITH_OOS_EXPAND` | inline OOS OID 슬롯을 실제 값으로 치환한 raw-record-safe `RECDES` 를 반환한다. | 호출자가 `RECDES.data` 를 직접 직렬화, 복사, 비교, `or_*` parsing, 재삽입에 사용한다. |
| `HEAP_WITHOUT_OOS_EXPAND` | heap record 안의 inline OOS OID 슬롯을 그대로 둔다. | 호출자가 곧바로 `heap_attrinfo_read_dbvalues()` 또는 같은 attribute layer 로 값을 읽는다. |

변경되는 public heap fetch API 는 다음과 같다.

| 함수 | 변경 |
|------|------|
| `heap_next()` | 기존 이름 유지, `HEAP_OOS_EXPAND_POLICY oos_expand_policy` 인자 추가 |
| `heap_next_sampling()` | 기존 이름 유지, `HEAP_OOS_EXPAND_POLICY oos_expand_policy` 인자 추가 |
| `heap_prev()` | 기존 이름 유지, `HEAP_OOS_EXPAND_POLICY oos_expand_policy` 인자 추가 |
| `heap_get_visible_version()` | 기존 이름 유지, `HEAP_OOS_EXPAND_POLICY oos_expand_policy` 인자 추가 |
| `heap_scan_get_visible_version()` | 기존 이름 유지, `HEAP_OOS_EXPAND_POLICY oos_expand_policy` 인자 추가 |
| `heap_init_get_context()` | `HEAP_GET_CONTEXT` 생성 시 enum 정책을 필수로 받음 |

아래 wrapper 이름은 제거 대상이다.

```text
heap_next_expand_oos()
heap_next_skip_oos_expand()
heap_next_sampling_skip_oos_expand()
heap_prev_skip_oos_expand()
heap_get_visible_version_expand_oos()
heap_get_visible_version_skip_oos_expand()
heap_scan_get_visible_version_skip_oos_expand()
```

## Implementation

정책 전달 흐름은 하나로 수렴한다.

```text
[caller]
  -> heap_next(..., HEAP_WITH_OOS_EXPAND | HEAP_WITHOUT_OOS_EXPAND)
     또는 heap_get_visible_version(..., HEAP_WITH_OOS_EXPAND | HEAP_WITHOUT_OOS_EXPAND)
       -> heap_init_get_context(..., oos_expand_policy)
          -> HEAP_GET_CONTEXT.oos_expand_policy
             -> heap_record_replace_oos_oids()
```

`heap_record_replace_oos_oids()` 는 `HEAP_WITHOUT_OOS_EXPAND` 일 때 바로 성공을 반환한다. `HEAP_WITH_OOS_EXPAND` 이고 record 에 OOS flag 가 있으면 OOS OID 를 따라 `oos_read()` 로 값을 읽고, variable offset table 을 다시 써서 OOS 를 쓰지 않은 것처럼 보이는 record image 를 만든다. invalid policy 는 assertion 과 `S_ERROR` 로 처리해 잘못된 내부 호출을 조기에 잡는다.

visible-version scan 에는 기존 fast path 가 있다. `peeked_recdes` 가 `REC_HOME` 이고 MVCC visible 이면 `heap_get_visible_version_internal()` 을 건너뛰어 record 를 바로 반환한다. 이 fast path 는 inline OOS OID 슬롯을 그대로 돌려주므로, `HEAP_WITH_OOS_EXPAND` 요청이면서 `heap_recdes_contains_oos()` 가 참이면 fast path 를 쓰지 않고 full path 로 내려간다.

caller 판정 기준은 아래처럼 유지한다.

| caller 종류 | 정책 | 예 |
|-------------|------|----|
| raw record 소비자 | `HEAP_WITH_OOS_EXPAND` | `LC_COPYAREA` fetch-all, class/root catalog 의 `or_*` parser, scanrange helper, compactdb 의 old record image, lock dump 의 MVCC header 확인 |
| OOS-capable attribute-layer 소비자 | `HEAP_WITHOUT_OOS_EXPAND` | `scan_manager`, `query_executor` LOB cleanup, `btree_load`, dblink/catalog metadata scan, foreign-key/index consistency check, parallel non-covering index scan |
| OID 전진용 scan 뒤 재조회 | `HEAP_WITHOUT_OOS_EXPAND` 후 필요한 지점에서 expanded fetch | locking branch 처럼 첫 scan 은 다음 OID 만 찾고, 실제 record 는 lock 획득 후 다시 읽는 경로 |

## Acceptance Criteria

- [ ] `heap_next()`, `heap_next_sampling()`, `heap_prev()`, `heap_get_visible_version()`, `heap_scan_get_visible_version()` 의 직접 호출자가 모두 `HEAP_OOS_EXPAND_POLICY` 를 명시한다.
- [ ] 제거 대상 `*_expand_oos()` / `*_skip_oos_expand()` wrapper 이름이 source tree 에 남지 않는다.
- [ ] raw `RECDES` 소비 경로는 `HEAP_WITH_OOS_EXPAND` 로 분류되고, OOS-capable record 를 곧장 attribute layer 로 넘기는 hot path 는 `HEAP_WITHOUT_OOS_EXPAND` 로 분류된다.
- [ ] `HEAP_WITH_OOS_EXPAND` 요청에서 visible-version fast path 가 inline OOS OID 슬롯을 그대로 반환하지 않는다.
- [ ] develop merge 로 새 heap fetch 호출자가 들어오면, 정책 인자를 추가하기 전에는 빌드가 실패한다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] debug build 통과
- [ ] OOS 관련 SQL/medium 회귀 확인
- [ ] 리뷰 시 caller classification table 재검토

## Verification

작성 시점의 로컬 commit report 기준으로 아래 확인이 완료됐다.

```sh
git diff --check
cmake --build build_preset_debug_gcc -j"$(nproc)"
```

결과: build completed successfully.

## References

- JIRA: <http://jira.cubrid.org/browse/CBRD-27029>
- 설계 메모: `/home/vimkim/gh/my-cubrid-docs/cbrd-27029/CBRD-27029-expand-raw-records.md`
- 로컬 commit report: `CBRD-27029-commit-report.md`
