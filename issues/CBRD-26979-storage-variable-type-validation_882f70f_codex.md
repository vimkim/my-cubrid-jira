# [CBRD-26979] 고정 길이 컬럼의 OOS STORAGE 옵션 지정 거부

## Issue Triage

**이슈 수행 목적**: `OOS`(Out-of-row Overflow Storage — 큰 가변 컬럼 값을 heap 레코드 밖의 전용 파일에 저장하는 방식) `STORAGE` 옵션을 실제 OOS 저장 대상이 될 수 있는 클래스의 가변 타입 일반 속성에만 지정할 수 있도록 한다.

**이슈 수행 이유**:

| 구분 | 동작 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 고정 길이 `INT` 컬럼에도 `STORAGE PREFER_INLINE`, `PREFER_OUTLINE`, `DEFAULT` 가 허용된다. `FORCE_OUTLINE` 만 별도의 검사를 거쳐 실패한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 네 가지 명시적 `STORAGE` 옵션을 하나의 적격성 규칙으로 검사하고, 고정 타입이나 CLASS/SHARED/VCLASS 속성이면 semantic error를 반환한다. |
| **영향** | 설계 의도 훼손 — 지원되지 않는 문법이 조용히 성공하고, 특히 `INT STORAGE PREFER_INLINE` 의 무효 정책은 스키마와 `SHOW CREATE TABLE` 결과에도 남는다. |

**이슈 수행 방안**: 물리적 가변 타입인 실제 클래스의 일반 속성만 허용한다. 부적격 속성에 명시한 네 가지 옵션은 모두 거부하고, 기존 정책이 있는 컬럼을 `STORAGE` 절 없이 부적격 타입으로 바꾸는 ALTER는 성공시키되 기존 컬럼의 `PREFER_INLINE` 또는 `FORCE_OUTLINE` 정책을 조용히 제거한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 재현 결과를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 스키마 실행부의 속성 적격성 검사, 파서 의미 검사 메시지, 영문/국문 메시지 카탈로그, OOS SQL 단위 테스트가 대상이다. SQL 문법, parse-tree enum, schema 플래그 형식, heap 레코드 형식, 복구에는 변화가 없다.

## Description

OOS의 컬럼별 정책은 `STORAGE PREFER_INLINE`, `FORCE_OUTLINE`, `PREFER_OUTLINE`, `DEFAULT` 문법으로 지정한다. 네 문법은 모두 OOS 정책을 나타내지만 기존 스키마 경로는 옵션별로 검사를 나눠 처리했다.

`do_add_attribute()` 와 `build_attr_change_map()` 은 `FORCE_OUTLINE` 에 대해서만 일반 속성, 실제 클래스, 물리적 가변 타입 조건을 모두 검사했다. `PREFER_INLINE` 은 속성 종류(namespace)만 확인했고, 기본 정책을 뜻하는 `PREFER_OUTLINE` 과 `DEFAULT` 는 별도의 플래그를 남기지 않아 적격성 검사를 통과했다. 이 구조 때문에 같은 OOS 정책 문법인데도 옵션 표기에 따라 허용 범위가 달라졌다.

물리적 저장 분류는 SQL 타입 이름이 아니라 `pr_is_variable_type(TP_DOMAIN_TYPE(domain))` 으로 결정된다. 예를 들어 물리적으로 가변인 `CHAR` 는 허용할 수 있지만, 고정 배치인 `BIT(n)` 은 허용하면 안 된다.

```
[CREATE / ALTER]
  attr_storage와 새 타입의 내부 표현(domain) 해석
    └ validate_oos_storage_setting()
        ├ STORAGE 생략                    -> 적격성 검사 생략
        └ STORAGE 명시
            └ is_oos_storage_eligible_attribute()
                ├ 행 레코드의 일반 속성 (`ID_ATTRIBUTE`)
                ├ VCLASS가 아닌 일반 CLASS (`SM_CLASS_CT`)
                └ 디스크 표현이 가변 영역인 타입 (`pr_is_variable_type`)
                     ★ 하나라도 불충족 -> `ER_PT_SEMANTIC`
```

## Test Build

- 수정 전 재현: `feat/oos` `07fef9d48b4776e60c42e8afa25b9f21c54b8226`, Linux x86_64 debug build
- 수정 반영: `882f70f9699ef68ee1457e8554178920df9894e1`, Linux x86_64 debug build

## Repro

```sql
CREATE TABLE t_fixed_prefer_inline (c INT STORAGE PREFER_INLINE);
CREATE TABLE t_fixed_force_outline (c INT STORAGE FORCE_OUTLINE);
CREATE TABLE t_fixed_prefer_outline (c INT STORAGE PREFER_OUTLINE);
CREATE TABLE t_fixed_default (c INT STORAGE DEFAULT);

CREATE VCLASS v_storage (c VARCHAR(4096) STORAGE PREFER_INLINE);

-- 준비 문장: 성공해야 한다
CREATE TABLE t_alter (c INT);
ALTER TABLE t_alter MODIFY c INT STORAGE PREFER_INLINE;
```

## Expected Result

`STORAGE` 절을 포함한 여섯 문장은 모두 다음 의미의 semantic error로 실패해야 한다. 준비 문장인 `CREATE TABLE t_alter (c INT)` 는 성공해야 한다.

```text
STORAGE options can be set only on variable-type normal attributes of a class
```

## Actual Result

수정 전에는 `STORAGE` 절을 포함한 문장 중 `FORCE_OUTLINE` 만 실패한다. 나머지 고정 타입 CREATE/ALTER와 VCLASS의 `PREFER_INLINE` 은 성공하며, `PREFER_INLINE` 정책은 `SHOW CREATE TABLE` 결과에 남는다.

## Additional Information

- 상위 이슈: https://jira.cubrid.org/browse/CBRD-26583
- 구현 commit: `882f70f9699ef68ee1457e8554178920df9894e1`
- 핵심 코드: `src/query/execute_schema.c` 의 `validate_oos_storage_setting()`, `is_oos_storage_eligible_attribute()`, `build_attr_change_map()`
- 검증: 수정 전 확장 테스트 6건이 실패해 결함을 재현했다. 수정 후 OOS STORAGE 대상 SQL 테스트 21건과 구성된 전체 테스트 25건이 통과했다.
