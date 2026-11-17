# [OOS] 고정 길이 부분만으로 한 페이지를 넘는 테이블을 DDL 시점에 거부

**한 줄 요약**: PR #8416(CBRD-27259) 리뷰에서 "CREATE·ALTER가 고정 길이 컬럼만으로 한 페이지를 넘는 테이블을 받아 주어 DDL은 성공하고 모든 쓰기가 실패한다"는 지적([discussion_r4536816663](https://github.com/CUBRID/cubrid/pull/8416#discussion_r4536816663))에 대응하여, 이런 스키마를 DDL 시점에 거부하는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: 고정 길이 부분만으로 행 크기 한도를 넘는 사용자 테이블을 CREATE TABLE과 ALTER 같은 DDL 시점에 거부한다. 사용자가 행을 하나도 쓸 수 없는 테이블을 만들거나, 기존 행을 더 이상 수정할 수 없게 만드는 일을 막는다.

**이슈 수행 이유**: CBRD-27259(PR #8416)부터 사용자 테이블 행이 한 페이지에 들어가지 않아 `REC_BIGONE` (여러 페이지에 걸친 레코드)이 필요하면 OOS 값이 없어도 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` (-1396)로 거부된다. 고정 길이 컬럼은 OOS로 옮길 수 없고 값이 NULL이어도 행 안에서 자리를 차지한다. 그래서 고정 길이 부분이 한도를 넘는 테이블에는 어떤 행도 쓸 수 없다. 그런데 DDL에는 이 판단이 없다. PR #8416 head(`89496263e`)에서 다음 DDL이 모두 성공하고, 그 뒤 쓰기는 모두 실패함을 확인했다.

- `CREATE TABLE`
- `ALTER TABLE ... ADD COLUMN`, `ALTER TABLE ... MODIFY` (빈 테이블)
- `CREATE TABLE ... UNDER`
- `CREATE TABLE ... LIKE`

**영향**: 사용자는 DDL이 성공했으므로 테이블을 쓸 수 있다고 생각하지만, 이후 INSERT와 UPDATE가 모두 실패한다. 행이 있는 테이블에 고정 길이 컬럼을 추가하면 기존 행의 무관한 UPDATE(조회수 증가, 새 컬럼을 NULL로 바꾸기 포함)까지 실패하고, 읽기와 DELETE만 된다. 컬럼을 다시 DROP해야 풀린다. 이 DB를 `unloaddb` 한 파일을 `loaddb` 하면 해당 테이블의 행이 하나도 실리지 않는다(리뷰어 보고, 직접 실행하지 않음). 대상은 사용자 타입 중 큰 고정 길이 타입, 사실상 `BIT(n)` 이나 수천 개의 고정 길이 컬럼을 쓰는 스키마로 좁다. 실제 발생 빈도는 알 수 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경

- PR #8416 이전 OOS 브랜치에서는 거부 조건이 `has_oos && heap_is_big_length` 였다. OOS 값이 없는 큰 행은 `REC_BIGONE` 으로 저장됐다.
- PR #8416은 이 조건을 비시스템 클래스 전체로 넓혔다(`src/storage/heap_file.c:14866-14867`, 쓰기 시점 행 배치 함수 `heap_attrinfo_transform_to_disk_internal`). 행이 한 페이지를 넘으면 거부한다는 규칙 자체는 리뷰어도 동의했다.
- 같은 스키마와 쓰기를 PR 이전 OOS 브랜치 빌드(`17a58ab`)에서 돌리면 모두 성공한다. 이 빌드는 PR의 정확한 base보다 오래됐다. 따라서 이 틈은 PR #8416이 만든 것으로 판단한다.
- DDL 쪽(`src/object/schema_manager.c`, `schema_template.c`, `class_object.c`, `src/query/execute_schema.c`, `src/parser/semantic_check.c`)에는 행 크기 검사가 없다. 옛 `ER_HEAP_OVERPASS_MAXOBJ_SIZE` (-54)는 정의만 있고 사용처가 없다.

### Repro

PR #8416 head `89496263e` (`11.5.0.2929-8949626`, debug 빌드), `csql -S` (SA 모드)에서 실행했다. 페이지 크기는 기본값 16KB이고 한도 `heap_Maxslotted_reclength` 는 16236바이트다.

```sql
-- 예 1: 처음부터 행을 하나도 넣을 수 없는 테이블
create table big_fixed (id int, image bit(136000));        -- 성공 (image 17000바이트)
insert into big_fixed values (1, B'1');                     -- -1396, 17040 bytes
insert into big_fixed (id) values (2);                      -- -1396, 17040 bytes (image NULL)

-- 예 2: 데이터가 있는 테이블에 고정 길이 컬럼 추가
create table photo (id int, view_count int, image bit(120000));
insert into photo values (1, 0, CAST(REPEAT('AA', 15000) AS BIT(120000)));   -- 성공
alter table photo add column thumbnail bit(16000);                          -- 성공
update photo set view_count = view_count + 1 where id = 1;                  -- -1396, 17044 bytes
update photo set thumbnail = NULL where id = 1;                             -- -1396, 17044 bytes
insert into photo (id) values (2);                                          -- -1396, 17044 bytes
```

리뷰어가 언급하지 않은 경로도 같은 결과다.

| 문장 | 결과 |
| --- | --- |
| 빈 테이블 `m2 (id int, b bit(8))` 에 `alter table m2 modify b bit(136000)` | 성공. 이후 쓰기는 모두 실패할 스키마 |
| 행이 있는 테이블에 같은 MODIFY | -1396로 실패, 기존 행 유지 |
| `create table c1 under p1 (c bit(60000))`, `p1` 은 `bit(80000)` | 성공. `insert into c1` 은 -1396, 17540 bytes |
| `create table l1 like big_fixed` | 성공. INSERT는 -1396 |
| `bigint` 컬럼 2100개 테이블 | 성공. INSERT는 -1396, 17096 bytes |
| `bit(128000)` + `varchar(100)` | INSERT 성공. 하한 이하는 정상 |
| 경계 `id int, b bit(129600)` | INSERT는 -1396, 16240 bytes |

### 스키마만으로 정해지는 최소 행 크기

고정 길이 컬럼은 NULL이어도 `tp_domain_disk_size` 만큼 자리를 차지한다(`heap_attrinfo_get_record_payload_size`). 그래서 최소 행 크기는 스키마만으로 정해진다. 측정한 오류 크기는 모두 다음 식과 정확히 일치했다. 가변 컬럼이 없는 사용자(MVCC) 클래스 기준이다.

`최소 행 크기 = OR_MVCC_MAX_HEADER_SIZE (32) + OR_BOUND_BIT_BYTES (고정 컬럼 수) + Σ tp_domain_disk_size (고정 컬럼)`

| 테이블 | 식 | 측정 |
| --- | --- | --- |
| `big_fixed` | 32 + 4 + (4 + 17000) | 17040 |
| `photo` (ALTER 후) | 32 + 4 + (4 + 4 + 15000 + 2000) | 17044 |
| `bit(129600)` | 32 + 4 + (4 + 16200) | 16240 |
| `bigint` × 2100 | 32 + 264 + 16800 | 17096 |

가변 컬럼이 있으면 가변 값이 모두 NULL인 행이 하한이다. 이때 가변 오프셋 테이블 `OR_VAR_TABLE_SIZE_INTERNAL (n_variable, 2)` 가 더해진다. 가변 컬럼의 선언 크기는 더하지 않는다. 더하면 `VARCHAR(20000) STORAGE FORCE_INLINE` 처럼 값에 따라 들어갈 수 있는 스키마까지 막는다.

### Acceptance Criteria

- 고정 길이 부분의 최소 행 크기가 한도를 넘는 사용자 테이블을 만드는 `CREATE TABLE`, `ALTER ... ADD/MODIFY/CHANGE`, `CREATE TABLE ... UNDER`, `CREATE TABLE ... LIKE` 가 DDL 시점에 오류로 실패하고 스키마가 바뀌지 않는다.
- 오류 메시지가 DDL 시점에 맞는 내용으로 원인(고정 길이 부분이 행 크기 한도를 넘음)을 알려 준다.
- 하한이 한도 이하인 스키마는 지금처럼 허용된다. 경계값에서 잘못 거부하지 않는다.
- 이미 한도를 넘는 기존 테이블(PR #8416 이전에 만들어 `REC_BIGONE` 행을 가진 DB)의 무관한 ALTER(ADD INDEX 등)와 DROP COLUMN은 막지 않는다.
- 시스템 클래스와 VCLASS는 검사 대상이 아니다.
- `feature/oos-merge` 를 `develop` 에 병합하기 전에 완료한다.

### Definition of done

- SQL TC로 CREATE, ADD, MODIFY, CHANGE, UNDER, LIKE, 경계값, 기존 초과 테이블의 ADD INDEX와 DROP COLUMN을 확인한다.

### ANALYSIS 확인 사항

- **검사 위치.** `classobj_install_template` (`src/object/class_object.c`)이 flatten된 템플릿의 고정 길이 크기 합을 이미 계산한다(`class_->fixed_size`). 이 함수는 `install_new_representation` → `update_class` (`schema_manager.c`) 경로에서 불리고, 위 DDL이 모두 이 경로를 지난다. 다만 `fixed_size` 는 `DB_ATT_ALIGN` 으로 올림된 값이라 그대로 쓰면 경계에서 최대 3바이트 잘못 거부한다. heap 검사와 같은 식으로 다시 계산해야 하는지 확인한다.
- **기존 초과 테이블.** `sm_add_constraint` 도 같은 갱신 경로를 지난다. 단순 검사를 넣으면 ADD INDEX까지 막힌다. "새 하한이 한도를 넘고 이전 하한보다 커질 때만 거부"하는 조건이 적절한지 정한다.
- **한도 값.** 한도는 페이지 크기에 따라 달라지는 서버 값이다. 클라이언트에서는 기존 API `heap_get_maxslotted_reclength` 로 받을 수 있다.
- **오류 코드.** -1396 메시지는 쓰기 시점 문구라 DDL에 맞지 않는다. 새 오류 코드와 메시지가 필요한지 정한다.
- **미확인 경로.** 파티션 테이블, `CREATE TABLE ... AS SELECT`, `ALTER ... CHANGE`, 상속 전파 중 ALTER 실패의 원자성, CS 모드 동작은 확인하지 않았다.
- **HA.** DDL은 SQL 문장으로 복제된다. 업그레이드 중 버전이 다른 slave가 DDL을 거부하면 복제가 멈출 수 있는지 확인한다(추정, 확인 안 함).

### 관련 이슈

- CBRD-26937: OOS 이후에도 한도를 넘는 행을 쓰기 시점에 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거부하는 규칙과 오류 코드를 도입했다. DDL 검사는 다루지 않았다.
- CBRD-27259: 이 거부 규칙을 OOS 값이 없는 사용자 행까지 넓힌 이슈(PR #8416).
- 같은 리뷰의 `ALTER ... STORAGE FORCE_INLINE` 뒤 unload/load 실패 지적([discussion_r4536816653](https://github.com/CUBRID/cubrid/pull/8416#discussion_r4536816653))도 "DDL은 받고 이후 쓰기에서 거부"라는 같은 모양이다. 그러나 가변 컬럼의 FORCE_INLINE은 값에 따라 들어갈 수 있으므로 이 이슈의 DDL 하한 검사로는 해결되지 않는다.
