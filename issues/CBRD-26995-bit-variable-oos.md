# [Non-OOS] [Proposal] BIT 타입을 fixed 에서 variable 로 전환해 OOS 대상에 포함

## Issue Triage

**이슈 수행 목적**: `BIT(n)` 컬럼도 큰 값이면 OOS (Out-of-row Storage) 이관 대상이 되도록 타입 저장 표현을 가변 길이 기반으로 전환한다. SQL 타입 의미는 유지하고, heap 레코드 배치 정책만 `CHAR` 의 최근 전환과 같은 방향으로 맞춘다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: 현재 `tp_Bit.variable_p = 0` 이라 `BIT(n)` 은 class representation (컬럼 디스크 배치 메타데이터)에서 fixed attribute 로 배치된다. OOS 이관 조건은 `DB_PAGESIZE/4` 를 넘는 레코드에서 `!is_fixed && column_size > OR_OOS_INLINE_SIZE`(16 바이트) 인 컬럼이므로, 사용자 정의 길이가 큰 `BIT(n)` 은 `DB_MAX_BIT_LENGTH`(0x3fffffff bit) 까지 커질 수 있는데도 OOS 후보가 되지 않는다.
- **영향**: 설계 의도 훼손 — 큰 `BIT(n)` 이 heap 내부의 큰 fixed payload 로 남아 OOS 로 줄일 수 있는 레코드까지 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 경로에 걸릴 수 있다.

**이슈 수행 방안**: 사용자 요청: "`BIT` type 을 fixed 에서 variable 로 변경하고, 최근 develop 의 `CHAR` fixed→variable 전환 패치와 같은 방향으로 제안". 이를 기준으로 `tp_Bit.variable_p` 를 `1` 로 전환하는 방안을 검토한다. 기존 데이터 호환 방식, 디스크 헤더 형식, `BIT`/`VARBIT` 공통화 범위는 `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: JIRA type 은 Sub-task 이며 parent 는 `CBRD-26978` 이다. 주요 영향 파일은 `src/object/object_primitive.c`, `src/object/schema_manager.c`, `src/base/object_representation_sr.c`, `src/storage/heap_file.c`, BIT 관련 parser/loaddb/index 경로다. 기존 DB 파일의 fixed `BIT` 레코드 읽기 호환 여부가 가장 큰 검토 지점이다.

---

## Description

현재 CUBRID 의 class representation 은 primitive type 의 `variable_p` 값을 기준으로 attribute 를 fixed 영역과 variable 영역으로 나눈다. `schema_manager.c` 는 `found->type->variable_p` 가 true 인 attribute 를 variable list 로 보내고, false 인 attribute 를 fixed list 로 보낸다. 서버가 class representation 을 읽을 때는 이 순서를 다시 `OR_ATTRIBUTE.is_fixed` 로 복원한다.

OOS 는 이 `is_fixed` 값을 직접 본다. `heap_attrinfo_determine_disk_layout` 은 레코드가 `DB_PAGESIZE/4` 를 넘을 때, variable column 이고 값 크기가 `OR_OOS_INLINE_SIZE` 보다 큰 컬럼만 후보로 삼는다. 따라서 `BIT(n)` 이 fixed attribute 로 남아 있으면 값이 커도 이관 대상이 아니다.

최근 develop 에 들어간 `CBRD-26663` 은 `CHAR` 를 fixed-length storage 에서 variable-length storage 로 옮겼다. 해당 커밋의 설명은 `tp_Char.variable_p = 1` 로 설정해 `VARCHAR` 와 같은 variable attribute flow 를 공유한다고 정리한다. 현재 코드도 그 상태다.

| 타입 | 현재 `variable_p` | class representation 배치 | OOS 후보 가능성 |
|------|-------------------|----------------------------|----------------|
| `CHAR` | `1` | variable | 가능 |
| `VARCHAR` | `1` | variable | 가능 |
| `BIT` | `0` | fixed | 불가 |
| `BIT VARYING` | `1` | variable | 가능 |

### BIT 최대 크기와 fixed 타입 현황

`BIT` 의 최대 precision 은 매뉴얼과 코드에서 모두 `DB_MAX_BIT_LENGTH`(0x3fffffff) 로 정의된다. 이는 1,073,741,823 bit 이며, `BITS_TO_BYTES(n)` 계산 기준으로 디스크 payload 는 최대 134,217,728 byte(128 MiB) 까지 필요하다. `BIT` 을 precision 없이 선언하면 1 bit 로 처리된다.

| 구분 | 예 | row payload 크기 | OOS 관점 |
|------|----|------------------|----------|
| fixed 이면서 사용자 정의 길이로 매우 커질 수 있는 타입 | `BIT(n)` | `ceil(n / 8)` byte, 최대 128 MiB | 현재 `tp_Bit.variable_p = 0` 이라 OOS 후보가 되지 않는 핵심 대상 |
| fixed 이지만 row payload 가 작게 bounded 된 타입 | integer, date/time, monetary, OID, enum | 타입별 고정 크기. enum 은 row 에 `unsigned short` 값만 저장 | OOS 로 보낼 대형 payload 가 아니므로 별도 조치 필요성이 낮음 |
| variable 로 이미 분류되는 대형 가능 타입 | `VARCHAR`, `CHAR`, `NCHAR`, `BIT VARYING`, `BLOB`, `CLOB`, collection, `JSON` | 값 크기 기반 variable payload. `CHAR`/`NCHAR` 도 최근 전환 후 variable flow 사용 | 레코드 gate 와 `OR_OOS_INLINE_SIZE` 조건을 만족하면 기존 OOS 후보 경로에 진입 가능 |

따라서 현재 코드 기준으로 "`BIT` 처럼 fixed 로 남아 있으면서 사용자가 정의한 길이 때문에 OOS 크기 문제가 될 수 있는 일반 SQL 타입" 은 `BIT(n)` 이 유일한 후보로 보인다. `NUMERIC` 은 precision 을 갖지만 `tp_Numeric.variable_p = 1` 이고 최대 precision 도 제한적이라 이 이슈의 주된 위험군이 아니다.

`BIT` 도 `CHAR` 처럼 SQL 의미와 저장 표현을 분리할 수 있다. 논리적으로는 `BIT(n)` 의 precision 과 comparison semantics 를 유지하되, on-disk heap record 안에서는 variable attribute 로 배치하면 OOS 이관 조건을 만족할 수 있다.

```
[현재]
tp_Bit.variable_p = 0
  -> schema_manager: fixed list
  -> OR_ATTRIBUTE.is_fixed = 1
  -> heap_attrinfo_determine_disk_layout: OOS 후보 제외

[제안]
tp_Bit.variable_p = 1
  -> schema_manager: variable list
  -> OR_ATTRIBUTE.is_fixed = 0
  -> heap_attrinfo_determine_disk_layout: 크면 OOS 후보
```

## Specification Changes

신규로 생성되는 `BIT(n)` 컬럼의 물리 저장 표현을 variable attribute 로 전환한다. SQL 타입명, precision 제한, 값 비교 규칙, `BIT` 과 `BIT VARYING` 의 타입 구분은 유지한다.

OOS 관점의 동작은 다음을 목표로 한다.

- 레코드가 `DB_PAGESIZE/4` 를 넘고 `BIT(n)` 값의 serialized size 가 `OR_OOS_INLINE_SIZE` 보다 크면 `BIT(n)` 도 largest-first OOS demotion 후보가 된다.
- OOS 로 이관된 `BIT(n)` 값은 다른 OOS column 과 같은 `OR_VAR_BIT_OOS` 표시와 16 바이트 OOS OID inline stub 을 사용한다.
- `BIT VARYING` 의 기존 동작은 유지한다.

다음 항목은 ANALYSIS 단계에서 확정해야 한다.

| 항목 | 상태 |
|------|------|
| 기존 fixed `BIT` record 를 새 코드가 읽는 방식 | `TBD - ANALYSIS 단계에서 결정` |
| `BIT` 이 `BIT VARYING` 의 header/write/read helper 를 공유할지 여부 | `TBD - ANALYSIS 단계에서 결정` |
| catalog/repr version 전환 또는 migration 필요 여부 | `TBD - ANALYSIS 단계에서 결정` |
| index key 및 midxkey encoding 변경 필요 여부 | `TBD - ANALYSIS 단계에서 결정` |

## Implementation

핵심은 OOS 코드를 직접 특수 처리하는 것이 아니라, `BIT` 을 variable attribute 로 분류되게 만드는 것이다. 그렇게 하면 OOS 후보 판정은 기존 `heap_attrinfo_determine_disk_layout` 경로를 그대로 탄다.

```
[DDL / class repr 생성]
SM_ATTRIBUTE.type->variable_p
  ├ 0 -> fixed list
  └ 1 -> variable list

[record layout 산정]
OR_ATTRIBUTE.is_fixed
  ├ 1 -> tp_domain_disk_size(domain) 로 fixed payload 산정
  └ 0 -> pr_data_writeval_disk_size(value) 로 variable payload 산정
           └ column_size > OR_OOS_INLINE_SIZE 이면 OOS 후보 가능
```

구현 검토 지점은 다음과 같다.

| 영역 | 확인할 내용 |
|------|-------------|
| primitive type 정의 | `tp_Bit.variable_p` 를 `1` 로 바꾸는 것만으로 충분한지, `size`/`disksize`/alignment 를 `tp_VarBit` 과 맞춰야 하는지 확인한다. |
| BIT read/write 경로 | `mr_data_lengthval_bit`, `mr_data_writeval_bit`, `mr_data_readval_bit` 이 variable attribute 영역에서도 크기 헤더를 안정적으로 처리하는지 검증한다. |
| 기존 데이터 호환 | 이전 class representation 의 fixed `BIT` 와 신규 variable `BIT` 가 한 서버에서 공존할 수 있어야 한다. |
| index/midxkey | `BIT` index key encoding 과 prefix/midxkey 계산이 fixed attribute 전제를 갖고 있는지 확인한다. |
| loader/unloader | loaddb/unloaddb 가 `BIT` 값을 논리 타입 기준으로 dump/load 하므로 저장 표현 전환에 영향을 받지 않는지 확인한다. |
| OOS regression | `BIT(n)` 단독 대형 row, `BIT(n)` + 다른 OOS column, UPDATE/ROLLBACK/replication/vacuum 경로를 함께 검증한다. |
| fixed 타입 재점검 | `BIT(n)` 외에 fixed layout 으로 남은 일반 SQL 타입 중 대형 row payload 를 만들 수 있는 타입이 새로 발견되는지 확인한다. |

## Acceptance Criteria

- [ ] 신규 생성 table 의 큰 `BIT(n)` 컬럼이 variable attribute 로 배치된다.
- [ ] 큰 `BIT(n)` 이 `DB_PAGESIZE/4` 레코드 gate 와 `OR_OOS_INLINE_SIZE` column floor 를 만족하면 OOS 로 이관된다.
- [ ] `BIT(n)` 의 SQL semantics, comparison, cast, index scan 결과가 기존과 동일하다.
- [ ] 기존 DB 의 fixed `BIT` record 를 새 바이너리에서 정상 조회할 수 있거나, 호환 불가 시 명시적 migration/제약 정책이 문서화된다.
- [ ] `BIT(n)` 외 fixed layout 타입 중 OOS 후보화가 필요한 대형 row payload 타입이 없는지 분석 결과가 PR 또는 설계 문서에 남는다.
- [ ] `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 는 모든 OOS 가능 컬럼을 이관한 뒤에도 inline record 가 `heap_Maxslotted_reclength` 를 넘는 경우에만 발생한다.

## Definition of done

- [ ] 위 A/C 충족
- [ ] SQL regression 에 `BIT(n)` OOS demotion, non-OOS boundary, UPDATE/ROLLBACK 케이스 추가
- [ ] 기존 BIT/VARBIT/CHAR/VARCHAR regression 통과
- [ ] loaddb/unloaddb, index, replication 영향 확인
- [ ] 문서/매뉴얼 반영

## Remarks

- 관련 선행 변경: `CBRD-26663` (`CHAR/VARCHAR unified variable-length storage`) 은 `CHAR` 를 fixed-length storage 에서 variable-length storage 로 옮기고 `tp_Char.variable_p = 1` 로 변경했다.
- 관련 OOS 변경: `CBRD-26937` 은 OOS OID 를 가진 레코드가 동시에 `REC_BIGONE` 으로 저장되는 조합을 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거절한다.
