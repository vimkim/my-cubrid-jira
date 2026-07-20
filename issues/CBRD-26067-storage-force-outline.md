# [OOS] STORAGE FORCE_OUTLINE 지원

## Issue Triage

**이슈 수행 목적**: 컬럼에 `STORAGE FORCE_OUTLINE` 을 지정하면 해당 가변 타입의 값을 레코드 크기와 값 크기에 관계없이 OOS로 저장하도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 일반 가변 값은 heap 레코드가 `heap_oos_inline_target_size()`(현재 16KB layout에서 4,060B, 한 페이지에 레코드 네 개가 들어가는 물리 용량 기준)를 넘고 값 크기가 `OR_OOS_INLINE_SIZE`(16B)보다 클 때만 OOS demotion 후보가 된다. 16B 이하는 inline stub으로 바꿔도 레코드가 줄지 않아 제외한다. `PREFER_INLINE` 은 후보 순서만 늦추며, 현재 `PREFER_OUTLINE` 은 `DEFAULT` 와 같은 정책이라 OOS 저장을 강제하지 않는다. |
| **TO-BE (목표 상태 / 기대 동작)** | `FORCE_OUTLINE` 이 지정된 가변 컬럼의 non-NULL 값은 일반 OOS trigger와 16B 수익성 조건을 건너뛰고 항상 OOS-backed attribute로 기록된다. |
| **영향** | 설계 의도 훼손 — 예를 들어 3KB `VARCHAR` 하나를 가진 레코드가 OOS inline target 이하이면 현재는 값이 heap에 남으므로, payload를 읽지 않는 조회도 해당 3KB를 heap I/O에 포함한다. 사용자가 이 컬럼의 heap 외부 저장을 보장할 방법이 없다. |

**이슈 수행 방안**:

- `CREATE TABLE` 과 `ALTER TABLE ... MODIFY/CHANGE` 의 컬럼 옵션으로 `STORAGE FORCE_OUTLINE` 을 추가한다. 가변 타입에만 허용한다. (사용자 인용: "FORCE_OUTLINE", "which sends the value to OOS no matter what (of course, if it is variable type).")
- PR #7334(CBRD-26912)의 파서 → 스키마 플래그 → 서버 attribute 표현 → heap layout → `SHOW CREATE TABLE`/unloaddb/`CREATE TABLE ... LIKE` 전달 경로를 확장한다.
- ALTER는 schema flag만 변경한다. 이미 저장된 행을 즉시 재배치하지 않으며, 이후 INSERT/UPDATE로 다시 기록되는 값부터 `FORCE_OUTLINE` 을 적용한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 파서와 lexer, schema attribute flag, server-side `OR_ATTRIBUTE`, heap OOS layout, DDL 출력·덤프·복제 경로, OOS SQL/heap 단위 테스트가 영향받는다.
- **호환성**: 기존 `DEFAULT`, `PREFER_OUTLINE`, `PREFER_INLINE` 컬럼과 저장 데이터는 새 플래그가 없으므로 기존 정책을 유지한다. 카탈로그의 `SM_ATTRIBUTE.flags` 정수에 비트를 추가하는 방식이면 attribute 디스크 포맷 자체를 늘리지 않는다.

## Description

OOS(Out-of-row Storage)는 heap의 가변 컬럼 값을 별도 OOS 파일로 분리하고, heap 레코드에는 16바이트 OOS inline stub만 두는 저장 방식이다. 현재 `heap_attrinfo_determine_disk_layout()` 은 레코드가 기준 크기를 넘을 때 수익성 있는 가변 값만 골라 큰 값부터 demote한다. 여기서 demotion은 인라인 값을 OOS value chain으로 옮기는 write-time 동작이다.

PR #7334는 `STORAGE PREFER_INLINE` 을 추가하면서 컬럼별 storage 정책이 SQL에서 heap까지 전달되는 경로를 마련했다. `PREFER_INLINE` 컬럼도 후보에서 빠지지는 않고 마지막 순서로 밀릴 뿐이다. 함께 추가된 `PREFER_OUTLINE` 은 현재 타입별 기본 정책을 명시하는 이름으로, parser enum에서 `DEFAULT` 와 같은 값이다.

`FORCE_OUTLINE` 은 우선순위 힌트가 아니라 강제 배치 정책이다. 해당 컬럼의 값은 행 전체가 작아 일반 demotion이 시작되지 않는 경우에도 OOS로 가야 한다. 또한 16바이트 이하 값을 OOS로 보내면 heap 레코드가 줄지 않거나 오히려 커지지만, 공간 수익성보다 사용자가 지정한 배치 정책을 우선한다.

NULL은 저장할 payload가 없고 OOS chain도 만들지 않는다. 현재 `oos_insert()` 는 길이 0 입력을 `ER_HEAP_OOS_INVALID_ARGUMENT` 로 거부하며, variable attribute의 NULL은 offset만으로 표현된다. 따라서 `FORCE_OUTLINE` 은 non-NULL 값에 적용하고 NULL은 기존 NULL 표현을 유지하는 것이 코드 불변식과 맞는다.

현재 체크아웃한 `feat/oos` 의 `heap_attrinfo_determine_disk_layout()` 은 raw `DB_PAGESIZE/4` gate를 사용한다. OOS 규범 문서와 CBRD-27057은 이를 `heap_oos_inline_target_size()` 가 계산하는 four-record physical-capacity target으로 교체한다. `FORCE_OUTLINE` 은 특정 수치에 종속되지 않고 정상 정책의 record gate 자체를 우회해야 하므로, 어느 target이 적용된 revision에서도 의미가 같다.

## Specification Changes

### SQL 구문

```sql
CREATE TABLE t_force_outline (
  id       INT,
  payload  VARCHAR(4096) STORAGE FORCE_OUTLINE,
  hot_text VARCHAR(4096) STORAGE PREFER_INLINE,
  normal   VARCHAR(4096) STORAGE PREFER_OUTLINE
);

ALTER TABLE t_force_outline
  MODIFY payload VARCHAR(4096) STORAGE FORCE_OUTLINE;

ALTER TABLE t_force_outline
  MODIFY payload VARCHAR(4096) STORAGE DEFAULT;
```

`FORCE_OUTLINE` 은 기존 `STORAGE` 절에 추가하는 non-reserved keyword다. `storage` 와 `force_outline` 을 식별자로 사용하던 스키마가 깨지지 않도록 `identifier` echo 규칙도 함께 추가한다.

### 정책 비교

| 옵션 | 일반 record gate 적용 | 16B 수익성 조건 적용 | OOS 배치 |
|------|-----------------------|----------------------|----------|
| 생략 / `DEFAULT` / `PREFER_OUTLINE` | 적용 | 적용 | 큰 후보부터 필요한 만큼 demote |
| `PREFER_INLINE` | 적용 | 적용 | 다른 후보 뒤에 마지막으로 demote |
| `FORCE_OUTLINE` | 미적용 | 미적용 | non-NULL 가변 값을 항상 OOS에 저장 |

`FORCE_OUTLINE` 은 `PREFER_OUTLINE` 과 다른 상태다. 전자는 hard policy이고 후자는 현재 기본 demotion 정책의 명시적 이름이다.

### 적용 대상과 오류

`pr_is_variable_type()` 이 true인 일반 instance attribute에만 허용한다. 고정 타입, CLASS/SHARED attribute, heap 저장이 없는 VCLASS attribute에 지정하면 DDL을 거부한다. 타입별 허용 목록을 따로 만들지 않고 CBRD-26912가 사용하는 가변 타입 판정과 같은 기준을 사용한다.

값별 동작은 다음과 같다.

| 값 상태 | 동작 |
|---------|------|
| non-NULL, 직렬화 크기 > 16B | record 크기와 관계없이 OOS 저장 |
| non-NULL, 직렬화 크기 ≤ 16B | heap 절감 효과가 없어도 OOS 저장 |
| NULL | OOS chain을 만들지 않고 NULL 유지 |

### ALTER와 스키마 round-trip

`ALTER ... MODIFY/CHANGE` 에서 `STORAGE` 절을 생략하면 기존 정책을 보존한다. 명시한 옵션은 다음 상태 전이로 처리한다.

| 명시 옵션 | 변경 후 상태 |
|-----------|--------------|
| `DEFAULT` 또는 `PREFER_OUTLINE` | prefer/force flag를 모두 해제 |
| `PREFER_INLINE` | prefer flag만 설정 |
| `FORCE_OUTLINE` | force flag만 설정 |

`SHOW CREATE TABLE`, `cubrid unloaddb`, `CREATE TABLE ... LIKE` 는 `FORCE_OUTLINE` 을 보존해야 한다. DEFAULT와 PREFER_OUTLINE은 현재와 같이 별도 flag가 없으므로 출력하지 않아도 의미가 보존된다.

ALTER 자체는 table rewrite를 수행하지 않는다. 기존 행은 물리 배치를 유지하고, 이후 해당 행이 UPDATE되어 다시 기록될 때 새 정책을 따른다.

## Implementation

### 전달 경로

```
[SQL] STORAGE FORCE_OUTLINE
  └ csql_lexer.l / csql_grammar.y
      └ PT_ATTR_STORAGE_SETTING::PT_ATTR_STORAGE_FORCE_OUTLINE
          └ execute_schema.c
              └ SM_ATTFLAG_OOS_FORCE_OUTLINE
                  ├ object_printer.cpp / unload_schema.c / class_object.c
                  │   └ DDL 출력, dump/load, CREATE TABLE LIKE 보존
                  └ object_representation_sr.c
                      └ OR_ATTRIBUTE::is_oos_force_outline
                          └ heap_attrinfo_determine_disk_layout()
                              ★ 일반 record gate와 16B 수익성 gate보다 먼저 강제 OOS 표시
```

### 파서와 스키마 상태

현재 `PT_ATTR_STORAGE_SETTING` 의 2비트 값은 `UNSET`, `DEFAULT/PREFER_OUTLINE`, `PREFER_INLINE` 세 상태를 사용한다. 남은 값 하나를 `PT_ATTR_STORAGE_FORCE_OUTLINE` 에 배정할 수 있다.

영속 상태는 기존 `SM_ATTFLAG_OOS_PREFER_INLINE` 과 별개인 `SM_ATTFLAG_OOS_FORCE_OUTLINE` 비트를 추가한다. 두 비트는 상호 배타적이어야 한다. CREATE와 ALTER change-map은 한 옵션을 설정할 때 반대편 비트를 제거하고, 절 생략 시 두 비트를 모두 보존한다.

### heap 배치

강제 정책과 정상 demotion을 두 단계로 나누면 의미가 분명하다.

```
heap_attrinfo_determine_disk_layout()
  ├ [1] payload/header 크기 계산
  ├ [2] FORCE_OUTLINE 선처리
  │    └ 가변 + non-NULL 값을 oos_columns[i] = true로 표시
  │         payload_size -= column_size[i]
  │         payload_size += OR_OOS_INLINE_SIZE
  └ [3] 결과 레코드가 normal OOS target을 넘는 경우
       └ 나머지 수익성 후보를 DEFAULT/PREFER_INLINE 우선순위로 demote
```

강제된 컬럼은 normal 후보 목록에서 제외해 중복 처리하지 않는다. 짧은 값을 16바이트 stub으로 바꾸면서 레코드가 커질 수 있으므로, FORCE_OUTLINE 선처리 후의 payload를 기준으로 header offset 크기와 normal demotion 필요 여부를 다시 계산해야 한다.

`heap_attrinfo_insert_to_oos()` 와 OOS inline stub 기록 경로는 기존 `oos_columns` 결과를 소비하므로 그대로 재사용한다. OOS가 포함된 레코드에 대한 `REC_BIGONE` 거부, WAL, replication, vacuum, read/resolve 경로도 기존 OOS-backed attribute와 동일한 불변식을 따른다.

### PR #7334에서 재사용할 변경 지점

| 역할 | 파일 |
|------|------|
| token/grammar/parse state | `src/parser/csql_lexer.l`, `csql_grammar.y`, `keyword.c`, `parse_tree.h`, `parse_tree_cl.c` |
| CREATE/ALTER flag 상태 전이 | `src/query/execute_schema.c` |
| schema flag와 서버 attribute | `src/storage/storage_common.h`, `src/base/object_representation_sr.c`, `object_representation_sr.h` |
| heap 배치 결정 | `src/storage/heap_file.c`, `src/storage/heap_oos.hpp` |
| SHOW/LIKE/dump round-trip | `src/object/object_printer.cpp`, `class_object.c`, `src/compat/db_info.c`, `dbi.h`, `dbi_compat.h`, `src/executables/unload_schema.c` |
| 오류 메시지 | `src/parser/parser_message.h`, `msg/en_US.utf8/cubrid.msg`, `msg/ko_KR.utf8/cubrid.msg` |
| 테스트 | `unit_tests/oos/sql/test_oos_sql_storage.cpp` 및 heap layout 단위 테스트 |

## Acceptance Criteria

- [ ] `CREATE TABLE` 과 `ALTER TABLE ... MODIFY/CHANGE` 에서 `STORAGE FORCE_OUTLINE` 을 사용할 수 있다.
- [ ] 일반 OOS trigger 이하인 레코드의 FORCE_OUTLINE non-NULL 가변 값도 VOT의 `OR_VAR_BIT_OOS` 가 설정되고 OOS value chain에 저장된다.
- [ ] 직렬화 크기가 `OR_OOS_INLINE_SIZE`(16B) 이하인 FORCE_OUTLINE non-NULL 가변 값도 OOS에 저장되고 원래 값으로 읽힌다.
- [ ] FORCE_OUTLINE 컬럼의 NULL은 OOS chain을 만들지 않으며 NULL로 읽힌다.
- [ ] 고정 타입, CLASS/SHARED attribute, VCLASS attribute의 `STORAGE FORCE_OUTLINE` 은 명확한 오류로 거부된다.
- [ ] `SHOW CREATE TABLE`, unloaddb/loaddb, `CREATE TABLE ... LIKE` round-trip에서 FORCE_OUTLINE 정책이 보존된다.
- [ ] ALTER에서 STORAGE 절 생략, DEFAULT/PREFER_OUTLINE, PREFER_INLINE, FORCE_OUTLINE 간 상태 전이가 정의대로 동작한다.
- [ ] DEFAULT/PREFER_OUTLINE의 largest-first demotion과 PREFER_INLINE의 last-resort demotion 동작에 회귀가 없다.
- [ ] INSERT, UPDATE, DELETE, SELECT, index scan, vacuum, recovery, replication 경로에서 FORCE_OUTLINE 값의 무결성과 OOS 수명주기가 유지된다.
- [ ] ALTER 자체는 기존 행을 재배치하지 않으며, 이후 INSERT/UPDATE되는 값부터 FORCE_OUTLINE 배치가 적용된다.

## Definition of done

- [ ] 위 A/C를 모두 충족한다.
- [ ] OOS 단위 테스트와 관련 SQL/medium/shell QA를 통과한다.
- [ ] `CREATE TABLE`/`ALTER TABLE` STORAGE 구문과 옵션별 동작을 매뉴얼에 반영한다.
- [ ] CBRD-26912 및 PR #7334와의 정책 차이(`PREFER_OUTLINE` 대 `FORCE_OUTLINE`)를 PR 설명에 명시한다.

## Remarks

- 관련 이슈: [CBRD-26912](http://jira.cubrid.org/browse/CBRD-26912) `STORAGE PREFER_INLINE`
- 참고 구현: [CUBRID PR #7334](https://github.com/CUBRID/cubrid/pull/7334)
- OOS target 변경: CBRD-27057
- JIRA type은 `Sub-task` 이며, 기능 확장 성격에 맞춰 Improve Function/Performance 본문 구조를 사용했다.
