# [OOS] SQL STORAGE FORCE_INLINE 지원 및 고정 길이 컬럼의 DEFAULT 허용

## Issue Triage

**이슈 수행 목적**: 컬럼 값을 OOS로 분리하지 않는 `STORAGE FORCE_INLINE` 을 지원한다. 고정 길이 일반 컬럼에도 `STORAGE DEFAULT` 를 허용하고, 이때의 기본 동작이 효과상 `FORCE_INLINE` 과 같음을 명확히 한다.

**이슈 수행 이유**: CBRD-26979에서는 고정 길이 컬럼의 명시적 `STORAGE` 옵션을 모두 거부하도록 검사를 통일했다. 그러나 타입 기본값으로 복귀하려는 `DEFAULT` 까지 거부하며, 가변 길이 컬럼에는 OOS 분리를 금지하는 정책이 없다. 선행 PR 리뷰에서 분리한 두 후속 요구를 본 이슈에서 다룬다.

**영향**: DDL 작성자와 스키마 관리 도구는 고정 길이 컬럼의 기본 정책을 명시하거나, 특정 가변 길이 컬럼의 OOS 분리를 확실히 금지할 수 없다. 실제 고객 발생 사례, 성능 영향의 크기와 발생 빈도는 확인되지 않았으며 ANALYSIS에서 확인한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 이슈, 선행 PR 리뷰, 설계 검토 문서와 OOS 명세를 바탕으로 작성한 상세 맥락이다. 현재 동작과 본 이슈의 목표를 구분하며, SQL 예시는 이번 작성에서 실행하지 않은 검증 시나리오다.

## Description

### 무엇이 문제인가

OOS(Out-of-row Overflow Storage)는 큰 가변 길이 컬럼 값을 별도 OOS 파일에 저장하고, 행에는 해당 값을 찾기 위한 OOS inline stub을 남기는 기능이다. 어떤 컬럼을 분리할지는 행 크기와 컬럼별 저장 정책에 따라 결정한다.

기존 `PREFER_INLINE` 은 inline 저장을 선호하는 정책이다. 다른 후보를 먼저 OOS로 분리한 뒤에도 필요하면 해당 컬럼을 분리할 수 있으므로, OOS 분리를 금지하는 요구를 표현하지 못한다. 본 이슈의 `FORCE_INLINE` 은 새 디스크 배치를 결정할 때 해당 컬럼 값을 OOS inline stub으로 바꾸지 않는 정책을 의미한다.

고정 길이 컬럼은 원래 OOS 분리 대상이 아니다. 따라서 이 타입의 기본 동작은 효과상 `FORCE_INLINE` 이지만, 선행 [CBRD-26979](https://jira.cubrid.org/browse/CBRD-26979)는 적용할 수 없는 정책이 스키마에 남는 문제를 막기 위해 `DEFAULT` 를 포함한 명시적 `STORAGE` 옵션을 모두 거부했다. 이로 인해 타입 기본값을 명시하는 중립적인 요청과 OOS 배치 방향을 지정하는 요청이 같은 방식으로 거부된다.

선행 [PR #7611](https://github.com/CUBRID/cubrid/pull/7611)은 2026-08-21에 `feat/oos` 로 병합되었다. 해당 PR의 최종 head는 `bc8a895d0a0a52b41ca27bfc3d4df0222af8519b` 이다. 본 문서는 이 선행 변경과 후속 요구의 경계를 기준으로 작성하며, 최신 배포 버전 전체에 대해 동작을 재현했다는 의미는 아니다.

| 항목 | 선행 변경에서 정리한 상태 | 본 이슈의 목표 |
|---|---|---|
| 고정 길이 일반 컬럼의 `STORAGE DEFAULT` | 다른 명시적 옵션과 함께 거부한다. | 타입 기본값으로 복귀하는 요청으로 허용한다. |
| 가변 길이 컬럼의 inline 유지 | `PREFER_INLINE` 으로 선호도만 지정한다. | `FORCE_INLINE` 으로 OOS 분리를 금지할 수 있게 한다. |
| 고정 길이 컬럼의 기본 정책 | OOS 비대상이라는 타입 특성으로 결정한다. | 효과상 `FORCE_INLINE` 이라고 설명하되 별도 정책으로 중복 저장하지 않는다. |

### 왜 문제인가

DDL 작성자나 스키마 관리 도구가 컬럼의 저장 정책을 기본값으로 되돌리려면 `STORAGE DEFAULT` 를 사용할 수 있어야 한다. 고정 길이 컬럼에서 이 요청까지 실패하면, 기본값을 지정하는 작업에도 타입별 예외 처리가 필요하다. `STORAGE` 절을 생략하는 우회 방법은 있지만, CREATE에서 기본값을 적용하는 것과 ALTER에서 기존 정책을 해제하는 요청을 명시하는 것을 동일하게 표현하지 못한다. 이는 가능한 사용 시나리오에 대한 영향이며, 특정 고객 도구에서 장애가 발생했다는 보고는 확인되지 않았다.

또한 사용자가 특정 가변 길이 컬럼을 행 내부 표현으로 유지하려 해도 현재의 `PREFER_INLINE` 만으로는 그 의도를 보장할 수 없다. 행 크기나 함께 저장하는 다른 컬럼 값이 달라지면 해당 컬럼도 OOS로 분리될 수 있다. 따라서 저장 위치를 제어해야 하는 요구를 스키마에 명시할 수 없고, 실제 배치가 사용자의 정책 의도와 달라질 수 있다. 이에 따른 추가 읽기 비용이나 성능 차이는 워크로드에 따라 달라지므로 수치로 단정하지 않는다.

반대로 `FORCE_INLINE` 을 단순히 “데이터를 언제나 heap의 원래 페이지에 둔다”라고 설명하면 기존 overflow 저장과 충돌한다. 컬럼 단위 OOS 분리와 전체 행 단위 overflow를 구분하지 않으면 사용자는 허용되는 큰 행을 오류로 오해하거나, 지원하지 않는 OOS와 overflow의 혼합 저장을 기대할 수 있다.

### 왜 해결해야 하는가

본 이슈를 미루면 타입 기본값으로 되돌리는 요청의 예외와 강한 inline 정책의 부재가 계속 남는다. 기본값 지정은 타입별 분기로 우회할 수 있지만, `PREFER_INLINE` 은 선호 정책이므로 OOS 분리 금지의 대체 수단이 되지 못한다.

두 요구를 함께 정리하면 타입 자체의 저장 능력과 사용자가 지정하는 배치 정책을 분리할 수 있다. 고정 길이 컬럼에는 불필요한 정책 정보를 남기지 않으면서, 가변 길이 컬럼에는 명시적인 OOS 분리 금지 정책을 제공하는 것이 필요한 결과다.

두 요구는 [선행 리뷰 의견](https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5290874468)과 [후속 이슈 분리 답변](https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5325413832)에 이미 기록되어 있다. 이를 근거로 분석 착수를 요청하며, 현재 자료만으로 긴급성이나 우선순위 상향을 주장하지 않는다.

## Specification Changes

다음은 원문과 선행 검토를 구체화한 목표 동작이다. `FORCE_INLINE` 이 이미 구현되었거나 기존 OOS 명세에 반영되었다는 의미는 아니다. 세부 문법, 정책 전환과 기존 데이터에 대한 적용 시점은 ANALYSIS에서 확정한다.

### 타입과 속성 종류별 허용 범위

일반 CLASS의 행별 일반 속성(normal attribute)을 대상으로 한다. 고정/가변 여부는 SQL 타입 이름의 인상이 아니라 실제 저장 표현의 분류로 판단한다. 예를 들어 선행 검토에서 `INT` 와 `BIT(n)` 은 fixed layout, `CHAR` 와 `BIT VARYING` 은 variable layout으로 구분한다.

| 명시한 정책 | 고정 길이 일반 컬럼 | 가변 길이 일반 컬럼 |
|---|---|---|
| `DEFAULT` | 허용한다. 타입 기본값을 적용하며 별도 OOS 정책을 남기지 않는다. | 허용한다. 명시적인 정책을 해제하고 타입 기본값을 적용한다. |
| `FORCE_INLINE` | 허용한다. 타입의 내재된 기본 동작과 같으며 별도 정책을 남기지 않는다. | 허용한다. OOS 분리를 금지하는 명시적 정책으로 보존한다. |
| `PREFER_INLINE` | 계속 거부한다. | 기존 선호 정책을 유지한다. |
| `PREFER_OUTLINE` | 계속 거부한다. | 기존 동작을 유지한다. |
| `FORCE_OUTLINE` | 계속 거부한다. | 기존 동작을 유지한다. |

이 예외는 고정 길이 일반 컬럼의 허용 정책만 확장한다. CLASS 속성, SHARED 속성 및 VCLASS 속성은 행별 OOS 정책 대상이 아니므로 명시적 `STORAGE` 옵션을 계속 거부한다.

### 정책 저장과 DDL 출력

고정 길이 컬럼의 OOS 비대상 특성은 타입으로부터 결정한다. `DEFAULT` 또는 `FORCE_INLINE` 을 명시했더라도 이를 별도 정책 flag로 저장하거나 `SHOW CREATE TABLE` 에 자동 출력하지 않는다.

가변 길이 컬럼의 명시적 `FORCE_INLINE` 은 기본 동작을 바꾸는 정책이므로 스키마에 보존하고 DDL로 출력해야 한다. 출력한 DDL로 다시 생성했을 때에도 같은 OOS 분리 금지 의도가 유지되어야 한다.

이 구분은 타입 변경에도 중요하다. 고정 길이 컬럼에 저장할 필요가 없던 정책이 나중에 가변 길이로 바뀌면서 의도하지 않은 강제 정책으로 살아나지 않아야 한다. 선행 검토는 `STORAGE` 생략 시 호환되는 가변→가변 변경에서는 기존 정책을 보존하고, 가변→고정 변경에서는 정책을 정리하며, 고정→가변 변경에서는 새 타입 기본값을 적용하는 방향을 제안했다. 타입 변환이 가능한 경우를 전제로 ANALYSIS에서 전환 규칙을 확정한다.

### OOS와 전체 행 overflow의 경계

`FORCE_INLINE` 은 해당 컬럼 값의 OOS 분리를 금지한다. 전체 행이 커서 기존 `REC_BIGONE` 경로로 저장되는 것까지 금지하지 않는다. 다음 경계는 기존 [OOS 명세의 OOS + bigone 규칙](https://github.com/vimkim/cubrid-oos-context/blob/3462a7f69a7ec0de8a0b97ad8da32b463ecf0e8c/OOS-CONTEXT.md#oos--bigone-rejection-cbrd-26937)과 함께 유지해야 한다.

| 저장 상황 | 필요한 결과 |
|---|---|
| OOS inline stub이 없는 행이 최대 slotted-record 크기를 초과한다. | 기존 non-OOS `REC_BIGONE` 저장을 허용한다. |
| 다른 컬럼이 OOS로 분리되었지만 남은 행이 최대 slotted-record 크기 이내다. | `FORCE_INLINE` 컬럼을 분리하지 않은 채 저장할 수 있다. OOS inline target을 초과했다는 이유만으로 실패시키지 않는다. |
| 다른 컬럼이 OOS로 분리된 후에도 남은 행이 `REC_BIGONE` 을 필요로 한다. | 기존 OOS+bigone 금지 규칙에 따라 실패한다. `FORCE_INLINE` 을 무시해 OOS로 보내는 우회 동작을 두지 않는다. |

마지막 경우의 오류는 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 이며, 기존 명세와 같이 새 OOS value chain을 쓰기 전에 판단해야 한다. 오류가 발생한 쓰기 작업은 데이터와 정책을 일부만 변경하거나 회수되지 않는 새 chain을 남기지 않아야 한다.

### 사용자 관점의 SQL 예시

다음은 구현 후 확인할 목표 시나리오이며 이번 작성에서 실행하지 않았다. `FORCE_INLINE` 은 추가 대상 문법이다.

```sql
-- 고정 길이 컬럼에서도 타입 기본값을 명시할 수 있어야 한다.
CREATE TABLE t_fixed_default (c INT STORAGE DEFAULT);

-- 고정 길이 컬럼의 내재된 동작을 명시한다.
CREATE TABLE t_fixed_inline (c INT STORAGE FORCE_INLINE);

-- 가변 길이 컬럼의 OOS 분리 금지 의도를 보존한다.
CREATE TABLE t_variable_inline (c VARCHAR(4096) STORAGE FORCE_INLINE);
SHOW CREATE TABLE t_variable_inline;

-- 명시한 강제 정책을 해제하고 타입 기본값으로 되돌린다.
ALTER TABLE t_variable_inline MODIFY c VARCHAR(4096) STORAGE DEFAULT;
```

고정 길이 두 테이블의 canonical DDL에는 불필요한 OOS 정책 절이 없어야 한다. 가변 길이 테이블은 정책 해제 전 출력에 `FORCE_INLINE` 을 보존하고, 해제 후에는 해당 강제 정책이 남지 않아야 한다. 고정 길이 컬럼의 `PREFER_INLINE`, `PREFER_OUTLINE`, `FORCE_OUTLINE` 은 계속 실패해야 한다.

### PostgreSQL 비교의 의미와 한계

원문에 인용된 검토는 PostgreSQL 18.6에서 `integer` 의 `STORAGE DEFAULT` 가 타입 기본값인 `PLAIN` 으로 해석되어 허용된다고 보고한다. [PostgreSQL 18 공식 문서](https://www.postgresql.org/docs/18/sql-altertable.html#SQL-ALTERTABLE-DESC-SET-STORAGE)도 `DEFAULT` 를 타입 기본 저장 방식으로 되돌리는 요청으로 설명한다. 이번 작성에서는 공식 문서를 확인했으며 PostgreSQL 실행을 반복하지 않았다.

이 비교는 고정 타입에서도 중립적인 기본값 복귀를 허용하는 근거다. PostgreSQL의 압축 및 TOAST 정책을 CUBRID에 그대로 도입하는 요구는 아니다. PostgreSQL은 [전체 tuple이 여러 페이지에 걸치는 저장을 허용하지 않으므로](https://www.postgresql.org/docs/18/storage-toast.html), CUBRID의 non-OOS `REC_BIGONE` 허용 여부를 PostgreSQL `PLAIN` 과 동일하게 해석해서는 안 된다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

분석에서는 다음을 확인한다.

- `DEFAULT` 와 `PREFER_OUTLINE` 을 구분하여 고정 길이 컬럼의 허용 여부를 판단할 수 있는지, `FORCE_INLINE` 추가가 parser와 의미 검사에 미치는 영향은 무엇인지 확인한다. 구체적인 enum 값과 비트 수는 구현 결정으로 남긴다.
- CREATE, ADD, MODIFY, CHANGE에서 같은 정책을 적용하고, 정책 전환 시 상충하는 설정이 남지 않도록 스키마 저장과 DDL 출력의 계약을 정한다.
- 새로 기록하는 값의 OOS 후보 선정에서 `FORCE_INLINE` 을 지키고, 다른 컬럼의 기존 정책 및 OOS+bigone 검사를 유지하는 방법을 정한다.
- ALTER 이전에 이미 OOS로 저장한 값을 즉시 재배치할지, 이후 어떤 쓰기에서 새 정책을 적용할지 결정한다. 특히 UPDATE에서 미변경 컬럼의 기존 chain을 재사용하는 정책과의 관계를 명확히 한다.
- 새 정책의 recovery, replication, `CREATE TABLE LIKE`, unload/load 전달 경로를 확인하고, 적용 버전 및 필요한 호환성 검증 범위를 정한다.

기존 행 전체를 재작성하는 기능이나 OOS+bigone 혼합 저장 지원을 본문만으로 추가 요구로 확정하지 않는다. `FORCE_INLINE` 을 제공하는 데 필요한 변경과 별도 후속 과제를 분석 결과에서 구분한다.

## Acceptance Criteria

1. 고정 길이 일반 컬럼의 `STORAGE DEFAULT` 와 `STORAGE FORCE_INLINE` 이 CREATE 및 해당 ALTER 경로에서 허용되고, 방향성 세 옵션의 거부와 CLASS/SHARED/VCLASS 제한은 유지된다.
2. 가변 길이 컬럼의 명시적 `FORCE_INLINE` 이 스키마와 DDL 재생성에서 보존되며, 새 정책으로 배치를 결정하는 값은 OOS로 분리되지 않는다.
3. `STORAGE DEFAULT` 로 명시적 정책을 해제할 수 있고, 고정 길이 컬럼에는 별도 OOS 정책 flag나 불필요한 출력이 남지 않는다.
4. 타입 및 정책 전환이 ANALYSIS에서 정한 규칙과 일치하며, 실패한 ALTER는 기존 스키마와 데이터를 보존한다.
5. non-OOS `REC_BIGONE` 은 계속 허용하고 OOS+bigone은 계속 거부한다. 실패를 피하려고 `FORCE_INLINE` 을 무시하지 않으며, 거부된 쓰기에서 새 OOS chain이 남지 않는다.
6. 기존 `PREFER_INLINE`, `PREFER_OUTLINE`, `FORCE_OUTLINE` 동작이 유지된다. 기존 행과 UPDATE 재사용에 대한 정책 적용 시점은 문서와 검증 결과가 일치한다.
7. ANALYSIS에서 확정한 recovery, replication 및 스키마 전달 경로에서 정책과 값이 올바르게 보존된다.

## Definition of done

- 타입별 허용 범위, 기본값과 명시적 정책의 차이, ALTER 적용 시점 및 overflow 경계를 ANALYSIS 산출물로 확정한다.
- 확정한 명세를 구현하고 parser/schema 단위 테스트와 실제 저장 배치 검증으로 위 수락 기준을 확인한다. DML 성공 여부와 값 조회만으로 OOS 비분리를 증명했다고 판단하지 않는다.
- 정책 전환, DDL 재생성, 큰 행의 성공/실패 경계와 실패 원자성에 대한 회귀 근거를 남긴다. 분석에서 선정한 recovery/replication 및 unload/load 검증도 완료한다.
- 사용자 문서에 `PREFER_INLINE` 과 `FORCE_INLINE` 의 차이, 고정 타입의 기본값, `REC_BIGONE` 경계와 기존 데이터 적용 시점을 설명한다.

## Triage Request

상위 [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 후속 Sub-task로 본 문제를 확인하고, 작성자 측에 ANALYSIS 배정을 요청한다. 기술적 성격은 저장 정책 기능 확장과 DDL 의미 명확화다.

CBRD-26979에서 완료한 적격성 검사 통일을 다시 결함으로 분류하지 않고, 분리된 `DEFAULT` 예외와 `FORCE_INLINE` 지원을 분석 범위로 삼는다. 우선 기존 데이터에 대한 적용 시점과 타입 변경 시 정책 전환을 확정하고, 실제 사용자 수요와 영향 범위를 확인해 우선순위를 판단한다.

## Additional Information

- 대상 이슈: [CBRD-27259](https://jira.cubrid.org/browse/CBRD-27259). 2026-10-27 조회 기준 Open, Minor, Sub-task이며 담당자는 미배정이다.
- 선행 이슈와 구현: [CBRD-26979](https://jira.cubrid.org/browse/CBRD-26979), [PR #7611](https://github.com/CUBRID/cubrid/pull/7611). 후속 범위의 기준은 최종 head `bc8a895d0a0a52b41ca27bfc3d4df0222af8519b` 이다.
- 요구의 출처: [고정 타입의 DEFAULT와 FORCE_INLINE 검토](https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5290874468), [CBRD-27259에서 처리한다는 답변](https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5325413832).
- 상세 설계 검토: [CBRD-26979 STORAGE 타입 검사와 후속 계약 제안](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26979/CBRD-26979-storage-variable-type-validation_882f70f_codex.md). 구현 후보와 과거 실행 기록은 해당 문서의 검토 시점 근거이며 이번 작성의 실행 결과가 아니다.
- 기존 저장 제약의 기준: [OOS 명세](https://github.com/vimkim/cubrid-oos-context/blob/3462a7f69a7ec0de8a0b97ad8da32b463ecf0e8c/OOS-CONTEXT.md), 2026-10-27 문서 기준. 본문 작성 중 엔진 수정, 빌드 또는 DB 실행은 수행하지 않았다.
