# [OOS] [M2] raw RECDES 소비 경로와 OOS Expand 정책 전수 조사

## Issue Triage

**이슈 수행 목적**: OOS inline stub 을 포함할 수 있는 heap instance `RECDES` 의 모든 생성·전달·소비 경로에서 필요한 OOS 처리가 일치하도록 한다. full logical record/variable area 소비 경로의 inline stub 노출과 OOS-insensitive 경로의 불필요한 OOS Expand 를 함께 제거한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | CBRD-27029 가 주요 heap fetch API 와 locator getter 에 필수 정책 인자를 추가하면서 호출자의 선택은 코드에 드러나게 됐다. 그러나 초기 정책값에는 기존 동작을 보존하기 위한 보수적 선택이 남아 있으며, 기존 CBRD-26847 의 `heap_get_visible_version_expand_oos` 호출처 조사만으로는 정책 인자를 전달하는 wrapper, WAL 에서 복원한 record, CDC/flashback 등 정책 API 밖의 raw `RECDES` 소비 경로를 확인할 수 없다. |
| **TO-BE (목표 상태 / 기대 동작)** | 명시적 정책값에서 소비자까지 추적하는 정방향 조사와 모든 heap instance `RECDES` 소비자에서 record 원점까지 거슬러 올라가는 역방향 조사를 수행한다. full logical record 또는 OOS inline stub 이 들어갈 수 있는 variable area 를 OOS-unaware 방식으로 소비하는 경로만 Expand 하고, attribute layer 소비와 physical image 보존, header/fixed/CHN 전용 경로는 stored-form record 를 유지한다. |
| **영향** | 데이터 정합성 -- raw bytes 를 client 로 보내거나 직접 파싱하는 경로가 non-consume 정책을 선택하면 16-byte OOS inline stub 의 head OOS OID 와 전체 길이를 실제 컬럼 값으로 해석할 수 있다. |

**이슈 수행 방안**:

- CBRD-27029 가 정책 인자를 추가한 heap fetch API 와 locator getter, 해당 API 를 감싼 wrapper, 각 호출처를 전수 조사한다.
- raw `RECDES` 를 전송, 복사, 비교, 파싱, 재삽입하는 소비 지점에서 record 원점까지 역추적한다. heap fetch 뿐 아니라 WAL/undo/redo 복원, CDC/flashback, replication 과 client 전달 경로를 포함하며, 직접 byte 를 읽더라도 physical image 보존 또는 header/fixed/CHN 에 한정되는지는 별도로 구분한다.
- 각 경로를 OOS-sensitive logical 소비, attribute layer 소비, physical image 보존, OOS-insensitive raw 소비, record body 미사용, 정책 전달 wrapper 로 분류하고 근거를 표로 남긴다.
- 잘못 선택된 정책과 근거 없는 보수적 Expand 는 본 이슈에서 바로잡는다. 별도 설계나 큰 회귀 수정이 필요한 경로는 후속 이슈로 분리하되 누락 없이 연결한다.
- 사용자 합의: "CBRD-27029 has changed the code a lot (made it explicit) and prepared for a new version of total inspection for OOS expansion (raw recdes usage inspection)."

---

## AI-Generated Context

> 아래는 AI 가 코드와 변경 이력을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: server-side heap fetch 와 locator 계층, WAL 에서 heap record image 를 복원하는 CDC/flashback, replication, client/network 및 반환 `RECDES` 를 소비하는 query, storage, transaction, utility 경로가 대상이다. SQL 문법, catalog schema, OOS on-disk layout, WAL format 은 바뀌지 않는다.
- **이슈 유형 / 계층**: CBRD-26583 의 Sub-task 다. 조사 결과에 따른 내부 fetch 정책 정정은 포함하지만 외부 기능 스펙은 추가하지 않는다.
- **기준 소스**: `feat/oos` commit `6816023df4ed910687523ab4d34bf667ab32b9cd` 기준으로 조사한다. 조사 중 base 가 바뀌면 최종 표에 새 commit 과 증감된 호출처를 함께 기록한다.

## Description

`OOS` (Out-of-row Overflow Storage -- heap 의 큰 가변 컬럼 값을 별도 OOS file 에 저장하는 방식) 가 적용된 record 의 variable area 에는 실제 값 대신 16-byte `OOS inline stub` 이 들어갈 수 있다. `RECDES` (record descriptor) 는 record bytes 와 길이를 담는 내부 구조체다.

OOS-backed attribute 를 읽는 방식은 두 가지다.

- `OOS Expand` 는 record-level eager 동작이다. 모든 OOS inline stub 을 실제 값으로 바꿔 record 전체를 다시 만든다.
- `OOS Resolve` 는 attribute-level lazy 동작이다. `heap_attrinfo_*` 계층이 접근한 attribute 만 `oos_read()` 로 읽는다.

CBRD-27029 이전에는 `heap_get_visible_version()` 과 `heap_get_visible_version_expand_oos()` 처럼 함수 이름으로 두 동작을 구분했다. 기존 CBRD-26847 은 `_expand_oos` 함수의 20여 개 호출처만 조사하는 내용으로 작성됐다.

CBRD-27029 이후 `_expand_oos` 전용 함수는 제거됐고, caller 가 다음 정책 중 하나를 필수로 넘긴다.

| 정책 | 반환 형태 | 올바른 소비자 |
|------|-----------|---------------|
| `HEAP_RECDES_CONSUME_RAW_BYTES` | OOS inline stub 을 실제 값으로 치환한 record | full record 또는 variable area 를 attribute layer 밖에서 전송, 복사, 비교, 파싱, 재삽입하는 경로 |
| `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` | heap 에 저장된 OOS inline stub 유지 | `heap_attrinfo_*` 로 필요한 attribute 만 읽거나 header/fixed/CHN 만 읽거나 record body 를 쓰지 않는 경로 |

따라서 기존 이슈의 조사 단위인 함수 이름과 호출처 목록은 더 이상 현재 코드를 설명하지 못한다. 명시적 enum 은 검토 지점을 만들었지만, enum 값 자체가 맞다는 보장은 아니다. raw 소비자가 정책 API 를 직접 호출하지 않고 여러 wrapper 를 거치거나 WAL 의 undo/redo image 에서 `RECDES` 를 복원하는 경우도 있어 정책 호출처만 보는 단방향 조사로는 누락을 찾을 수 없다.

또한 `RECDES.data` 를 직접 읽는다는 사실만으로 Expand 대상으로 판정하지 않는다. OOS inline stub 은 variable area 에 있으므로 MVCC header, fixed attribute, CHN 처럼 OOS 와 무관한 byte 범위만 읽는 caller 는 stored-form record 로 충분하다. 반대로 full record image 를 전송하거나 variable area 를 OOS-unaware parser 로 읽는 caller 는 실제 컬럼 값이 필요하다.

WAL append, recovery redo/undo, vacuum 처럼 heap record 의 physical image 를 보존하는 경로는 inline stub 을 그대로 유지해야 한다. Undo record 는 과거 heap-record version 의 OOS value chain 을 가리키며 MVCC와 vacuum 이 그 참조를 사용하므로, 이 단계에서 Expand 하면 오히려 저장·복구 계약을 깨뜨린다. 반면 log record 에서 복원한 `RECDES` 를 CDC/flashback 결과로 해석하는 단계는 logical consumer 다. 현재 `cdc_make_dml_loginfo()` 는 `heap_attrinfo_read_dbvalues()` 로 attribute-level Resolve 를 시도하므로 이 호출 흐름과 오류·schema-change 분기를 조사표에서 검증한다.

### 현재 조사 시작점

기준 commit 의 CBRD-27029 정책 소스 검색 결과는 다음과 같다. 이 수치는 전체 raw `RECDES` 조사 범위나 완료 판정값이 아니라 정방향 조사의 시작점이며, 최종 결과에서는 주석, enum 정의, 정책 구현부를 제외한 실제 호출처를 다시 산출한다.

| 항목 | 시작점 |
|------|--------|
| 정책을 직접 받는 public heap fetch | `heap_next()`, `heap_prev()`, `heap_get_visible_version()`, `heap_scan_get_visible_version()` |
| 정책을 직접 받는 locator getter | `locator_lock_and_get_object()`, `locator_lock_and_get_object_with_evaluation()`, `locator_get_object()` |
| `HEAP_RECDES_CONSUME_RAW_BYTES` 호출 인자 | 25곳 |
| `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` 호출 인자 | 59곳 |
| 정책을 내부에서 고정하는 대표 wrapper | `heap_first()`, `heap_last()`, `heap_next_1page()`, `heap_next_record_info()`, `heap_prev_record_info()` |

CBRD-27029 설명에 포함됐던 `heap_next_sampling()` 은 이후 CBRD-26936 에서 제거됐으므로 현재 조사 대상 API 목록에 넣지 않는다.

### 조사 방향

두 방향의 결과가 같은 경로 집합으로 수렴해야 전수 조사로 인정한다.

```
[정방향: 정책 선택의 타당성]
HEAP_RECDES_* 정책값
  -> heap fetch / locator getter / wrapper
  -> 반환 RECDES 전달 경로
  -> 실제 소비 연산
       ├ full record / variable area raw 소비 -> CONSUME_RAW_BYTES
       ├ attribute layer 소비                 -> DONT_CONSUME_RAW_BYTES
       ├ header / fixed / CHN raw 소비        -> DONT_CONSUME_RAW_BYTES
       └ record body 미사용                   -> DONT_CONSUME_RAW_BYTES

[역방향: Expand/Resolve 누락 탐지]
heap instance RECDES 소비 연산
  -> 입력 RECDES 의 alias / copy / wrapper 역추적
  -> record 원점 분류
       ├ heap fetch                  -> 정책 전달 확인
       ├ WAL undo/redo 복원          -> physical 보존인지 logical 해석인지 확인
       └ replication/client/buffer   -> 전송 방향과 수신 consumer 확인
  -> 소비 방식 판정
       ├ full logical record / variable area -> Expand 또는 attribute Resolve 확인
       ├ physical image 보존                -> inline stub 유지
       └ header / fixed / CHN                -> inline stub 유지
```

정방향 조사는 명시적 정책값의 과도한 Expand 와 잘못된 non-consume 선택을 찾는다. 역방향 조사는 정책 API 를 통하지 않는 logical consumer 의 Resolve 누락과 physical-image 경로의 잘못된 materialization 을 찾는다. 한쪽만 수행하면 각각 반대쪽 결함을 놓칠 수 있다.

### 조사 범위

| 포함 | 판단 기준 |
|------|-----------|
| 명시적 정책 호출처 | 두 enum 값의 모든 실제 호출 인자 |
| 정책 전달 wrapper | 정책을 인자로 받아 하위 fetch 로 전달하거나 내부에서 한 값을 고정하는 함수 |
| heap fetch 반환값의 alias/copy | 반환 `RECDES` 가 다른 구조체, buffer, 함수 인자로 전달되는 경로 |
| 비-fetch heap record image | WAL undo/redo 에서 복원한 instance `RECDES`, CDC/flashback 해석, replication 과 client/network 전달 |
| raw-byte 소비 seed | `LC_COPYAREA`/network 전송, `memcpy`/`memcmp`, `OR_BUF`/`or_*` 직접 파싱, raw serialization, 다른 heap record 로 재삽입. 각 연산이 실제로 읽거나 전달하는 byte 범위를 확인한다. |
| attribute-layer 소비 | `heap_attrinfo_read_dbvalues()` 등 OOS Resolve 가능한 계층을 통한 attribute 접근 |
| physical image 보존 | WAL append, recovery, rollback, vacuum 처럼 inline stub 과 head OOS OID 를 저장 형태 그대로 유지해야 하는 경로 |
| OOS-insensitive raw 소비 | MVCC header, fixed attribute, CHN 처럼 OOS inline stub 이 들어갈 수 없는 범위만 직접 읽는 경로 |
| record body 미사용 | 존재 확인이나 OID 이동처럼 `RECDES.data` 를 읽지 않는 경로 |

다음은 이름이 같아도 이 이슈의 reverse audit 대상에서 제외한다.

| 제외 | 이유 |
|------|------|
| B-tree, sort, list file 등 heap instance 가 아닌 구조의 `RECDES` | OOS-capable heap record 가 아니므로 OOS Expand 정책과 무관하다. |
| `OOS_RECDES` 와 OOS chunk record 내부 처리 | heap record 안의 OOS inline stub 을 materialize 하는 소비자가 아니다. |
| write-time DB_VALUE-to-RECDES 변환 중 OOS demotion 이전 image | 아직 OOS inline stub 이 없는 logical record 생성 단계다. demotion 후 physical image 의 전달·소비는 포함한다. |

> **요지**: 변수 이름이 `recdes` 라는 이유만으로 모든 저장 구조를 조사하지 않는다. OOS inline stub 을 포함할 수 있는 heap instance record image 인지, 그 bytes 를 physical image 로 보존하는지 logical row 로 해석하는지를 경계로 삼는다.

## Specification Changes

외부 SQL 동작과 저장 형식 변경은 없다.

내부 계약은 CBRD-27029 가 도입한 기준을 모든 heap instance record image 로 확장해 검증한다. heap fetch 에서 full logical record 또는 OOS inline stub 이 들어갈 수 있는 variable area 를 attribute layer 밖에서 소비하면 `HEAP_RECDES_CONSUME_RAW_BYTES` 를 선택한다. attribute layer 로 Resolve 하거나 physical image 를 보존하거나 header/fixed/CHN 만 읽거나 record body 를 쓰지 않으면 stored-form record 를 유지한다. 정책-bearing fetch 에서는 후자의 경우 `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` 를 선택한다. `COPY`/`PEEK` 은 buffer 소유권과 수명에 관한 옵션이므로 OOS Expand 판단 근거로 사용하지 않는다.

## Implementation

### 1. 정책 API와 wrapper 목록 고정

기준 commit 에서 `HEAP_RECDES_CONSUMPTION_POLICY` 를 받는 함수, 두 enum 값을 직접 쓰는 호출처, 정책을 내부에서 고정하는 wrapper 를 기계적으로 수집한다. 최종 조사표에는 함수, 파일/라인, 호출한 API, 선택 정책을 기록한다.

### 2. 정방향 소비 추적

각 fetch 결과가 마지막으로 사용되는 지점까지 alias 와 호출 흐름을 추적한다. 단순히 caller 함수 이름이나 `COPY`/`PEEK` 값으로 판정하지 않는다.

| 분류 | 완료 근거 | 정책 |
|------|-----------|------|
| OOS-sensitive raw 소비 | full record/variable area 전송, 복사, 비교, 파싱, 재삽입 연산과 그 위치 | `HEAP_RECDES_CONSUME_RAW_BYTES` |
| attribute layer 소비 | OOS-aware attribute reader 로 이어지는 호출 흐름 | `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` |
| physical image 보존 | inline stub 과 head OOS OID 를 유지해야 하는 WAL/recovery/MVCC/vacuum 계약 | stored-form 유지 |
| OOS-insensitive raw 소비 | header/fixed/CHN 등 실제 참조 byte 범위와 OOS inline stub 을 읽지 않는 근거 | `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` |
| record body 미사용 | 성공 여부, OID 등 실제 참조 결과와 `RECDES.data` 미사용 근거 | `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` |
| 정책 전달 wrapper | 모든 caller 의 소비 방식 또는 상위로 전달하는 정책 인자 | caller 결정 전달 |

`OOS 를 쓰지 않는 catalog 일 것 같다`, `기존부터 이 값이었다`, `안전을 위해 보수적으로 Expand 한다` 는 단독 근거로 인정하지 않는다.

### 3. 역방향 raw 소비자 조사

heap instance `RECDES.data` 를 읽거나 전달하는 연산을 검색하고, 입력값의 원점을 역추적한다. heap fetch 에서 온 값이면 실제로 읽거나 전달하는 byte 범위를 확인한다. full record/variable area 소비 경로는 호출 체인의 모든 wrapper 를 거쳐 `HEAP_RECDES_CONSUME_RAW_BYTES` 가 전달되는지 확인하고, header/fixed/CHN 전용 경로는 불필요한 Expand 가 없는지 확인한다.

WAL/undo/redo, CDC/flashback, replication, client/network 또는 callback 경로에서 온 값이면 physical image 보존과 logical row 해석의 경계를 찾는다. logical consumer 가 attribute layer 로 OOS Resolve 하거나 record-level Expand 하는지 확인하고, physical-image 단계는 inline stub 을 유지하는지 확인한다.

정책 API 에 도달하지 않는 fetch wrapper, 내부 hard-code, raw record 를 담는 별도 구조체, callback 으로 넘기는 경로도 조사표에 포함한다. 검색으로 찾기 어려운 alias 는 caller/callee 추적으로 보완한다.

### 4. 결과 반영

근거와 정책이 다른 단순 호출처는 본 이슈에서 수정하고 선택 이유를 짧은 코드 주석으로 남긴다. 공용 wrapper 가 raw/non-raw caller 를 함께 받으면 정책을 상위 caller 에서 전달하도록 signature 를 바꾼다.

별도 설계, protocol 변경, 광범위한 회귀 수정이 필요한 결함은 후속 이슈로 분리한다. 이 경우에도 CBRD-26847 조사표에는 결함, 영향 경로, 임시 상태, 후속 이슈를 남긴다.

## Acceptance Criteria

- [ ] 기준 commit 과 최종 commit 에서 정책-bearing API, 정책 고정 wrapper, 두 enum 값의 실제 호출처 수를 각각 산출한다.
- [ ] 모든 `HEAP_RECDES_CONSUME_RAW_BYTES` 호출처에 구체적인 raw-byte 소비 연산과 호출 흐름 근거가 있다.
- [ ] 모든 `HEAP_RECDES_DONT_CONSUME_RAW_BYTES` 호출처가 attribute layer 로 OOS-backed attribute 를 Resolve 하거나 header/fixed/CHN 만 읽거나 record body 를 사용하지 않음을 확인한다.
- [ ] 정책을 내부에서 고정하는 모든 wrapper 에 대해 단일 정책이 모든 caller 에 맞는지 확인하고, mixed consumer wrapper 는 정책을 상위에서 전달하도록 바꾼다.
- [ ] `LC_COPYAREA`/network 전송, raw memory 연산, `OR_BUF`/`or_*` 파싱, raw serialization, record 재삽입을 seed 로 역방향 조사하여 OOS-capable heap fetch 와 연결되는 모든 경로와 실제 소비 byte 범위를 표로 남긴다.
- [ ] WAL undo/redo 복원, CDC/flashback, replication 과 client/network 에서 전달되는 heap instance `RECDES` 를 역방향 조사하여 physical image 보존과 logical row 해석 경계를 표로 남긴다.
- [ ] physical image 보존 경로가 OOS inline stub 과 head OOS OID 를 materialize 하지 않고 유지함을 확인한다.
- [ ] `cdc_get_recdes()` 에서 복원한 undo/redo record 를 `cdc_make_dml_loginfo()` 가 읽는 경로가 OOS-backed attribute 를 Resolve 하는지 CDC와 flashback 양쪽에서 검증한다.
- [ ] 정방향 목록과 역방향 목록을 대조하여 한쪽에만 존재하는 경로가 0건임을 확인한다.
- [ ] 잘못 분류된 단순 정책 선택과 근거 없는 보수적 Expand 를 수정한다.
- [ ] 별도 작업이 필요한 발견 사항은 영향과 재현 경로가 포함된 후속 이슈로 연결한다.
- [ ] 정책 변경 경로마다 OOS-backed attribute 의 값 동등성을 검증하고, raw 소비자는 inline stub 이 노출되지 않으며 non-raw 소비자는 불필요한 record-level Expand 를 수행하지 않음을 확인한다.
- [ ] 전체 debug build 와 영향받는 SQL, unit, shell 회귀 테스트가 통과한다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] 조사표와 코드 변경 리뷰 완료
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영: 사용자-visible 동작 변경 없음. 내부 OOS context 와 코드 주석이 최종 정책과 일치하는지 확인

## Remarks

- Parent: CBRD-26583
- 선행 작업: CBRD-27029, PR #7416, merge commit `de84fa59e16aa0b863cfdbda4655f6c371dc0f86`
- 관련 raw fetch 회귀: CBRD-26948
- 기존 CBRD-26847 의 `_expand_oos` 호출처 목록과 A/B/C 분류는 historical input 으로만 사용한다. 최종 완료 근거는 현재 commit 에서 다시 만든 양방향 조사표다.
