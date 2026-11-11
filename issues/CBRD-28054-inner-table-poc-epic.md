# [OOS] [EPIC] [POC] Inner Table: 큰 VARCHAR·VARBIT 값을 숨은 companion 테이블의 chunk 행으로 저장

**한 줄 요약**: OOS(CBRD-26357)의 대안 설계 후보인 Inner Table POC를 추적하는 이슈다. 큰 값을 OOS 전용 파일 대신 일반 MVCC 테이블의 행으로 저장해도 OOS와 같은 조회 이득을 얻으면서 복구·vacuum·DDL을 기존 경로에 맡길 수 있는지 POC로 확인한다.

## Issue Triage

**이슈 수행 목적**: 대용량 컬럼 저장 구조를 결정할 때 OOS와 비교할 수 있는 근거를 확보한다. Inner Table 방식이 정확성, 조회 I/O, 미사용 비용, 운영 기능(HA, CDC, flashback, TDE) 측면에서 어디까지 성립하는지 단계별 수락 결과로 보여준다.

**이슈 수행 이유**: OOS는 큰 값을 별도 OOS 파일에 두고 그 값의 쓰기·회수·복구를 전용 경로로 관리한다. 이 전용 경로에서 결함이 계속 나오고 있다. 예를 들어 CBRD-27827은 동시 INSERT 중 OOS 파일 헤더 경합이고, CBRD-28035는 회수되지 않는 OOS chain이다. 값을 일반 MVCC 행으로 두면 수명 관리를 기존 heap·btree·vacuum 경로가 맡는다. 다만 그 경로 자체의 결함은 그대로 물려받는다. 이 POC의 phase 1에서 heap vacuum의 slot 재사용 결함 CBRD-27935, CBRD-27936을 실제 서버로 재현한 것이 그 예다. 이 방식이 실제로 성립하는지, 비용은 얼마인지 확인이 필요하다.

**영향**: 저장 구조 결정을 맡은 엔진 개발자와 리뷰어가 대상이다. POC 결과가 없으면 OOS의 대안을 설계 문서만으로 비교해야 한다. 이 POC는 제품 기능이 아니며 병합 대상이 아니다. OOS 병합 일정을 막지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. POC 자체의 진행 방식은 아래 계획을 따른다.

---

## AI-Generated Context

## Description

### 설계 요약

- 큰 값을 옮길 수 있는 테이블 `T`마다 숨은 companion 클래스 `T__inner (ck BIGINT PRIMARY KEY, chunk BIT VARYING)`가 있다. 값은 페이지 절반 크기 이하의 chunk로 나뉘어 이 테이블의 행이 된다. 키는 `값 ID << 20 | 순번`이다.
- 행 길이가 `inner_table_threshold` 이상이면 큰 VARCHAR·VARBIT 값이 chunk 행으로 옮겨진다. 원래 행에는 28바이트 참조가 남는다. 참조는 페이지·slot 주소가 아니라 논리 값 ID를 가리킨다.
- 덮어쓰기와 DELETE는 이전 chunk 행을 일반 MVCC DELETE로 은퇴시킨다. 오래된 snapshot은 이전 값을 계속 읽고, 회수는 일반 vacuum이 한다.
- DROP, TRUNCATE, RENAME은 부모 테이블에서 companion으로 같은 savepoint 안에서 전파된다. companion에 직접 거는 같은 DDL은 거부된다.
- 큰 값 컬럼을 읽지 않는 스캔은 참조를 펼치지 않는다. 그래서 chunk 페이지를 읽지 않는다.

### 진행 현황 (2026-11-11)

엔진 브랜치는 `inner-table`이며 `develop` `e64a04a79` 기반이다. 수락 판정은 각 phase의 driver(`contrib/benchmarks/inner_table/`)가 하고, 모든 driver에 일부러 틀린 입력으로 실패하는지 보는 대조군이 있다.

| Phase | 내용 | 결과 |
| --- | --- | --- |
| 1 lifecycle | slot 재사용과 restart undo 경합을 실제 서버에서 재현 | CBRD-27935, CBRD-27936 재현과 수정 확인 |
| 2 storage | VARCHAR·VARBIT, 경계값, 여러 컬럼, chunk 누락 검출 | VERIFIED |
| 3 recovery | 8개 crash 시점, 두 번씩 restart, checkdb | VERIFIED (60개 판정) |
| 4 reclamation | 오래된 snapshot, vacuum 회수, 반복 churn | VERIFIED |
| 5 transport | 인덱스, trigger, 스키마 변경, 실패·rollback된 DDL, unloaddb/loaddb, compactdb | VERIFIED (70개 판정) |
| 10 projection | 작은 컬럼 집계 스캔의 페이지 수 | VERIFIED. 데이터 페이지 6~10개, 기준 802~1004개 |
| 11 unused | 기능을 쓰지 않거나 큰 값이 없는 테이블의 INSERT·SELECT·UPDATE·DELETE 비용 | 명령어 수 기준 VERIFIED. 8개 workload 모두 비율 0.958 이상. 시간 기준은 공용 서버 부하로 미확정 |
| 6 history | CDC, flashback | 미착수 |
| 7 ha | 복제 | 미착수 |
| 8 encryption | TDE | 미착수 |
| 9 compatibility | 이전 바이너리의 거부 | 미착수 |
| 12 regressions | SQL, shell, medium 회귀 | 미착수 |

### 알려진 한계

- companion 클래스가 `db_class`에 보이고, 이 클래스에 직접 DML을 할 수 있다.
- FK cascade로 자식 테이블이 TRUNCATE될 때 자식의 companion에는 전파되지 않는다.
- CDC와 flashback이 companion 클래스를 걸러내지 않는다(phase 6에서 다룬다).
- 64KiB 값을 전부 읽으면 chunk 페이지 약 1400개를 읽는다. 기준 overflow 방식은 800개다. chunk 크기 조정은 아직 하지 않았다.
- 시간 기준 미사용 비용은 한가한 서버에서 다시 측정해야 한다. 공용 서버(load average 27~175)에서는 신뢰구간이 0.1~0.25로 넓었다. inline UPDATE의 시간 비율은 0.84로 기준에 못 미쳤고, 이것이 실제 비용인지 서버 부하 때문인지는 아직 가르지 못했다.

### 산출물

- 설계·계획 문서: [my-cubrid-docs inner-table](https://github.com/vimkim/my-cubrid-docs/tree/main/inner-table)
- 엔진 draft PR: [CUBRID/cubrid#8494](https://github.com/CUBRID/cubrid/pull/8494)

### 관련 이슈

- CBRD-26357: OOS EPIC. 이 POC는 그 대안 후보다.
- CBRD-27935, CBRD-27936: phase 1에서 실제 서버로 재현한 heap vacuum 결함. 이 POC가 기대는 기존 경로의 결함이다.
- CBRD-27827, CBRD-28035: OOS 전용 경로에서 나온 결함의 예
- CBRD-27725: OOS 분리 시점을 늦추는 방식의 평가. OOS 구조 안의 다른 대안이다.
