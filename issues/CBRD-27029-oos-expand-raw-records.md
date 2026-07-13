# [OOS] raw RECDES 소비 경로에서 실제 컬럼 값이 담긴 record 를 받도록 heap fetch 계약 명시

## Issue Triage

**이슈 수행 목적**: 주요 heap fetch API 와 locator getter 가 반환 record 의 소비 계약을 필수 인자로 받게 한다. raw bytes 를 직접 쓰는 호출자는 실제 컬럼 값이 담긴 record 를 받는다.

**이슈 수행 이유**:

| 항목 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 기존 API 를 호출할 때 반환 `RECDES` 의 소비 방식을 밝히지 않아도 컴파일되므로, develop 에서 추가된 호출부가 OOS 검토 없이 merge 될 수 있다. 단건 object fetch 도 OOS 값을 복원하지 않은 record 를 client 로 보냈다. |
| **TO-BE (목표 상태 / 기대 동작)** | 정책 인자를 추가한 heap fetch API 5종과 locator getter 3종은 raw bytes 소비 여부를 반드시 받는다. 단건 object fetch 를 포함한 raw-byte 경로는 실제 컬럼 값이 담긴 record 를 반환하며, 정책을 빠뜨린 새 호출부는 compile error 로 드러난다. |
| **영향** | 데이터 정합성 -- `unloaddb` 가 record 를 byte 단위로 client 에 전송할 때 OOS 저장 위치 정보가 컬럼 값처럼 노출되면 fetch 또는 parsing 이 실패할 수 있다. |

**이슈 수행 방안**:

- `heap_next()`, `heap_next_sampling()`, `heap_prev()`, `heap_get_visible_version()`, `heap_scan_get_visible_version()` 와 locator getter 3종에 필수 enum 인자를 추가한다. 기본값은 두지 않는다.
- raw bytes 를 직접 전송·복사·비교·파싱·재삽입하는 경로에서는 모든 OOS inline stub 을 실제 값으로 치환한 record 를 반환한다.
- `heap_attrinfo_*` 로 컬럼을 읽거나 record body 를 사용하지 않는 경로에서는 inline stub 을 유지하고 attribute-level Resolve 를 사용한다.
- `locator_lock_and_return_object()` 의 단건 client fetch 는 전송 전에 record 를 materialize 한다. 확장된 record 가 `LC_COPYAREA` 의 남은 공간보다 크면 기존 `S_DOESNT_FIT` 계약에 따라 필요한 크기를 알리고, 상위 호출자가 copy area 를 늘려 다시 시도한다.
- 현재 enum 이름은 동작인 OOS Expand 를 강조한다. 호출자의 선택 기준이 코드에 드러나도록 소비 방식 중심 이름으로 바꾸는 안을 검토한다. 최종 이름은 `TBD - 리뷰 합의 미확인` 이다.

---

## AI-Generated Context

> 아래는 AI 가 코드와 변경 이력을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **이슈 유형 / 범위**: CBRD-26835 의 Sub-task 로, server-side heap fetch 내부 API 계약과 locator 전송 경로를 변경한다.
- **변경 파일**: `src/storage/heap_file.h`, `src/storage/heap_file.c`, `src/storage/heap_oos.cpp`, `src/transaction/locator_sr.c` 및 heap fetch 호출부가 대상이다.
- **호환성**: SQL 문법, catalog schema, OOS on-disk layout, WAL format 은 바뀌지 않는다. 내부 C/C++ API signature 와 반환 record 구성 시점만 달라진다.

---

## Description

`OOS` (Out-of-row Overflow Storage -- heap 의 큰 가변 컬럼을 별도 OOS file 에 저장하는 방식) 를 사용하는 record 는 컬럼 전체 값을 heap 에 두지 않는다. variable area 에는 16-byte `OOS inline stub` 만 남는다. `RECDES` (record descriptor) 는 record bytes 와 길이를 담는 내부 구조체다.

```text
heap 에 저장된 record
[ id | name | OOS inline stub ]
                    |
                    +-- head OOS OID + 전체 값 길이
                              |
                              +-- OOS file 의 실제 컬럼 값
```

이 record 를 읽는 방법은 소비자에 따라 다르다.

`OOS Expand` 는 record-level eager 동작으로, 모든 OOS inline stub 을 실제 값으로 바꾸고 record 전체를 다시 만든다. `OOS Resolve` 는 attribute-level lazy 동작으로, 필요한 `OOS-backed attribute` (heap 에 실제 값 대신 OOS inline stub 이 저장된 속성 값) 하나만 읽는다.

attribute layer 를 사용하는 query scan 은 `heap_attrinfo_read_dbvalues()` 로 필요한 컬럼만 Resolve 한다. record 전체를 먼저 Expand 할 필요가 없으므로, 읽지 않는 큰 컬럼에 대한 OOS I/O 도 피할 수 있다.

반면 `LC_COPYAREA` 에 record image 를 복사해 client 로 보내거나 `or_*` 함수로 `RECDES.data` 를 직접 파싱하는 코드는 attribute layer 를 거치지 않는다. 이런 경로에 OOS inline stub 이 남아 있으면, OOS file 에 접근할 수 없는 client 또는 OOS 를 모르는 parser 가 stub 안의 head OOS OID 와 길이를 컬럼 값으로 해석한다.

```text
[raw-byte 소비 경로]
heap fetch
  -> 모든 OOS inline stub 을 실제 값으로 치환
  -> LC_COPYAREA / raw parser / record 재삽입
  -> 실제 컬럼 bytes 사용

[attribute-layer 소비 경로]
heap fetch
  -> OOS inline stub 유지
  -> heap_attrinfo_* 로 필요한 컬럼만 읽음
  -> 해당 컬럼만 oos_read()
```

## Specification Changes

### 정책 인자 추가 API

| 구분 | 함수 |
|------|------|
| heap fetch | `heap_next()`, `heap_next_sampling()`, `heap_prev()`, `heap_get_visible_version()`, `heap_scan_get_visible_version()` |
| locator getter | `locator_lock_and_get_object()`, `locator_lock_and_get_object_with_evaluation()`, `locator_get_object()` |

### 호출자 분류 기준

| 소비 방식 | 필요한 반환 형태 | 대표 경로 |
|-----------|------------------|-----------|
| raw bytes 직접 소비 | OOS inline stub 을 실제 값으로 치환한 record | `LC_COPYAREA` client 전송, `unloaddb`, `compactdb`, `or_*` parsing, byte 단위 비교, record 재삽입 |
| attribute layer 소비 | OOS inline stub 을 유지한 record | query scan, index key 생성, `heap_attrinfo_read_dbvalues()` 기반 metadata 조회 |
| record body 미사용 | OOS inline stub 을 유지한 record | 존재 확인, 다음 OID 탐색, MVCC header 만 확인 |

`COPY` 또는 `PEEK` 은 record buffer 의 소유권과 수명을 정하는 옵션이다. OOS 값을 materialize 할지 정하는 기준으로 사용하지 않는다.

### Enum 이름 후보

현재 이름은 `HEAP_WITH_OOS_EXPAND` / `HEAP_WITHOUT_OOS_EXPAND` 다. 아래 후보는 구현 동작보다 호출자가 반환 record 를 어떻게 소비하는지를 먼저 보여준다.

| 순위 | enum type | 값 | 고려사항 |
|------|-----------|----|----------|
| 1 | `HEAP_RECDES_CONSUMPTION_POLICY` | `HEAP_RECDES_RAW_BYTES_CONSUMED`, `HEAP_RECDES_RAW_BYTES_NOT_CONSUMED` | 권장안. fetch 호출자가 `RECDES.data` 를 직접 쓰는지만 답하면 된다. 두 번째 값은 attribute layer 로 읽는 경로와 record body 를 쓰지 않는 경로를 모두 포함한다. |
| 2 | `HEAP_RECDES_MATERIALIZATION_POLICY` | `HEAP_RECDES_MATERIALIZE_OOS`, `HEAP_RECDES_KEEP_OOS_STUBS` | 반환 형태가 정확하다. 다만 호출자가 OOS materialization 방식을 알아야 선택할 수 있다. |
| 3 | `HEAP_RECORD_CONSUMPTION_MODE` | `HEAP_RECORD_FOR_RAW_CONSUMER`, `HEAP_RECORD_FOR_NON_RAW_CONSUMER` | 소비자 기준은 분명하지만 식별자가 길고, CUBRID 코드에서 쓰는 `RECDES` 용어가 빠진다. |
| 4 | `HEAP_RAW_RECORD_POLICY` | `HEAP_RAW_RECORD_REQUIRED`, `HEAP_RAW_RECORD_NOT_REQUIRED` | 리뷰 제안의 방향은 좋다. 다만 `raw record` 가 on-disk 형태인지, 실제 값을 채운 논리 record 인지 혼동될 수 있다. |

> **권장**: `HEAP_RECDES_CONSUMPTION_POLICY` 와 `HEAP_RECDES_RAW_BYTES_CONSUMED` / `HEAP_RECDES_RAW_BYTES_NOT_CONSUMED` 조합을 사용한다. enum 값은 fetch 호출자의 소비 계약을 말하고, 실제 OOS materialization 여부는 fetch 구현이 결정한다.

최종 이름이 정해지면 invalid 값과 필드명도 같은 축으로 맞춘다.

```c
typedef enum
{
  HEAP_RECDES_CONSUMPTION_INVALID = 0,
  HEAP_RECDES_RAW_BYTES_CONSUMED,
  HEAP_RECDES_RAW_BYTES_NOT_CONSUMED
} HEAP_RECDES_CONSUMPTION_POLICY;
```

## Implementation

정책은 public fetch 에서 실제 materialization 지점까지 한 번만 전달한다.

```text
[caller]
  -> heap_next() / heap_get_visible_version() / locator_get_object()
       -> heap_init_get_context()
            -> HEAP_GET_CONTEXT
                 -> heap_record_replace_oos_oids()
```

`RAW_BYTES_CONSUMED` 정책이고 record-level `HAS_OOS` flag (record 안에 OOS inline stub 이 있음을 나타내는 표시) 가 설정돼 있으면 `heap_record_replace_oos_oids()` 가 variable offset table 을 순회한다. 각 OOS inline stub 의 head OOS OID 로 `oos_read()` 를 호출한 뒤, 실제 컬럼 값이 담긴 새 record image 를 만든다.

`RAW_BYTES_NOT_CONSUMED` 정책이면 `heap_record_replace_oos_oids()` 는 record 를 바꾸지 않는다. 이후 attribute layer 가 접근한 OOS-backed attribute 만 Resolve 한다.

단건 client fetch 흐름은 다음과 같다.

```text
xlocator_fetch() / xlocator_fetch_lockset()
  -> locator_lock_and_return_object()
       -> locator_get_object(..., RAW_BYTES_CONSUMED)
            -> heap fetch + OOS materialization
       -> LC_COPYAREA 에 record 복사
       -> client 전송

★ 확장된 record 가 현재 area 보다 큼
  -> S_DOESNT_FIT + 필요한 크기 반환
  -> 상위 호출자가 area 확장 후 재시도
```

## Acceptance Criteria

- [x] heap fetch API 5종과 `locator_lock_and_get_object()`, `locator_lock_and_get_object_with_evaluation()`, `locator_get_object()` 호출자가 OOS record 처리 정책을 명시한다.
- [x] 정책을 빠뜨린 새 호출자는 compile error 가 발생한다.
- [x] `locator_lock_and_return_object()` 가 OOS-backed instance 를 client 로 보낼 때 inline stub 대신 실제 컬럼 값이 담긴 record 를 전송한다.
- [x] materialization 으로 `LC_COPYAREA` 공간이 부족하면 `S_DOESNT_FIT` 크기 반환과 재시도 계약을 유지한다.
- [x] attribute-layer 소비 경로는 record-level materialization 없이 필요한 OOS 컬럼만 Resolve 할 수 있다.
- [ ] enum type 과 값의 최종 이름을 리뷰에서 합의하고 source, PR, JIRA 표현을 일치시킨다.

## Definition of done

- [ ] 위 A/C 충족
- [x] debug build 통과
- [ ] OOS-backed row 의 단건 client fetch, fetch-all, `unloaddb`, `compactdb` 회귀 확인
- [ ] PR 설명과 commit message 에 raw-byte 소비 경로의 실패 원인 및 enum 선택 기준 반영

## Verification

PR #7416 HEAD `f59e9b8b2` 기준으로 PR diff 정적 검사와 로컬 debug build 를 수행했다.

```sh
base=$(git merge-base origin/feat/oos HEAD)
git diff "$base"...HEAD --check
cmake --build build_preset_debug_gcc -j"$(nproc)"
```

추가 확인이 필요한 핵심 시나리오는 OOS-backed instance 를 단건 fetch 해 client 가 원래 컬럼 값과 길이를 받는지 검증하는 것이다. fetch-all, `unloaddb`, `compactdb` 도 같은 raw-record 계약을 사용하므로 함께 회귀 확인한다.

## Remarks

- PR: <https://github.com/CUBRID/cubrid/pull/7416>
- 관련 caller audit: CBRD-26847
- raw fetch 회귀: CBRD-26948
