# [OOS] 개발자 SQL/Shell 회귀 테스트 작성·검증 및 CI 전달

## Issue Triage

**이슈 수행 목적**: 개발자가 OOS 의 공개 SQL 테스트와 비공개 shell 테스트를 작성하고 검증하여, 값 보존과 저장소 수명에 대한 회귀 검증을 회사 CI 에 전달한다. 검증한 동작과 남은 엔진 결함·관찰 공백을 구분한다.

**이슈 수행 이유**: 기존 본문은 시나리오와 작성 위치를 정하는 계획 단계에 머물러 있다. 이후 개발자 작성·검증 범위를 확정하고 SQL 17쌍과 shell 진입점 18개를 게시했으며, CI 환경의 helper 문제와 파티션 이동의 복제 assertion 도 수리했다. 이전 16 byte stub, raw page-quarter 기준과 isolation 전용 분리는 현재 합의·산출물에 맞춰 갱신해야 한다.

**영향**: 논리 값의 통과를 물리 배치·회수·복제의 통과로 확대하면 미해결 저장소 결함을 놓칠 수 있다. 반대로 과거 계획과 실패 결과만 남기면 이미 작성·검증한 회귀 테스트와 수리 결과를 확인하기 어렵다. 현재 SQL 은 회사 CI 에서 통과했지만 shell 전체와 TC 병합 조건은 아직 완료되지 않았다.

**이슈 수행 방안**: 동작별 커버리지와 독립적인 기대값을 기준으로 공개 `test_sql` 과 비공개 `test_shell` 을 유지한다. 정확한 엔진·TC 리비전의 로컬 결과와 회사 CI 결과를 각각 기록한다. 알려진 결함 재현기는 올바른 기대값과 실행 상태를 보존하며, 현재 남은 shell 실패와 후속 공백의 처리·수락 및 두 TC PR 의 동료 검토를 완료 조건과 분리해 추적한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 맥락을 분석해 작성한 상세 자료다.

## Description

OOS(Out-of-row Overflow Storage)는 heap record 의 큰 가변 속성 값을 별도 `FILE_OOS` 에 저장하고 원래 행에는 inline stub 을 남기는 기능이다. 테스트는 사용자에게 보이는 전체 값뿐 아니라 복사, UPDATE/DELETE, 트랜잭션, 스키마 변경, crash recovery, snapshot 과 파일 정리에서 필요한 값과 소유권이 유지되는지 확인해야 한다.

2026-10-08 합의에서는 개발자가 공개 SQL 과 비공개 shell 테스트를 직접 작성하고 로컬에서 검증하기로 했다. 과거 adversarial 캠페인과 C++ unit test 는 시나리오·기대값의 조사 자료다. 단일 세션의 결정적인 결과는 SQL 로, 실제 세션 순서·서버·유틸리티·물리 진단을 제어해야 하는 동작은 shell 로 전달한다. 6월 이슈 댓글에서 요청한 컬럼 순서, 추가·삭제, default 기반 record rewrite, inline/OOS 전환과 타입·속성 변경도 스키마 검증 범위에 유지한다.

2026-10-13 02:37 KST 기준으로 초기 14개 구현 묶음의 산출물은 전달되었고 세 PR 은 모두 draft/OPEN 이다. 최신 엔진 `1ef86a7` 에 대한 회사 CI 는 종료되었다. SQL 전체 17,488개와 medium 975개는 통과했고, shell 은 7개 실패했다. 테스트 파일 전달과 선택한 동작의 검증, 전체 엔진의 명세 충족, QA 수락 및 PR 병합은 각각 별도 상태다.

현재 JIRA 유형은 `Sub-task`, 부모는 [CBRD-26357](http://jira.cubrid.org/browse/CBRD-26357) 이다. shell handover 이슈 [CBRD-26871](http://jira.cubrid.org/browse/CBRD-26871) 은 `Duplicate` 로 해결되어 연결되어 있다. 이 본문은 기존 이슈의 개발자 SQL/Shell 작업을 갱신하며, 관련 이슈의 오래된 임계치나 미구현 관측 수단을 현재 규칙으로 계승하지 않는다.

## Specification Changes

N/A. 이 이슈의 산출물은 회귀 테스트와 검증·전달 기록이다. 새 사용자 SQL 문법이나 디스크 형식을 정의하지 않는다. 테스트 정상화에 필요했던 제한적인 엔진 수리는 아래에 실제 변경으로 기록한다.

### 이전 계획에서 갱신한 기준

| 항목 | 현재 적용 기준 |
| --- | --- |
| 작성 책임과 위치 | 개발자가 `cubrid-testcases` 의 SQL 과 `cubrid-testcases-private-ex` 의 shell 을 작성·검증한다. 두 TC PR 의 브랜치는 `tc/pr-8128`, 대상은 `feature/oos-merge` 다. |
| 세션 분리 | 실제 snapshot 및 동시 writer 순서는 비공개 shell 의 세션 controller 로 검증한다. 예전 계획의 별도 isolation 디렉터리 작성 체크리스트를 현재 전달 조건으로 사용하지 않는다. |
| 크기와 발동 조건 | 승인된 inline stub 과 chunk header 는 24 byte 다. 가변 속성의 직렬화 크기가 `OR_OOS_INLINE_SIZE` 24 byte 를 엄격히 초과해야 후보가 된다. 일반 demotion 의 승인 목표는 unfill 과 독립적인 네 레코드 heap 용량이며 16 KiB I/O layout 에서 4,060 byte 다. 현재 엔진의 raw `DB_PAGESIZE/4` 4,086 byte 와의 차이는 CBRD-27057 검증 공백으로 남긴다. |
| OOS 동작 증거 | 전체 값·독립 hash 를 논리 기대값으로 사용한다. 물리 배치·파일 소유권은 shell 의 긍정적인 `SHOW HEAP OOS`/`diagdb` 관찰로 확인한다. SQL 길이나 `DISK_SIZE` 만으로 물리 배치를 증명하지 않는다. |
| UPDATE chain 재사용 | 미할당 속성의 chain 재사용과 commit 조건부 vacuum 통지는 CBRD-27230 의 승인 요구사항이다. 예전의 취소된 미래 기능 분류를 유지하지 않으며, 구현·검증 공백을 명시한다. |
| 실행 비용 | SQL 과 shell 의 전체 실행 시간을 각각 측정한다. 각각 약 10분은 참고 지침이며 합산 제한이나 필수 통과 조건이 아니다. 로컬 시간의 회사 CI 환산 비율을 가정하지 않는다. |
| 엔진 수리 범위 | 2026-10-12 합의에 따라 대상 SQL 14개 정상화에 필요한 공통 파티션 assertion 원인의 수리를 허용했다. 다른 파티션·회수·복제 요구사항의 완료를 뜻하지 않는다. |

OOS 요구사항의 기준은 [정규 명세](https://github.com/vimkim/cubrid-oos-context/blob/c6fc51bc0e27032c9c4fb999ce3e0342b20d2349/OOS-CONTEXT.md) 다. 확인한 파일의 SHA-256 은 `b38059a3a8e9495a88c16cfe14daec89d72586e3d0ef2c86755b64305ebccb65` 다. 구현과 명세의 차이는 테스트 정답을 바꾸는 근거가 아니다.

## Implementation

### 전달한 테스트와 증거의 범위

| 산출물 | 위치와 주요 검증 |
| --- | --- |
| 공개 SQL/answer 17쌍 | `sql/_36_guava/cbrd_26659/` 에 표현·chunk 경계, 여러 속성, INSERT/복사, UPDATE/DELETE, 트랜잭션·실패 DML, 제약·trigger, 읽기 경로, 스키마·storage policy, 파티션 라우팅·이동과 외부 LOB 복사를 전달했다. |
| 비공개 shell 진입점 18개 | `shell/_40_guava/` 에 owner DROP, 표현/DML/읽기/스키마/LOB 의 별도 물리 fixture, commit crash redo, 미완료 트랜잭션 undo, 실제 snapshot, utility/backup round trip 과 TDE/WAL 검증을 전달했다. 알려진 결함 재현기 네 개를 포함한다. |
| 동작별 커버리지 31항목 | 요구사항·관련 이슈·기존 unit/SQL/shell 사례와 실제 fixture, 기대값, 실행 결과 및 한계를 연결했다. 같은 사례가 여러 동작을 검증하더라도 각 assertion 과 결과를 구분한다. |
| 기대값과 정리 | 실제 오동작 출력으로 answer 를 생성하지 않는다. 구별 가능한 VARBIT 패턴, 전체 값·독립 hash·행/트랜잭션 모델을 사용한다. 물리 parse 실패나 빈 결과는 성공으로 처리하지 않으며, 소유한 DB·등록·경로·프로세스와 설정의 정리 결과를 남긴다. |

### 추가된 SQL TC 파일별 목록

아래 경로는 공개 `cubrid-testcases` 저장소 기준이다. 링크는 현재 public head `d7bec2f` 에 고정했고, 각 SQL 의 정답 파일도 함께 연결했다. disable 여부는 현재 PR8128 의 Linux `gha-ci` 에서 해당 TC 전체가 실행 제외 또는 skip 되어 있는지를 뜻한다. 두 TC 저장소의 제외 설정과 실제 [최종 CI](https://github.com/CUBRID/cubrid/actions/runs/38271660063) XML 을 대조했으며, 아래 35개 TC 는 모두 실제 실행되었고 skip 은 0개다.

| 파일 경로와 정답 | 파일별 검증 요약 | 현재 disable 여부 | 최종 CI 결과 |
| --- | --- | --- | --- |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_chunk_boundaries.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_chunk_boundaries.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_chunk_boundaries.answer) | 직렬화된 chunk 용량 경계의 직전·정확·직후 값과 구별 가능한 내용이 복사·UPDATE·원본 DROP 후에도 보존되는지 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_partition.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_partition.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_partition.answer) | 파티션 라우팅·key UPDATE 이동·재구성에서 논리 값 보존을 확인한다. 이전 assertion 재현기이며 현재 수리 head 에서는 통과한다. 목적지의 물리 소유권은 별도 shell TC 가 검증한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_partition_routing.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_partition_routing.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_partition_routing.answer) | 파티션 생성·INSERT 라우팅·읽기와 duplicate-key 거부를 확인한다. 이동·재구성·물리 소유권은 검증 범위에 포함하지 않는다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_representation.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_representation.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_representation.answer) | 크기가 다른 VARBIT 구성, NULL·빈 값·비바이트 정렬 값과 작은 VARCHAR 에서 논리 값 및 24 byte profitability 경계 주변의 표현을 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_schema.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_schema.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_schema.answer) | 컬럼 순서·추가·삭제, hard default 기반 rewrite, OOS 후보 컬럼 DROP, inline/OOS 전환 조건과 타입·속성 변경 뒤 값·catalog 를 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql01_insert_select.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql01_insert_select.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql01_insert_select.answer) | VALUES/INSERT SELECT 로 만든 네 행의 전체 값·독립 hash·행 식별자와 원본 DELETE/DROP 후 복사본의 독립성을 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql04_delete.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql04_delete.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql04_delete.answer) | DELETE·TRUNCATE·재삽입 뒤 전체 행 모델을 대조하고 영향받지 않은 survivor 의 값이 보존되는지 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql04_update.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql04_update.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql04_update.answer) | 값 성장·축소, NULL·빈 값 전환, 미할당·동일 값 할당과 반복·복사 UPDATE 의 모든 컬럼 및 survivor 를 확인한다. chain 재사용은 별도 미검증 항목이다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_bigone.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_bigone.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql05_bigone.answer) | OOS stub 과 bigone 이 함께 필요한 INSERT/UPDATE 의 거부, 허용되는 인접 크기·일반 bigone 대조와 거부 뒤 기존 행 보존을 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_constraints.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_constraints.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql05_constraints.answer) | PK/UNIQUE/NOT NULL 및 view CHECK OPTION 의 오류 결과와 거부된 DML 뒤 값 보존을 확인한다. table CHECK 의 enforcement 는 검증 실적으로 계산하지 않는다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_transactions.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql05_transactions.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql05_transactions.answer) | COMMIT·ROLLBACK·SAVEPOINT, DELETE rollback 과 실패 DML 의 즉시 원자성을 독립적인 전후 행 모델로 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql06_triggers.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql06_triggers.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql06_triggers.answer) | AFTER UPDATE 의 log/mirror, BEFORE UPDATE 의 거부와 이후 정상 쓰기의 논리 결과를 확인한다. triggered DML 의 OOS 물리 배치는 별도 공백이다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql07_read_paths.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql07_read_paths.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql07_read_paths.answer) | heap/index projection, join·집계 등 relational read 와 CTAS/복사에서 전체 값·독립 hash·혼합 scalar 값을 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql09_lob_copy.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql09_lob_copy.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql09_lob_copy.answer) | VARBIT 와 BLOB/CLOB 를 복사하고 원본 DELETE/DROP 뒤 복사본의 내용·hash 를 확인한다. locator demotion 은 별도 shell fixture 로 관찰한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql09_lob_maxcols.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_sql09_lob_maxcols.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_sql09_lob_maxcols.answer) | 1,000개 LOB 컬럼 행의 크기 초과 거부와 두 locator 만 채운 sparse 행의 성공을 확인한다. 최대 컬럼 구성의 호환성 대조다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_storage_policy.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_storage_policy.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_storage_policy.answer) | DEFAULT/PREFER_INLINE/FORCE_OUTLINE 의 CREATE·LIKE·MODIFY·CHANGE·설정 생략/해제와 지원·거부 domain 의 metadata 및 논리 값을 확인한다. | 아니오(활성) | 통과 |
| [sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_vot_many_attributes.sql](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/cases/cbrd_26659_oos_vot_many_attributes.sql) · [정답](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/answers/cbrd_26659_oos_vot_many_attributes.answer) | BYTE/SHORT/INT VOT 모델 경계와 서로 다른 12개 속성의 전체 값·hash 를 확인한다. 실제 binary VOT 폭을 직접 읽는 검증은 포함하지 않는다. | 아니오(활성) | 통과 |

### 추가된 shell TC 파일별 목록

아래 경로는 비공개 `cubrid-testcases-private-ex` 저장소 기준이며 링크는 현재 private head `a2054f9` 에 고정했다. 최종 CI 에서 18개 중 14개가 통과하고 네 재현기가 실패했다. 로컬 통과 선택 집합이나 수리 범위에서 제외한 재현기도 CI 발견·실행은 활성 상태로 유지한다.

| 파일 경로 | 파일별 검증 요약 | 현재 disable 여부 | 최종 CI 결과 |
| --- | --- | --- | --- |
| [shell/_40_guava/cbrd_26659_backup_restore/cases/cbrd_26659_backup_restore.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_backup_restore/cases/cbrd_26659_backup_restore.sh) | engine volume 의 backup/restore 뒤 전체 값·schema·OOS owner 와 checkdb 를 확인한다. 외부 LOB payload 의 backup 보장은 범위에 포함하지 않는다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_crash_committed/cases/cbrd_26659_crash_committed.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_crash_committed/cases/cbrd_26659_crash_committed.sh) | commit 완료 ACK 와 독립 journal 을 확보한 뒤 실제 SIGKILL·복구를 수행하고 커밋된 전체 값과 OOS 복구 관찰을 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_crash_undo/cases/cbrd_26659_crash_undo.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_crash_undo/cases/cbrd_26659_crash_undo.sh) | 미완료 쓰기 ACK 뒤 SIGKILL·복구를 수행하여 undo 된 행 모델과 새 chunk record 제거를 확인한다. 빈 page 반환은 별도 요구사항이다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_dml_transitions/cases/cbrd_26659_dml_transitions.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_dml_transitions/cases/cbrd_26659_dml_transitions.sh) | SA 모드에서 growth/shrink·NULL·empty·DELETE 전환의 현재 chunk 수·slot bytes·전체 값과 survivor 를 확인한다. MVCC 수명·page reclaim 은 별도다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_lob_locators/cases/cbrd_26659_lob_locators.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_lob_locators/cases/cbrd_26659_lob_locators.sh) | 두 BLOB/CLOB locator 만 있는 fixture 의 물리 demotion·복사와 소유 원본 파일 파괴 뒤 복사된 외부 내용·owner 생존을 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_owner_drop/cases/cbrd_26659_owner_drop.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_owner_drop/cases/cbrd_26659_owner_drop.sh) | inline 대조, lazy OOS 파일 생성, SHOW/descriptor 소유권, owner DROP 후 파일 제거와 독립 survivor 값·파일 보존을 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_partition_owner/cases/cbrd_26659_partition_owner.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_partition_owner/cases/cbrd_26659_partition_owner.sh) | 일반/FORCE_OUTLINE 파티션 라우팅·이동·duplicate probe 뒤 목적지 class/file/chunk 소유권을 확인한다. CBRD-27089 의 올바른 물리 기대값을 유지한 재현기다. | 아니오(활성) | 실패 |
| [shell/_40_guava/cbrd_26659_read_paths/cases/cbrd_26659_read_paths.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_read_paths/cases/cbrd_26659_read_paths.sh) | 별도 CS fixture 의 relational read 결과·실행 계획·긍정적인 OOS owner 관찰과 CTAS 후 원본 DROP 시 값 보존을 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_representation_chunks/cases/cbrd_26659_representation_chunks.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_representation_chunks/cases/cbrd_26659_representation_chunks.sh) | largest-first·inline 대조·24 byte floor·여러 속성·chunk 경계 fixture 의 정확한 chunk 수와 slot bytes 및 전체 값을 독립 모델과 비교한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_schema_policy/cases/cbrd_26659_schema_policy.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_schema_policy/cases/cbrd_26659_schema_policy.sh) | storage policy DDL 의 metadata·largest/protection/fallback/floor 배치, 비소급 ALTER 뒤 쓰기 및 스키마 rewrite 의 별도 CS 값을 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_snapshot_visibility/cases/cbrd_26659_snapshot_visibility.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_snapshot_visibility/cases/cbrd_26659_snapshot_visibility.sh) | 실제 old/new snapshot 과 writer ACK 순서, 이전 값·새 값의 정확성 및 obsolete chunk record 정리를 확인한다. page 반환은 검증 실적으로 계산하지 않는다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_snapshots_reclaim/cases/cbrd_26659_snapshots_reclaim.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_snapshots_reclaim/cases/cbrd_26659_snapshots_reclaim.sh) | 실제 snapshot 수명·writer 와 chunk drain 이후 빈 OOS page 반환 및 후속 churn 조건을 검증한다. 올바른 page-return 기대를 유지한 재현기이며 미도달 후속 단계는 미검증이다. | 아니오(활성) | 실패 |
| [shell/_40_guava/cbrd_26659_tde_wal/cases/cbrd_26659_tde_wal.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_tde_wal/cases/cbrd_26659_tde_wal.sh) | lazy OOS 파일의 암호화 metadata·owner, OOS WAL flag 와 정상 재시작 뒤 전체 값을 확인한다. 기존 파일 암호화 전환·ciphertext·crash/HA 는 별도 공백이다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_transactions/cases/cbrd_26659_transactions.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_transactions/cases/cbrd_26659_transactions.sh) | 별도 CS fixture 의 baseline/writer OOS 배치와 전체 rollback·DELETE rollback·savepoint 의 논리 값을 확인한다. vacuum 이후 안전성은 별도다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_utility_cs/cases/cbrd_26659_utility_cs.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_utility_cs/cases/cbrd_26659_utility_cs.sh) | CS unload/load·compact round trip 의 전체 값·schema·OOS 물리 owner 와 명시적인 외부 LOB 전달·checkdb 를 확인한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_utility_sa/cases/cbrd_26659_utility_sa.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_utility_sa/cases/cbrd_26659_utility_sa.sh) | SA load 경로의 전체 값·schema·외부 LOB 전달과 utility round trip 을 확인한다. SA destination 의 OOS 물리 배치는 별도 TC 로 요구한다. | 아니오(활성) | 통과 |
| [shell/_40_guava/cbrd_26659_utility_sa_physical/cases/cbrd_26659_utility_sa_physical.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_26659_utility_sa_physical/cases/cbrd_26659_utility_sa_physical.sh) | SA load destination 에서 의도한 OOS4/37316 배치와 소유권을 요구한다. CBRD-27424 의 물리 배치 기대값을 유지한 재현기다. | 아니오(활성) | 실패 |
| [shell/_40_guava/cbrd_27237_rollback_vacuum/cases/cbrd_27237_rollback_vacuum.sh](https://github.com/CUBRID/cubrid-testcases-private-ex/blob/a2054f965a20241b87dc9577585ccc8a8cb6ab97/shell/_40_guava/cbrd_27237_rollback_vacuum/cases/cbrd_27237_rollback_vacuum.sh) | UPDATE·ROLLBACK 과 daemon vacuum 을 거친 뒤 원래 pre-image 전체 값의 안전한 읽기를 요구한다. CBRD-27237 의 수명 결함 재현기다. | 아니오(활성) | 실패 |

각 shell 사례의 `setup.sql`, SQL/JSON fixture 와 공통 `oos_common/`, `oos_utility/` 파일은 해당 TC 의 보조 입력·helper 다. 위 표는 CI 가 독립 TC 로 발견하는 진입점 18개를 센다. disable 판정의 범위는 확인한 Linux CI 설정과 위 두 head 이며, 다른 플랫폼이나 별도의 QA 실행 설정은 각각 확인해야 한다.

물리 shell companion 은 자신의 fixture 와 설정에 대한 증거다. 실제 공개 JDBC SQL 실행의 OOS 배치를 관찰한 증거로 계산하지 않는다. 파일과 chunk record 의 제거, 빈 page 의 file manager 반환, old snapshot/rollback 의 안전성도 각각 별도 검증이다.

shell helper 는 기존 저장소 관례에 맞춰 Bash/awk/jq 중심으로 전환했고, 프로세스 소유권 제어에는 작은 Linux C adapter 를 사용한다. CI 가 다른 사례의 `cases/` 디렉터리를 제거하여 snapshot controller 를 찾지 못하던 문제는 private TC `a2054f9` 에서 controller 를 `shell/_40_guava/oos_common/snapshot_controller.sh` 로 옮겨 수리했다. 기존 assertion 과 제한 시간은 보존했다. 최신 CI 에서 `snapshot_visibility` 는 통과한다.

### 현재 게시 리비전과 엔진 수리

| 저장소/PR | 확인한 head | 상태 |
| --- | --- | --- |
| [Engine #8128](https://github.com/CUBRID/cubrid/pull/8128) | `1ef86a7efa34002e971b1b30bcf5d451e9db441b` | `vimkim/cubrid:CBRD-26659-oos-testcases-handover`, draft/OPEN |
| [공개 TC #3688](https://github.com/CUBRID/cubrid-testcases/pull/3688) | `d7bec2fdeb6a19573300e1a624e03e0b87eb9e96` | `tc/pr-8128`, draft/OPEN |
| [비공개 TC #4365](https://github.com/CUBRID/cubrid-testcases-private-ex/pull/4365) | `a2054f965a20241b87dc9577585ccc8a8cb6ab97` | `tc/pr-8128`, draft/OPEN |

Engine PR 은 처음에 엔진 파일 변경 없는 연결용 커밋 `a5da823` 으로 시작했다. 이후 파티션 key UPDATE 의 destination INSERT 가 OOS insertion LSA queue 를 소비한 뒤 source index DELETE 가 같은 OOS publication 정보를 다시 복제하려고 하여 빈 queue assertion 이 발생하는 경로를 입증했다.

[수리 커밋 `1ef86a7`](https://github.com/CUBRID/cubrid/commit/1ef86a7efa34002e971b1b30bcf5d451e9db441b) 은 `locator_add_or_remove_index_internal` 의 OOS post-image 복제 루프를 INSERT 에만 적용한다. DELETE 의 primary-key 복제와 queue assertion 은 유지한다. 최소 재현 및 이동 없음/inline/PK 없음/HA off 대조를 보존했고, SQL/answer/fixture/discovery 를 변경하지 않았다. 공개 TC 의 `1a556a0` 이후 변경은 검증·범위 README 다.

2026-10-12 수리 범위는 기존 corpus 에서 이미 확인한 동일 증상 실패와 사전에 올바른 기대값을 유지한 결함 재현기를 제외한 SQL 14개다. 제외는 수리 범위 판정이며 실행 비활성화나 정답 변경이 아니다. 제외된 full partition 의 공통 crash 원인을 수리했더라도 destination 의 물리 소유권 등 별도 요구사항은 남는다.

## Validation

### 리비전별 로컬 검증

| 시점·조건 | 실제 결과와 적용 범위 |
| --- | --- |
| 2026-10-08, Engine `fb567a6`, OptDebug, JDBC/16 KiB | public `c949615` 의 선택 SQL 16/16, 88.523774초. private `f5fc1fa` 의 선택 shell 14/14, 316.414065초. 당시 통과 집합 밖의 재현기는 별도로 보존했다. |
| 2026-10-12 shell 전환, Engine `a5da823`, OptDebug, private `5f049c5` | 선택 shell 14/14, 실패·skip 0, 305.251934초. 기존 336개 assertion 을 보존하고 소유권 정리 20개를 더한 356개 assertion 및 원시 결과·정리 증거를 재검증했다. 이후 controller 경로 수리는 이 로컬 리비전보다 최신이다. |
| 2026-10-13 SQL 수리, Engine `1ef86a7`, `11.5.0.2639-1ef86a7`, Debug, JDBC/HA/16 KiB | 대상 14개를 각 fresh DB 에서 독립 실행하여 모두 golden·artifact·소유 자원 정리를 통과했다. 실제 public 실행 리비전 `1dec9d1` 과 게시 head `d7bec2f` 의 SQL/answer/fixture 는 동일하다. |
| 같은 최종 엔진, 원래 `sql/_36_guava` 72-case 순서 | 72/72 통과, 617.50초. full partition 은 43번, 대상 14개는 44–57번에서 통과했다. 실행 순서·manifest·XML 사례 집합과 개별 판정·정리를 대조했다. |
| 같은 최종 엔진의 CMake/ctest | 35/35 통과, 165.18초. 대상별 SQL 과 물리 shell 검증을 대체하지 않는다. |

각 SQL/shell 시간은 해당 runner 실행의 setup·정리를 포함하며, build/download·복사 준비·별도 증거 검증 시간과 구분한다. 서로 다른 build mode 와 실행 도구의 결과를 같은 환경의 재실행으로 설명하지 않는다. 특히 unpatched native 순서 실행의 69/72 결과는 이전 CI 의 57/72 결과와 다르며, 로컬 실행을 CI 와 동등한 재현으로 간주하지 않는다.

### 최신 회사 CI 의 종료 결과

[run38271660063, attempt 1](https://github.com/CUBRID/cubrid/actions/runs/38271660063) 은 위 Engine/public/private 게시 head 를 사용한 단일 전체 검증이며, 2026-10-13 02:32 KST 에 종료되었다. 전체 workflow 결론은 실패다. Collector summary 와 61개 shard XML 의 hash·실행 identity·사례 수·개별 판정을 대조했다.

| 검사 | 종료 결과 |
| --- | --- |
| Debug/Release build | 모두 통과 |
| `test_sql` 전체 | 17,488/17,488 통과, 실패·skip 0 |
| 이 이슈의 SQL 17개 | 모두 통과. 수리 대상 14개와 full partition 의 논리 golden 도 통과 |
| `test_medium` 전체 | 975/975 통과, 실패·skip 0 |
| `test_shell` 전체 | 계획 3,307개 중 3,277개 실행: 3,270개 통과, 7개 실패, 30개 skip |
| 이 이슈의 shell 18개 | 14개 통과, 아래 재현기 4개 실패, skip 0 |

기존 PR 설명과 10월 8일/12일 문서의 “CI 미실행”, “엔진 파일 변경 없음”, “SQL partition 실패”는 각각 그때의 관측이다. 최신 head 의 위 결과로 현재 진행 상태를 판단한다. full partition SQL 의 논리 통과로 physical owner 재현기나 다른 파티션 요구사항을 완료 처리하지 않는다.

### 최신 shell 실패와 미확정 판정

| 사례 | 최신 CI 관측과 처리 |
| --- | --- |
| `cbrd_26659_partition_owner` | destination ownership mismatch 14개가 남는다. CBRD-27089 의 물리 소유권 재현기이며 논리 partition 통과와 별도다. |
| `cbrd_26659_snapshots_reclaim` | controller exit 1 로 실패한다. 로컬 재현에서는 chunk drain 후 user page 수가 줄지 않아 page return/churn 검증을 완료하지 못했다. 최신 CI 의 내부 첫 실패 원인은 공개된 controller 상태만으로 확정하지 않는다. |
| `cbrd_27237_rollback_vacuum` | 의도한 pre-image 검증이 controller exit 1 로 실패한다. 로컬에서 관측한 metadata corruption 과 최신 CI 의 내부 원인을 동일하다고 확정하지 않으며, rollback-after-vacuum 안전성은 미검증이다. |
| `cbrd_26659_utility_sa_physical` | source 값·OOS4/37316·LOB 전달 후 utility controller exit 1 로 실패한다. 로컬의 SA destination 배치 미달 재현과 함께 남기되 최신 CI 의 내부 원인 확정은 별도다. |
| 기존 `cbrd_27064` | CDC delete/update extractor `rc=-10` 으로 실패한다. ADR-0005 의 deferred OOS history 범위이며 기존 기대값과 실행 상태를 유지한다. |
| 기존 `cbrd_27075` | 4K/8K 에서 extract error, 세 설정 중 하나만 통과한다. deferred OOS history 실패로 남긴다. |
| 기존 `hide_cubrid_replay` | `qa8.answer` 비교가 실패한다. 이전 보고서의 qa9/qa10 실패와 동일 증상이라고 자동 제외하지 않는다. 정확한 기준 대조와 원인·수리 대상 판정은 미확정이다. |

## Remaining Work

### 요구사항과 후속 공백

| 항목 | 유지하는 요구사항과 현재 한계 |
| --- | --- |
| [CBRD-27057](http://jira.cubrid.org/browse/CBRD-27057) | 승인된 4,060/4,064 경계 재현기는 외부에 보존한다. 현재 source 의 raw quarter-page gate 차이는 남으며, 표현/floor 테스트 통과로 목표 경계를 검증했다고 하지 않는다. |
| [CBRD-27230](http://jira.cubrid.org/browse/CBRD-27230) | 미할당 속성 chain 재사용과 commit-조건부 vacuum 통지는 승인 요구사항이다. 현재 `RVOOS_NOTIFY_VACUUM` 은 emitter 없는 예약 슬롯이며 이번 수리로 구현·검증하지 않았다. |
| [CBRD-27237](http://jira.cubrid.org/browse/CBRD-27237), [CBRD-26786](http://jira.cubrid.org/browse/CBRD-26786) | 즉시 rollback, old snapshot 값 및 chunk 제거의 통과가 vacuum 이후 pre-image 수명이나 빈 page 반환·growth 재사용을 보장하지 않는다. 실패·부분 검증 상태를 유지한다. |
| [CBRD-27089](http://jira.cubrid.org/browse/CBRD-27089), [CBRD-27424](http://jira.cubrid.org/browse/CBRD-27424) | destination 소유권과 SA/workspace 물리 demotion 은 각각 별도 미해결 검증이다. 이번 INSERT 복제 guard 와 SA 논리 load 의 통과로 닫지 않는다. |
| TDE | lazy OOS 파일의 알고리즘 metadata/WAL flag 검증은 통과한 부분이다. 기존 파일 NONE→AES 적용, ciphertext/평문 비노출과 crash 복구까지 검증한 것으로 확대하지 않는다. |
| 일반 HA 복제 | 두 node topology 와 실행 수단 준비는 2026-10-08 합의된 후속 과제다. replica 의 독립 값과 replica-local 참조를 검증해야 한다. 단일 DB 의 `ha_mode=yes` 및 이번 queue assertion 수리는 두 node transport 통과 증거가 아니다. |
| 내부 제어·확장 기능 | deterministic retry/slot reuse, allocation fault, binary VOT 폭, 정밀 horizon/cursor 는 관찰 공백을 유지한다. compression/PEEK 등 제안·연기 기능은 승인된 이번 전달 요구사항과 구분한다. |

CDC/flashback history 는 [ADR-0005](https://github.com/vimkim/cubrid-oos-context/blob/c6fc51bc0e27032c9c4fb999ce3e0342b20d2349/docs/adr/0005-defer-oos-history-from-the-11-5-merge.md) 에 따라 11.5 OOS 병합에서 연기되었다. 기존 두 CDC 테스트의 실패를 숨기거나 정답을 오동작에 맞추는 방식으로 완료시키지 않는다.

### 검토·수락과 병합 조건

현재 두 TC PR 이 OPEN 이므로 TC Merge Gate 의 두 TC PR 병합 또는 close 전제는 충족되지 않았다. TC PR 의 검토·병합/close 는 동료가 결정한다. 최신 shell 실패의 처리·후속 추적과 검증 공백의 수락도 남는다. 전체 workflow 실패를 QA 통과로 표시하지 않는다.

## Acceptance Criteria

- [x] 공개 SQL 과 비공개 shell 을 개발자가 작성하고 동작별 커버리지·기대값·확인 한계를 기록한다.
- [x] 6월 댓글의 스키마 변경 범주를 포함해 표현/복사/DML/트랜잭션/읽기/정책/LOB 의 논리 회귀를 전달한다. 실제 JDBC 물리 배치와는 구분한다.
- [x] owner DROP, crash redo/undo, 실제 snapshot, utility/backup, TDE/WAL 의 선택한 shell 동작을 로컬에서 검증하고 정확한 리비전·assertion·소유 자원 정리와 별도 실행 시간을 남긴다.
- [x] 회사 CI 의 helper 의존성과 파티션 assertion 을 올바른 기대값을 보존하여 수리하고 전후 증거를 남긴다.
- [x] 대상 SQL 14개가 최종 엔진의 fresh DB 독립 실행과 원래 72-case 순서에서 통과하며, 최종 CI 에서도 각 대상의 통과를 확인한다.
- [x] 최종 회사 CI 에서 SQL 17개와 선택 shell 14개가 실제 실행되어 통과하고, 나머지 shell 재현기 네 개 및 기존 실패·skip 은 별도로 기록한다.
- [ ] 최신 shell 잔여 실패의 기준 대조·수리 대상·후속 추적을 확정하고 전달 범위의 수락을 완료한다. 알려진 재현기와 공백의 올바른 기대값은 유지한다.
- [ ] 일반 HA 및 명세/물리/관찰 공백의 후속 처리와 전달 한계를 동료가 검토·수락한다.

## Definition of done

- [ ] 위 Acceptance Criteria 의 미완료 항목에 대한 처리·수락이 기록된다.
- [x] 최종 게시 head 의 단일 전체 CI 결과와 대상별 통과/실패가 기록된다. 이 항목의 충족은 전체 QA 통과를 뜻하지 않는다.
- [ ] QA/동료 검토가 전달 범위와 잔여 실패·skip·후속 공백을 확인한다. 현재 전체 CI 는 실패다.
- [ ] 두 TC PR 의 검토와 병합/close 가 완료되어 TC Merge Gate 조건을 충족한다.
- [x] 이슈 본문에 현재 산출물·리비전·결과·한계를 반영하고 기존 테스트 문서를 근거로 연결한다. 이번 작업에 따른 제품 매뉴얼 변경은 N/A 다.

## Code References

- [INSERT 전용 OOS 복제 guard](https://github.com/CUBRID/cubrid/blob/1ef86a7efa34002e971b1b30bcf5d451e9db441b/src/transaction/locator_sr.c#L8164): `locator_add_or_remove_index_internal` 의 수리 범위다.
- [현재 demotion gate](https://github.com/CUBRID/cubrid/blob/1ef86a7efa34002e971b1b30bcf5d451e9db441b/src/storage/heap_file.c#L12840): 승인된 물리 목표와 source 의 raw quarter-page 조건을 구분한다.
- [미사용 vacuum 통지 슬롯](https://github.com/CUBRID/cubrid/blob/1ef86a7efa34002e971b1b30bcf5d451e9db441b/src/transaction/recovery.h#L206): emitter 없는 상태를 확인한다.

## Remarks

- [2026-10-08 합의된 계획](https://github.com/vimkim/my-cubrid-docs/blob/64787e0dfc40382825a71b36e4caf8ec4149b9e9/cbrd-26659/ci-replan/plan.md), [검증 계약](https://github.com/vimkim/my-cubrid-docs/blob/64787e0dfc40382825a71b36e4caf8ec4149b9e9/cbrd-26659/ci-replan/spec.md), [31항목 커버리지](https://github.com/vimkim/my-cubrid-docs/blob/64787e0dfc40382825a71b36e4caf8ec4149b9e9/cbrd-26659/ci-replan/coverage.md): 당시의 동작별 근거와 한계를 유지하며 최신 실행 상태는 위 표를 적용한다.
- [shell 전환과 독립 증거](https://github.com/vimkim/my-cubrid-docs/blob/64787e0dfc40382825a71b36e4caf8ec4149b9e9/cbrd-26659/ci-replan/shell-conversion-results-20261012.md): private `5f049c5` 의 로컬 결과다.
- [현재 SQL 수리 범위와 로컬 검증 요약](https://github.com/CUBRID/cubrid-testcases/blob/d7bec2fdeb6a19573300e1a624e03e0b87eb9e96/sql/_36_guava/cbrd_26659/README.md): 독립 14개와 원래 순서 72개 검증을 기록한다. 이 README 의 CI 대기는 본문에서 최신 종료 결과로 갱신했다.
- [이전 전체 CI run38223008491](https://github.com/CUBRID/cubrid/actions/runs/38223008491): shell 8개·SQL 3개 실패 및 medium 975개 통과의 역사적 결과다.
- [controller 수리 후 replay run38245729674](https://github.com/CUBRID/cubrid/actions/runs/38245729674): 이전 엔진 `a5da823` 에서 SQL 72개 중 15개 및 shell replay 8개 중 5개가 실패했다. 최종 전체 CI 와 실행 범위가 다르다.
- [최종 전체 CI run38271660063](https://github.com/CUBRID/cubrid/actions/runs/38271660063): Engine `1ef86a7`, public `d7bec2f`, private `a2054f9` 의 최신 결과다.
