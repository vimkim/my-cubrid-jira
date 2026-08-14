# [CBRD-26979] 고정 길이 컬럼의 OOS STORAGE 옵션 적격성 검증

## Issue Triage

**이슈 수행 목적**: `OOS`(Out-of-row Overflow Storage) 컬럼 정책에서 방향을 지정하는 옵션과 타입 기본값으로
돌아가는 `STORAGE DEFAULT`를 구분한다. 실제 CLASS의 normal attribute에 대해 고정 타입은 `DEFAULT`만
허용하고, OOS 배치 방향을 지정하는 옵션은 계속 거부한다.

**이슈 수행 이유**:

| 구분 | 동작 및 영향 |
|---|---|
| **AS-IS (기준 브랜치)** | 고정 길이 `INT`에도 `PREFER_INLINE`, `PREFER_OUTLINE`, `DEFAULT`가 허용되고 `FORCE_OUTLINE`만 실패한다. 무효한 OOS 방향 정책이 schema와 `SHOW CREATE TABLE`에 남을 수 있다. |
| **현재 구현안 (`c47b705`)** | 네 가지 명시적 옵션을 같은 적격성 검사로 묶어 고정 타입에서 모두 거부한다. 방향성 옵션의 문제는 해결하지만, 중립적인 reset으로 읽히는 `STORAGE DEFAULT`까지 실패한다. |
| **리뷰 우려** | `@lht1199` 임형태님은 inline/outline 방향을 지정하는 옵션이 고정 타입에서 실패하는 것은 이해할 수 있지만, OOS 맥락이 드러나지 않는 일반적인 표현인 `STORAGE DEFAULT`까지 실패하면 사용자에게 매우 혼란스럽다는 의견을 주셨다. |
| **TO-BE (권고)** | 실제 CLASS의 normal attribute라면 고정 타입의 `STORAGE DEFAULT`는 타입 기본값으로의 reset/no-op으로 허용한다. `PREFER_INLINE`, `PREFER_OUTLINE`, `FORCE_OUTLINE`은 계속 실패한다. CLASS/SHARED/VCLASS 속성의 명시적 `STORAGE`는 타입과 관계없이 계속 실패한다. |
| **영향** | 무효한 OOS 방향 정책은 차단하면서도 `DEFAULT`의 자연어 의미와 PostgreSQL의 타입별 기본값 복원 동작을 유지한다. |

**이슈 수행 방안**: parse tree에서 현재 같은 값인 `DEFAULT`와 `PREFER_OUTLINE`을 분리하고
`attr_storage`를 2비트에서 3비트로 넓힌다. 공통 validator는 object kind와 물리 타입을 함께 검사하되,
실제 CLASS의 fixed-layout normal attribute에는 명시적 `DEFAULT`만 예외로 허용한다. catalog 정책 flag는
늘리지 않으며, `DEFAULT`는 기존 override를 제거한다. `FORCE_INLINE`은 아래 계약을 갖춘 별도 기능으로
추가하는 것을 권고하며, CBRD-26979의 필수 수정 범위에는 포함하지 않는다.

---

## AI-Generated Context

> 아래는 AI가 CUBRID 소스, PostgreSQL 18.6 공식 소스와 문서, 실제 PostgreSQL 18.6 실행 결과를 분석해
> 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 스펙 합의와 구현 및
> 리뷰 단계에서 참고하면 된다.

## Description

OOS의 컬럼별 정책은 현재 `STORAGE PREFER_INLINE`, `FORCE_OUTLINE`, `PREFER_OUTLINE`, `DEFAULT` 문법으로
지정한다. 기준 브랜치에서는 옵션마다 검사가 달라 `FORCE_OUTLINE`만 fixed-layout 타입에서 실패했다.
현재 CBRD-26979 구현은 네 spelling을 공통 helper로 검증하여 이 비대칭을 제거했지만, 모든 명시적
`STORAGE`를 OOS 방향 정책으로 간주한 결과 `DEFAULT`도 함께 거부한다.

`DEFAULT`와 방향성 옵션은 사용자 계약이 다르다.

| 분류 | 현재 문법 | 고정 타입에서의 의미 |
|---|---|---|
| 기본값 복원 | `DEFAULT` | 타입 기본 저장 동작으로 돌아가는 중립적 reset/no-op |
| soft 방향 | `PREFER_INLINE`, `PREFER_OUTLINE` | OOS demotion 우선순위를 지정하지만 고정 타입은 OOS 후보가 될 수 없음 |
| hard 방향 | `FORCE_OUTLINE` | OOS 배치를 강제하지만 고정 타입은 OOS 후보가 될 수 없음 |

따라서 적격성은 "`STORAGE` 절이 있는가" 하나로 판단하지 않고 object kind, 물리 배치 능력, 요청한
clause를 함께 해석해야 한다.

```text
STORAGE 절 생략
  -> 성공

실제 CLASS의 normal attribute
  + variable layout
    -> 현재의 모든 STORAGE clause 성공
  + fixed layout
    -> DEFAULT만 성공
    -> PREFER_INLINE / PREFER_OUTLINE / FORCE_OUTLINE 실패

CLASS attribute / SHARED attribute / VCLASS attribute
  + 명시적 STORAGE clause
    -> 타입과 관계없이 실패
```

물리 분류는 SQL 타입 이름의 인상이 아니라 `pr_is_variable_type(TP_DOMAIN_TYPE(domain))`으로 결정한다.
예를 들어 CUBRID `CHAR`는 물리적으로 가변이므로 적격하지만, `BIT(n)`은 fixed layout이므로 고정 타입
규칙을 적용한다.

## Reviewer Concern

`@lht1199` 임형태님이 구두로 전달한 의견의 요지는 다음과 같다.

> `FORCE_INLINE`, `FORCE_OUTLINE`처럼 배치 방향을 지정하는 옵션을 fixed type과 함께 사용할 때 실패하는
> 것은 이해할 수 있다. 그러나 `STORAGE DEFAULT`라는 문구 자체에는 OOS 방향 맥락이 없고 일반적인
> "기본 저장 방식"으로 읽힌다. fixed type에서 이것까지 실패하면 일반 사용자에게 혼란스럽다.

이 우려는 syntax spelling과 내부 구현의 의미가 어긋나는 문제다. 현재 parse tree는
`PT_ATTR_STORAGE_PREFER_OUTLINE = PT_ATTR_STORAGE_DEFAULT`로 두 spelling을 같은 enum 값에 합친다.
따라서 semantic 단계에서는 사용자가 중립적인 `DEFAULT`를 썼는지, outline 방향을 명시했는지 구분할 수
없다. 사용자 계약을 구분하려면 parser 표현부터 분리해야 한다.

## PostgreSQL Comparison

CUBRID 문법의 출발점인 PostgreSQL TOAST `SET STORAGE` 동작을 PostgreSQL 18.6에서 확인했다.

| PostgreSQL 컬럼 | STORAGE clause | 결과 | 최종 `attstorage` |
|---|---|---|---|
| `integer` | `PLAIN` | 성공 | `p` |
| `integer` | `DEFAULT` | 성공 | `p` |
| `integer` | `MAIN` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `integer` | `EXTERNAL` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `integer` | `EXTENDED` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `char(10)` / `bpchar` | 다섯 모드 | 모두 성공 | 요청 모드, `DEFAULT`는 `x` |

PostgreSQL 구현은 `DEFAULT`를 먼저 해당 타입의 `typstorage`로 해석한다. 그 결과 fixed-length `integer`의
`DEFAULT`는 `PLAIN`이 되어 허용되고, `MAIN`/`EXTERNAL`/`EXTENDED`는
`column data type integer can only have storage PLAIN`으로 실패한다. 반면 `char(n)`의 물리 타입
`bpchar`는 `typlen=-1`, `typstorage=x`인 varlena이므로 다섯 모드를 모두 허용한다.

이는 CUBRID에서도 타입 이름보다 물리 배치 능력을 기준으로 삼되, `DEFAULT`는 그 타입의 기본값으로
해석해야 한다는 리뷰 의견을 뒷받침한다.

공식 근거:

- [PostgreSQL 18 ALTER TABLE - SET STORAGE](https://www.postgresql.org/docs/18/sql-altertable.html#SQL-ALTERTABLE-DESC-SET-STORAGE)
- [PostgreSQL 18 TOAST storage](https://www.postgresql.org/docs/18/storage-toast.html)
- [PostgreSQL REL_18_6 `GetAttributeStorage()`](https://github.com/postgres/postgres/blob/724edf9bde9d356724ad384a2e196edc3c9f80f7/src/backend/commands/tablecmds.c)
- [상세 비교 및 실행 기록](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26979/CBRD-26979-storage-variable-type-validation_882f70f_codex.md)

## FORCE_INLINE Decision Review

`FORCE_INLINE`은 `FORCE_OUTLINE`의 반대편 hard policy로서 제품에 추가할 가치가 있다. 특히 variable-layout
속성을 OOS demotion 후보에서 완전히 제외할 수 있어 `PREFER_INLINE`과 독립적인 사용자 제어력을 제공한다.
다만 CBRD-26979의 `DEFAULT` 예외와 함께 작은 parser 수정으로 취급하면 안 된다. grammar, persisted schema
flag, ALTER 전환, heap layout planner, `SHOW CREATE TABLE`/unload/LIKE 라운드트립, overflow 및 복구 테스트가
함께 필요하므로 별도 기능 범위로 분리한다.

정확한 계약은 다음과 같다.

> `FORCE_INLINE`은 새 디스크 배치에서 해당 속성 값을 OOS inline stub으로 바꾸지 않는다는 뜻이다.
> 전체 heap 레코드가 반드시 home page에 남는다는 뜻은 아니다.

CUBRID는 OOS-backed attribute가 없는 큰 레코드를 `REC_BIGONE`으로 저장할 수 있다. 따라서 모든 속성이
fixed 또는 `FORCE_INLINE`인 큰 레코드는 OOS를 사용하지 않은 채 `REC_BIGONE`이 될 수 있다. 반대로 다른
속성이 OOS로 demote된 뒤 남은 inline payload가 여전히 `REC_BIGONE`을 요구하면 현재의 OOS+bigone 금지
규칙에 따라 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`로 실패해야 한다. 이 경우 정책을 무시하고
`FORCE_INLINE` 값을 OOS로 보내는 fallback은 두지 않는다.

고정 타입의 **효과상 기본 정책**은 `FORCE_INLINE`으로 정의한다. 다만 이는 타입의 내재된 OOS 부적격성에서
계산하며 schema flag로 저장하거나 `SHOW CREATE TABLE`에 자동 출력하지 않는다.

| 향후 fixed-layout DDL | 결과 | catalog 및 canonical DDL |
|---|---|---|
| `INT` | 성공, 효과상 `FORCE_INLINE` | flag 없음, 절 없음 |
| `INT STORAGE DEFAULT` | 성공, 타입 기본값으로 reset | flag 없음, 절 없음 |
| `INT STORAGE FORCE_INLINE` | 성공, 내재된 기본값과 동일 | flag 없음, 절 생략 |
| `INT STORAGE PREFER_INLINE` | 실패 | OOS 방향 지정 불가 |
| `INT STORAGE PREFER_OUTLINE` | 실패 | OOS 방향 지정 불가 |
| `INT STORAGE FORCE_OUTLINE` | 실패 | OOS 강제 불가 |

variable-layout 타입의 명시적 `FORCE_INLINE`은 실제 사용자 override이므로 별도 flag로 저장하고 canonical
DDL에 출력한다. 타입 변경 시에는 다음 원칙을 적용한다.

- variable -> variable, `STORAGE` 생략: 호환되는 기존 override를 보존한다.
- variable -> fixed: 기존 OOS override를 제거하고 fixed 타입의 내재된 기본값을 적용한다.
- fixed -> variable, `STORAGE` 생략 또는 `DEFAULT`: 새 variable 타입의 기본값을 적용한다.
- fixed -> variable에서 hard inline을 유지하려면 ALTER에 `STORAGE FORCE_INLINE`을 명시한다.

이 정규화는 고정 타입에서 의미가 없던 flag가 타입 변경 뒤 갑자기 hard policy로 활성화되는 일을 막는다.

## Implementation Direction

### CBRD-26979 필수 범위

- `PT_ATTR_STORAGE_DEFAULT`와 `PT_ATTR_STORAGE_PREFER_OUTLINE`에 서로 다른 enum 값을 부여한다.
- `UNSET`, `DEFAULT`, `PREFER_OUTLINE`, `PREFER_INLINE`, `FORCE_OUTLINE`을 표현하도록
  `attr_storage:2`를 `attr_storage:3`으로 넓힌다.
- 실제 CLASS의 normal attribute인지 먼저 검사한다. fixed layout이면 `DEFAULT`만 통과시킨다.
- explicit `DEFAULT`는 기존 `PREFER_INLINE`/`FORCE_OUTLINE` override를 제거한다.
- catalog 및 on-disk flag는 변경하지 않는다.

### 후속 FORCE_INLINE 범위

- variable override용 `SM_ATTFLAG_OOS_FORCE_INLINE`을 추가하고 OOS policy flag를 one-hot으로 관리한다.
- `OR_ATTRIBUTE_OOS_STORAGE_FORCE_INLINE`을 추가하고 heap 후보 수집에서 해당 속성을 제외한다.
- fixed 타입의 내재된 기본값에는 위 flag를 저장하지 않는다.
- `SHOW CREATE TABLE`, unload/load, `CREATE LIKE`, ALTER 전환 및 복구/복제 round-trip을 검증한다.
- all-FORCE_INLINE `REC_BIGONE` 성공과 mixed OOS+bigone의 사전 실패를 모두 검증한다.

CREATE/ADD/MODIFY/CHANGE가 각자 예외를 구현하지 않도록 schema seam에는 하나의 resolver를 두는 것이
바람직하다.

```text
resolve_oos_storage_policy(attribute_kind, physical_layout,
                           requested_clause, old_override, ddl_operation)
  -> effective_policy + persisted_override
  -> or semantic error
```

resolver는 `DEFAULT` reset, 타입별 기본값, 호환되지 않는 ALTER policy 정리, flag 상호 배제를 숨긴다.
heap layout planner는 정규화된 정책만 받아 intrinsic fixed 여부와 `FORCE_INLINE`을 후보에서 제외한다.

## Repro

```sql
-- CBRD-26979: 성공해야 한다.
CREATE TABLE t_fixed_default (c INT STORAGE DEFAULT);

-- CBRD-26979: 모두 실패해야 한다.
CREATE TABLE t_fixed_prefer_inline (c INT STORAGE PREFER_INLINE);
CREATE TABLE t_fixed_prefer_outline (c INT STORAGE PREFER_OUTLINE);
CREATE TABLE t_fixed_force_outline (c INT STORAGE FORCE_OUTLINE);

-- object-kind 회귀: DEFAULT도 실패해야 한다.
CREATE VCLASS v_storage_default (c VARCHAR(4096) STORAGE DEFAULT);
```

## Expected Result

`t_fixed_default`만 성공한다. 세 방향성 옵션은 fixed layout에 OOS 배치 방향을 지정할 수 없다는 semantic
error로 실패한다. VCLASS의 명시적 `DEFAULT`는 행별 OOS 정책 대상이 아니므로 실패한다.

ALTER에서 explicit `DEFAULT`는 기존 OOS override를 제거한다. `STORAGE` 절을 생략한 호환 가능한
variable-to-variable ALTER는 기존 override를 보존한다.

## Actual Result

- 기준 브랜치: fixed `PREFER_INLINE`, `PREFER_OUTLINE`, `DEFAULT`가 성공하고 `FORCE_OUTLINE`만 실패한다.
- 현재 구현 `c47b70596b8e564f203497f0a2f381697fc56f74`: fixed 타입의 네 명시적 옵션이 모두 실패한다.
- 따라서 reviewer concern을 반영하려면 현재 구현에서 `DEFAULT`와 `PREFER_OUTLINE` spelling을 분리하고
  fixed normal attribute의 explicit `DEFAULT`만 허용하는 후속 수정이 필요하다.

## Additional Information

- JIRA: http://jira.cubrid.org/browse/CBRD-26979
- 상위 이슈: https://jira.cubrid.org/browse/CBRD-26583
- 현재 구현 commit: `c47b70596b8e564f203497f0a2f381697fc56f74`
- 비교 문서: https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26979/CBRD-26979-storage-variable-type-validation_882f70f_codex.md
- 문서 갱신 commit: `89b170b` (`FORCE_INLINE` 검토 포함)
- 핵심 코드: `src/parser/parse_tree.h`, `src/query/execute_schema.c`, `src/storage/heap_file.c`,
  `src/object/object_printer.cpp`
