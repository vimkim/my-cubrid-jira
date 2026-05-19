# [OOS] OOS 값 압축 메커니즘 분석 — 타입별 자동 압축 여부 정리

## Description

### 배경

OOS(Out-of-row Overflow Storage)에는 길이가 큰 가변(variable) 컬럼 값이 저장된다.
기능 요구사항 중 하나로 **"OOS 값을 자체적으로 압축해서 저장하는 메커니즘이 필요한가"** 가
제기되었다.

CUBRID 는 이미 일부 가변 타입에 대해 LZ4 기반 자동 압축을 수행하고 있으므로,
OOS 경로에서 별도 압축을 추가하기 전에 **현재 어떤 타입이 압축되고 어떤 타입이
압축되지 않는지** 를 코드로 확인할 필요가 있다.

### 목적

- OOS 에 적재되는 값이 자동 압축되는 경로를 코드로 입증한다.
- 현재 압축이 적용되는 타입과 적용되지 않는 타입을 분리하여 정리한다.
- 향후 OOS 전용 압축 도입 여부 판단의 근거 자료로 활용한다.

### 조사 결론

#### 한 줄 결론

> **모든 OOS 적재 대상 가변 타입에 대해, OOS 에 넣기 직전에 한 번 압축을 시도한다.**
> (= PostgreSQL TOAST 의 `EXTENDED` 정책을 OOS 레이어에서 그대로 구현)

#### 결정 (2026-05-08 OOS 회의)

- **방향**: PostgreSQL TOAST 의 `EXTENDED` 스펙을 따른다 (P사 스펙 채택).
- **구현 위치**: 타입별 직렬화 단계가 아니라 **OOS 진입 직전의 공통 단계** 에 압축을 둔다.
- **동작 순서**: `압축 시도 -> (그래도 크면) OOS 저장` 의 2 단계.
  - PG `EXTENDED` 의 "압축 후에도 임계값을 넘으면 TOAST 로 외부화" 와 동일 구조.
  - 본 문서에서 말하는 **"OOS 저장"** = PG 문서의 "외부(out-of-line) 저장" 에 해당하는 CUBRID 측 용어.
- **결과**: 현재는 `VARCHAR` 만 압축되지만, 변경 후에는 OOS 로 가는 **모든 가변 타입** (`VARCHAR`, `VARNCHAR`, `VARBIT`, `JSON`, `SET`, `MULTISET`, `SEQUENCE`) 이 동일하게 압축 혜택을 받는다.
- **출처**: [CBRD-26592](http://jira.cubrid.org/browse/CBRD-26592) Compression Behavior 표.

#### 왜 이렇게 결정했는가 (현재 코드 상태 요약)

본 조사로 확인한 현재 CUBRID 의 압축 동작은 타입별로 불균일하다.

| 타입 분류 | 대상 타입 | 현재 동작 | PG TOAST 용어 |
|---|---|---|---|
| 압축됨 | `VARCHAR` | `tp_String` 직렬화 시 LZ4 압축 후 OOS 페이지에 기록 | `EXTENDED` 와 동등 |
| 압축 안 됨 | `VARNCHAR`, `VARBIT`, `JSON`, `SET`, `MULTISET`, `SEQUENCE` | 직렬화 시 압축 없이 OOS 페이지에 기록 | `EXTERNAL` 과 동등 |
| 대상 외 | `BLOB`, `CLOB` | 본문은 외부 ES 에 저장, OOS 인라인은 locator 뿐 | OOS 압축 정책의 범주 외 |

즉 **타입에 따라 압축 혜택을 받기도 하고 못 받기도 하는 현재 상태** 를 통일하기 위해, 타입별 경로가 아니라 **OOS 공통 진입점에서 압축** 하기로 정한 것이다.

> 본 결론을 뒷받침하는 코드 경로 / `pr_do_db_value_string_compression` / `data_writeval` 콜백별 압축 호출 유무 / 타입 매핑 / OR-buf 단계 압축 입증 — **하단 코멘트 #1 (Analysis · Findings · Remarks) 참조.**

#### 후속 구현 시 고려사항 (본 티켓 범위 외, 별도 후속 티켓에서 다룸)

1. **공통 압축 단계 신설 위치**: OOS 인서트 경로의 공통 지점 (예: `heap_attrinfo_insert_to_oos` 직전 또는 내부 공통 함수).
2. **알고리즘 / 임계값 선정**: LZ4 / pglz / 기타. PG 의 `pglz` 는 `min_comp_rate >= 25%` 등 압축 효과가 부족하면 원본 유지. CUBRID 도 유사 정책 필요.
3. **이중 압축 회피**: `VARCHAR` 는 이미 `tp_String` 단계에서 LZ4 압축되므로 그대로 다시 압축하면 손해다. 다음 중 하나 선택 필요.
   - case A: type-layer 압축을 OOS 진입 시 해제 -> OOS-layer 에서 재압축
   - case B: type-layer 결과를 그대로 통과 (OOS-layer 에서 skip)
   - case C: `VARCHAR` 에 한해 OOS-layer 압축을 skip
4. **메타 인코딩**: 압축 알고리즘 ID, 원본 크기 등을 OOS 레코드 헤더 또는 인라인 포인터에 적재할 필드 필요. PG `va_extinfo` 에 해당하는 슬롯이 현재 CUBRID OOS 에는 없음 (참조: CBRD-26592 Inline Reference 표).
5. **토글 정책**: 전역 토글 `pr_Enable_string_compression` 을 OOS 압축에도 재사용할지, 별도 파라미터를 둘지 결정.

---

## 설계 옵션 비교 — 권장안 요약 (구두 피드백 사항, 2026-05-19)

세 가지 설계 옵션을 비교했다.

| ID | 명칭 | 한 줄 요약 |
|---|---|---|
| **A** | OOS 진입 직전 공통 압축 | 현 VARCHAR 압축은 그대로 두고, OOS 적재 직전에 LZ4 wrapper 한 번 |
| **B** | `data_writeval` / `pr_do_db_value_string_compression` 일반화 | 현 VARCHAR 와 동일한 시점·메커니즘을 다른 가변 타입에도 확장 |
| **C** | VARCHAR 압축 제거 + OOS-layer 로 단일화 | 압축 분기 일체 제거, 압축은 오직 OOS 레이어 |

### 권장안: Option A 채택

핵심 근거 (정량):

- **변경 면적**: A ≈ 400~500 LOC (OOS 레이어 + `system_parameter` 토글로 국한). B ≈ 1,500~2,000 LOC + 인덱스/HA 호환성 부채. C ≈ 1,200~1,500 LOC + 마이그레이션 비용.
- **호환 부담 차원 수**: A = 1 (OOS payload prefix), B = 3 (인덱스 + WAL + HA wire), C = 4 (heap + WAL + HA + 카탈로그).
- **마이그레이션 강제 여부**: A = 없음, B = 인덱스 키 포맷에 따라 있음, C = 필수 (dump/restore).
- **롤링 업그레이드 가능 여부**: A = 가능 (OOS 자체가 unreleased), B = 불가, C = 불가.
- **목적 부합**: 본 작업 목적인 "JSON / VARBIT / SET / MULTISET / SEQUENCE 의 OOS 단계 압축 누락" 을 A 하나로 충족.

### Option C ("varchar 압축 제거 후 OOS 로 통일") 가 너무 breaking 한가?

**예, 너무 breaking 합니다.** 단순 LOC 합산은 1,200~1,500 line 이지만 disk + WAL + HA wire + 카탈로그 포맷이 동시에 깨져 dump/restore 마이그레이션이 강제되고, legacy compressed-VARCHAR reader 영구 유지 필요로 제거 효과의 절반 이상이 상쇄된다.

### 이중 압축 회피 술어

```
skip_oos_compression(value) :=
  DB_VALUE_DOMAIN_TYPE(value) == DB_TYPE_VARCHAR
  && charlen >= OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION  // 255
```

→ 현 `pr_do_db_value_string_compression` (`object_primitive.c:14260`) 의 게이트와 동일 조건이므로, OR-layer 가 압축을 시도한 경우 ↔ OOS-layer 가 skip 하는 경우가 정확히 일치 (false-positive/negative 0). VARNCHAR / VARBIT / JSON / SET / MULTISET / SEQUENCE 는 OR-layer 압축이 없으므로 전부 OOS-layer 압축 대상.

> **옵션별 상세 분석 (코드 인용 · grep 집계 · 옵션 A/B/C 별 Pros/Cons/LOC 견적 · WAL/HA/btree 호환성 분석) 은 하단 코멘트 #2 (설계 옵션 비교 상세) 참조.**

---

## Acceptance Criteria

- [x] OOS 적재 경로(`heap_attrinfo_insert_to_oos` -> `data_writeval`) 가
      일반 heap 직렬화 경로와 동일하게 `data_writeval` 콜백을 호출함을 확인한다.
- [x] `pr_do_db_value_string_compression` 이 `DB_TYPE_VARCHAR` 에만 동작하고,
      `OR_MINIMUM_STRING_LENGTH_FOR_COMPRESSION = 255` 임계값을 가짐을 확인한다.
- [x] `tp_String` 외 가변 타입의 `data_writeval` 콜백에 LZ4 호출이 없음을
      확인한다 (`mr_writeval_char_internal`, `mr_writeval_varbit_internal`,
      `mr_data_writeval_json`, `mr_data_writeval_set`).
- [x] OOS 진입 가능하지만 압축이 미적용인 타입 목록을 정리한다
      (VARNCHAR/VARBIT/JSON/SET/MULTISET/SEQUENCE).
- [x] OOS 압축 정책 방향을 의사결정한다 → 2026-05-08 OOS 회의에서
      "P사(PG) `EXTENDED` 스펙을 OOS 레이어 자체에서 구현" 으로 확정.
- [x] 설계 옵션 A/B/C 비교 및 권장안 작성 (2026-05-19, 하단 코멘트 #2 상세).
- [ ] EXTENDED-at-OOS 구현 (알고리즘 선정, 이중 압축 회피, 메타 인코딩,
      토글 정책) 을 별도 후속 티켓에서 진행한다.
