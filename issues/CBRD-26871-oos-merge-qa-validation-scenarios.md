# [OOS] OOS 병합 검증 시나리오 (QA 전달용)

## Issue Triage

**이슈 수행 목적**: OOS(Out-of-row Overflow Storage - heap 의 큰 가변 컬럼을 별도 OOS 파일로 분리 저장하는 기능)의 `feature/oos-m2` -> `develop` 병합 전에 QA 가 실행할 검증 시나리오 4종(SQL, Shell, HA SQL=`ha_repl`, HA Shell=`ha_shell`)을 표준 OOS 발동 게이트와 함께 정리해 QA 에 전달한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: OOS 는 heap 레코드 길이 > `DB_PAGESIZE/8`(16KB 페이지 기준 약 2KB) **그리고** 가변 컬럼 크기 > 512B 두 조건을 모두 만족할 때만 동작한다(`heap_file.c:12472`). 이 임계를 넘기지 못하는 테스트는 OOS 코드를 한 줄도 실행하지 않는다. 게다가 release 빌드에는 OOS 발동 여부를 증명할 신뢰 가능한 수단이 없다 - `cubrid spacedb` 가 `FILE_OOS` 를 heap 으로 오집계하기 때문이다(`file_manager.c:12236`, `assert_release(false)` 워크어라운드).
- **영향**: QA 통과 오판(거짓 양성) 위험. 검증이 실제 OOS 경로를 태웠는지 증명하지 못하면 green 결과는 OOS 에 대해 아무것도 보장하지 못한다. 실제로 `cbrd_24983`(CBRD-26867)에서 `content` 가 `VARCHAR` 라 문자열 압축 때문에 raw 95KB 데이터도 OOS 가 발동하지 않을 수 있다. 압축 후 크기를 확인하지 않으면 "통과" 가 거짓 양성이 된다.

**이슈 수행 방안**:

- 검증 6대 원칙 P1~P6 을 모든 시나리오에 적용한다. 핵심은 P1 - OOS 발동을 먼저 증명한다. 권위 있는 게이트는 debug 빌드의 `oos.log` 의 'inserted to oid=' grep 뿐이다. `DISK_SIZE` 는 전제조건일 뿐 증명이 아니며, `cubrid spacedb` 는 현재 게이트로 쓸 수 없다.
- 결정적 트리거(P2): `BIT VARYING` + `CAST(REPEAT('AA', N) AS BIT VARYING)`(비압축, N = 정확한 디스크 바이트) 또는 realistic `VARCHAR`/JSON + `enable_string_compression=no`(`system_parameter.c:4115`, 기본값 `yes`).
- HA(P5): 값 동등성만 보장하고 OID 동등성은 보장하지 않는다(slave 는 자체 `oos_insert` 를 수행하므로 OOS OID 가 다를 수 있다).
- 4개 버킷 시나리오를 전달한다: SQL(SQL-01~12), Shell(SH-01~11), HA SQL `ha_repl`(HSQL-01~05), HA Shell `ha_shell`(HSH-01~04). 불변식 #1~#6 커버리지 매트릭스 포함.
- QA 툴링 선행과제 T1/T2 는 별도 child ticket 후보로 분리한다: T1 `cubrid spacedb` 에 `SPACEDB_OOS_FILE` 카테고리 추가, T2 OOS 파일 descriptor 에 parent HFID 저장. T1/T2 도입 전까지 OOS merge-gate 스위트는 debug 빌드에서 실행한다.
- 범위 외: OID 재사용/dedup(구 M3, 취소), ordered-fix deadlock(구 M4, 취소), CHAR-as-OOS(미구현).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 QA 시나리오 실행/리뷰 단계에서 참고하면 된다.

### Summary

- **목적**: OOS 병합 전 QA 검증 시나리오 4종(SQL/Shell/HA SQL/HA Shell)을 표준 OOS 발동 게이트와 함께 전달한다.
- **배경**: OOS 는 임계(레코드 약 2KB + 컬럼 512B)를 넘을 때만 동작하고, release 빌드에는 발동 증명 도구가 없어 검증의 거짓 양성 위험이 크다.
- **변경 사항**: 제품 코드 변경 없음. 검증 원칙 P1~P6 + 32개 시나리오(SQL 12 + Shell 11 + HA SQL 5 + HA Shell 4) + 불변식 매트릭스 + 툴링 선행과제 T1/T2.
- **영향 범위**: QA 검증 프로세스. 제품 코드 비변경. T1/T2 는 후속 개선 티켓 후보.

---

## Description

### 배경

OOS 는 heap 레코드의 큰 가변 컬럼(`recdes` - heap 레코드 디스크립터 - 안의 데이터)을 테이블별 OOS 파일(`FILE_OOS`)로 분리 저장해, 작은 컬럼만 읽을 때 불필요한 디스크 I/O 를 줄이는 기능이다. M1(POC)에서 insert/read/update/delete + WAL(Write-Ahead Logging - 변경 전 로그 선기록) + 복구 + 복제가 구현됐고, M2 에서 drop table, bestspace(빈 공간 많은 페이지를 빠르게 찾는 힌트 구조) 최적화, in-page compaction, vacuum(더 이상 보이지 않는 레코드의 공간을 회수하는 백그라운드 작업) 연동이 추가됐다.

### 목적

팀장 요청("oos 병합 시 qa팀에 전달할 검증 시나리오도 정리해서 이슈로 올려주세요")에 따라, `feature/oos-m2` 병합 게이트에서 QA 가 실행할 검증 시나리오를 표준화해 전달한다. 시나리오는 무엇을 테스트할지와 통과를 어떻게 증명할지를 함께 규정한다. CTP(CUBRID 테스트 플랫폼) 테스트 포맷(`cases/`, `answers/`, `*.sh`, `init.sh`/`make_ha.sh`)으로의 변환은 QA 몫이다.

### 핵심 위험: OOS 발동 증명 (P1)

가장 중요한 교훈은 `cbrd_24983`(CBRD-26867)에서 나왔다. `cubrid` 는 문자열을 압축하므로 OOS 트리거는 raw 크기가 아니라 **압축 후 크기** 를 기준으로 판단한다. 따라서 raw 95KB `VARCHAR` 도 OOS 가 발동하지 않을 수 있다. OOS 발동을 증명하지 못한 green 결과는 통과가 아니다. release 빌드는 `cubrid applyinfo` 의 Fail=0 만 보고 통과로 오판하기 쉬우므로, 발동 증명 게이트가 반드시 선행해야 한다.

---

## Specification Changes

제품 스펙 변경 없음. 아래는 QA 검증 시 필요한 테스트 구성 요건이다(제품 스펙 변경 아님):

- 결정적 OOS 트리거를 위해 `enable_string_compression=no`(server 파라미터) 사용 가능. realistic `VARCHAR`/JSON 데이터를 비압축으로 두어 임계를 확실히 넘긴다.
- OOS merge-gate 스위트는 debug 빌드에서 실행한다(`./build.sh -m debug`; `oos.log` 발동 게이트가 release 에서는 컴파일 제외됨). 자세한 이유는 아래 Tooling 선행과제 T1 참고.
- debug 게이트만으로는 실제 출하 바이너리(release)를 검증하지 못한다. 따라서 debug 게이트 통과와 별도로 release 빌드 smoke 통과를 병합 조건에 포함한다.

---

## Implementation

### 검증 원칙 (모든 시나리오 공통)

| ID | 원칙 | 근거 |
|----|------|------|
| P1 | OOS 발동을 먼저 증명한다. 권위 게이트 = debug 빌드 + `grep 'inserted to oid=' $CUBRID/log/oos.log`(insert 단위 증명, `oos_file.cpp`). `DISK_SIZE` 는 전제조건(값이 OOS 저장이든 inline 이든 전체 값 크기를 반환)일 뿐 증명이 아니다. `cubrid spacedb` 는 현재 게이트 불가(T1). | `cbrd_24983`: 압축으로 인해 raw 95KB `VARCHAR` 도 OOS 미발동 가능 |
| P2 | 결정적 트리거: (a) `BIT VARYING` 의 `CAST(REPEAT('AA', N) AS BIT VARYING)`(비압축, N = 디스크 바이트) 또는 (b) realistic `VARCHAR`/JSON + `enable_string_compression=no`. 기본 압축 `VARCHAR` 에 의존 금지. | 압축으로 기본 `VARCHAR` 크기가 비결정적이라 트리거가 무력화될 수 있음. `enable_string_compression` 기본값 `yes`(`system_parameter.c:4115`, `PRM_FORCE_SERVER` - `cubrid.conf` 에 설정 후 서버 재시작 필요, 세션 단위 변경 불가) |
| P3 | 값 크기는 `DISK_SIZE(col)`(바이트)로 확인. `LENGTH()`(BIT 는 비트 단위)는 금지. `DISK_SIZE` 는 512B 전제조건만 확인하고 OOS 저장 자체는 증명하지 못함 - 그건 P1 게이트만 가능. | |
| P4 | 값마다 구분되는 hex 패턴('AA','BB','CC')을 써서 행/컬럼 간 교차 오염을 탐지. | |
| P5 | HA 는 값 동등성만 보장하고 OID 동등성은 보장하지 않는다(slave 는 자체 `oos_insert`). | 불변식 #5 |
| P6 | OOS 트리거 = 레코드 > `DB_PAGESIZE/8`(약 2KB) AND 가변 컬럼 > 512B(인라인 OID 치환 시 절감이 의미 있어지는 하한). 두 임계를 모두 넘기지 못하는 시나리오는 OOS 코드를 실행하지 않음. | `heap_attrinfo_determine_disk_layout()` - 레코드 임계 `heap_file.c:12466`, 컬럼 512B 테스트 `:12472` |

### 공통 셋업

```sql
-- N 바이트(비압축):
CAST(REPEAT('AA', N) AS BIT VARYING)        -- DISK_SIZE = N

CREATE TABLE oos_test (
    id        INT PRIMARY KEY,
    small_col VARCHAR(100),
    big_col1  BIT VARYING,
    big_col2  BIT VARYING
);
```

```bash
# debug 빌드 필요(release 는 oos.log 게이트가 컴파일 제외됨):  ./build.sh -m debug
# realistic 타입의 결정적 트리거(server 파라미터, cubrid.conf):  enable_string_compression=no

# OOS 발동 게이트(권위, debug 빌드):
#   ls -l $CUBRID/log/oos.log          # 파일 생성 먼저 확인 - 없거나 비면 환경 미비(게이트 실패 아님)
#   grep 'inserted to oid=' $CUBRID/log/oos.log
#   기대 라인 예: ... OOS [DEBUG](oos_insert:1081): inserted to oid={vol=1,page=33,slot=4}
#   (oos.log 기본 레벨이 DEBUG 라 별도 설정 불필요; $CUBRID 미설정/디렉터리 쓰기불가면 라인이 조용히 누락됨)
# OOS 발동 게이트(release):  현재 신뢰 불가 - cubrid spacedb 가 OOS 를 heap 으로 오집계/abort(T1)

# HA 복제 게이트(slave 에서; applyinfo = slave 복제 반영 상태/지연 보고 HA 진단 도구):
#   cubrid applyinfo -r <master_host> -L <slave_copylogdb_dir> <db> -a | grep Fail
#   => "Fail : 0"
#   -L 은 slave 의 copylogdb 대상 디렉터리(HA 구성/make_ha.sh 가 설정한 경로로 치환)
```

### Bucket 1 - SQL (CTP `sql`: `cases/*.sql` + `answers/`)

단일 노드에서 OOS 읽기/쓰기 경로의 기능 정확성.

| ID | 시나리오 | 셋업(핵심 데이터) | OOS 발동 게이트 | 검증 / 기대 | 불변식/기능 |
|----|----------|-------------------|-----------------|-------------|-------------|
| SQL-01 | INSERT + SELECT 왕복 | `big_col1=REPEAT('AA',1700)`, `big_col2=REPEAT('BB',600)`(레코드 > 2KB) | `DISK_SIZE`=1700, 600 | 값 동등(`col = CAST(...)` -> 1), 크기 정확 | INSERT/SELECT resolve |
| SQL-02 | 임계 미달은 heap 유지 | 레코드 약 1.5KB(`big_col1=REPEAT('AA',400)`) | 이 insert 에 대한 `oos.log` 'inserted' 라인 없음 | 행 정상, OOS 미발동 | 트리거 음성 |
| SQL-03 | 부분 활성화 | 레코드 > 2KB, `big_col1`=1700B(>512), `big_col2`=400B(<512) | `big_col1` 만 발동 | `big_col1` 만 OOS, `big_col2` heap 잔류, 둘 다 정확 | 트리거 granularity |
| SQL-04 | 멀티청크 단일 값(OOS 페이지 초과) | `big_col1=REPEAT('AA',50000)`(약 50KB) | `oos.log` 'inserted to oid=' 청크당 1회 출현, `DISK_SIZE`=50000 | 체인 재조립 후 값 동등 | 멀티청크 체인 |
| SQL-05 | OOS 컬럼 UPDATE | 1700B insert 후 `UPDATE ... SET big_col1=REPEAT('CC',1700)` | `DISK_SIZE` 신규=1700 | 신규 값 정확, 구 값은 vacuum 이 후처리 | UPDATE(항상 신규 OID) |
| SQL-06 | 비-OOS 컬럼 UPDATE | OOS 행에 `UPDATE ... SET small_col='x'` | OOS 여전히 발동 | 큰 컬럼 값 불변/정확 | 항상 신규 OID(M2) |
| SQL-07 | DELETE + COUNT | OOS 행 삭제 | 해당 없음 | `COUNT(*)` 감소, OOS 정리는 vacuum(Bucket 2)으로 지연 | DELETE |
| SQL-08 | OOS UPDATE 의 ROLLBACK | `UPDATE big_col1`; `ROLLBACK` | 해당 없음 | undo 레코드의 OOS OID 로 원본 복원(resolved 값 아님) | 불변식 #2 |
| SQL-09 | MVCC(다중 버전 동시성 제어) 격리 | S1 이 OOS 행 update(미커밋), S2 가 read | 해당 없음 | S2 는 이전 버전 재구성으로 구 값 조회 | 불변식 #2 / MVCC |
| SQL-10 | 엣지 케이스 | (a) OOS 대상 컬럼 NULL; (b) 길이 0 `BIT VARYING`; (c) 한 행에 OOS 컬럼 10개 이상; (d) 정확히 512B(미발동) | 케이스별 `oos.log` / `DISK_SIZE` | 각각 정상, 512B 는 OOS 미발동 | 엣지/경계 |
| SQL-11 | OVF + OOS 동시 | 한 행에 고정 `CHAR` 로 recdes > 16K(overflow page) AND `BIT VARYING` > 512B(OOS) | `oos.log` 발동 + overflow page 존재 | 두 컬럼 모두 정확히 재구성. 단 OVF/OOS 공존은 OOS-CONTEXT 5장 미검증 항목 - overflow 가 OOS 를 단락(short-circuit)하면 실제 동작을 기록(병합 차단 아님) | OVF x OOS 상호작용 |
| SQL-12 | CDC / flashback OOS resolve(CDC/flashback 가 병합 범위일 때만) | OOS 행 insert/update 후 CDC/flashback 으로 read | 원본 쓰기 시 `oos.log` | 기능 존재 시 OOS OID 가 값으로 resolve(raw OID 아님). 기능 미구현(OOS-CONTEXT 5장 known bug)이면 실패가 정상 - 병합 차단 아님, 별도 추적 | 알려진 버그 |

### Bucket 2 - Shell (CTP `shell`: `*.sh` + `cases/`/`answers/`)

SQL 테스트가 닿지 못하는 시스템 레벨: 크래시 복구, durability, vacuum, drop, 공간 관리.

| ID | 시나리오 | 방법 | OOS 발동 게이트 | 검증 / 기대 | 불변식/기능 |
|----|----------|------|-----------------|-------------|-------------|
| SH-01 | 커밋된 INSERT 가 크래시 후 생존 | OOS 행 INSERT + COMMIT -> `kill -9` -> 재시작 | kill 전 oos.log | 재시작 후 행/값 존재 | 불변식 #1(redo) |
| SH-02 | 미커밋 INSERT 가 undo | INSERT(미커밋) -> `kill -9` -> 재시작 | kill 전 oos.log | 행 사라짐, OOS orphan 없음(OOS 파일 페이지 덤프로 확인; spacedb 불가, T1) | undo |
| SH-03 | 미커밋 UPDATE 가 undo | `UPDATE big_col1`(미커밋) -> 크래시 -> 재시작 | 해당 없음 | 원본 값 복원 | 불변식 #2 |
| SH-04 | 멀티청크가 크래시 생존 | 50KB 값 INSERT + COMMIT -> 크래시 -> 재시작 | `oos.log` 청크당 1회 | 체인 무결, 값 동등 | 불변식 #1 |
| SH-05 | vacuum 이 죽은 OOS 회수 | 커밋된 OOS 행 DELETE -> vacuum 강제 -> OOS 파일 페이지 수 확인 | 삭제 전 oos.log | OOS 파일 페이지 사용 감소, orphan 없음(spacedb 불가, debug 덤프로 확인, T1) | M2 vacuum 연동, 불변식 #3 |
| SH-06 | DROP TABLE 이 OOS 파일 파괴 | OOS 테이블 생성/적재 -> `DROP TABLE` -> 파일/페이지 확인 | drop 전 oos.log | OOS 파일 제거, 공간 반환(파일 존재/덤프로 확인; spacedb 불가, T1) | M2 `oos_file_destroy` |
| SH-07 | 삭제 후 bestspace 재사용 | 일부 DELETE -> 유사 크기 재삽입 -> OOS 파일 페이지 수 확인 | oos.log | 해제된 OOS 페이지 재사용(파일 무한 증가 없음; debug 덤프 확인, T1) | M2 3-tier bestspace(CBRD-26658) |
| SH-08 | unloaddb / loaddb 왕복 | OOS 테이블 적재 -> `cubrid unloaddb` -> 새 db 로 `cubrid loaddb` -> 비교 | 재적재 시 oos.log | 모든 값 동등, 재적재 완료(성능 주시, CBRD-26458) | 데이터 이동 |
| SH-09 | in-page compaction | 한 OOS 페이지에 update 다발 발생 | oos.log | 페이지 내 단편화 회수(정밀 공간 측정은 T1 미해결로 debug 계측 사용) | M2 compaction |
| SH-10 | 동시 OOS insert | N 세션이 같은 테이블/OOS 파일에 동시 INSERT + COMMIT | 세션별 oos.log | 데드락/에러 없음, 전 행 존재/정확, OOS 파일 일관 | M2 3-tier bestspace(conditional-latch) |
| SH-11 | bulk / stress | OOS 행 1000개 이상; 한 행 50회 이상 반복 update | oos.log | 종료 후 전 값 정확, leak/orphan 없음(vacuum 후) | stress/완전성 |

주: 공간/orphan 검증(SH-02/05/06/07)은 T1 미해결로 `cubrid spacedb` 대신 debug 계측(OOS 파일 페이지 수 직접 덤프, `oos.log` delete 라인)으로 확인한다. `cubrid spacedb` 는 OOS 포함 DB 에서 abort 하므로 게이트/검증 모두 불가하다.

### Bucket 3 - HA SQL (`ha_repl`: SQL 을 master/slave 환경에서 재생, master/slave/answer 비교)

OOS 연산의 복제 값 동등성. 값 동등성만 검증하고 OID 동등성은 검증하지 않음(P5).

| ID | 시나리오 | master 동작 | OOS 발동 게이트(master) | 검증(slave) | 불변식 |
|----|----------|-------------|--------------------------|-------------|--------|
| HSQL-01 | INSERT OOS 행 복제 | 1700B/600B 행 insert | master oos.log | slave 값 동등 + `DISK_SIZE` 일치, `applyinfo` Fail=0 | #5 |
| HSQL-02 | UPDATE OOS 복제 | `UPDATE big_col1` | master oos.log | slave 신규 값 표시 | #5 |
| HSQL-03 | DELETE 복제 + slave vacuum | OOS 행 DELETE | 해당 없음 | slave 행 사라짐, slave vacuum 후 orphan 없음 | #5 + #3 |
| HSQL-04 | 멀티청크 복제 | 50KB 값 insert | master `oos.log` 청크당 1회 | slave 값 동등(체인 독립 재구성) | #5 멀티청크 |
| HSQL-05 | OOS/비-OOS 혼합 배치 | OOS + 작은 행 배치 | master oos.log | slave 전 값 정확, 섞임 없음 | #5 |

### Bucket 4 - HA Shell (`ha_shell`: failover 오케스트레이션; `init.sh`/`make_ha.sh` 하니스)

failover + 복제 지연 + `applyinfo`. 검증된 `cbrd_24983` 병합 게이트를 일반화.

| ID | 시나리오 | 방법 | OOS 발동 게이트 | 검증 / 기대 | 불변식 |
|----|----------|------|-----------------|-------------|--------|
| HSH-01 | `cbrd_24983` 일반화 | master 에서 OOS 다수 테이블 bulk `loaddb`(realistic `VARCHAR`/JSON 을 `enable_string_compression=no` 로 결정적화) | master `oos.log`(debug) - 필수 선행; spacedb 게이트 불가(T1) | slave `applyinfo ... \| grep Fail`=0; slave `COUNT(*)` 일치; 행별 값 동등 | #1 + #5(게이트) |
| HSH-02 | OOS 적재 중 failover | OOS 다수 적재 시작 -> master `kill -9` -> slave 승격 | kill 전 oos.log | 승격된 slave 에 커밋된 OOS 데이터 무결/정확 | failover durability |
| HSH-03 | 복제 지연 따라잡기(멀티청크) | 대형 멀티청크 적재 -> slave LSA(Log Sequence Address - 로그 위치 지표) 관찰 | master `oos.log` 청크당 1회 | slave `applyinfo` LSA 따라잡음, Fail=0, 값 동등 | 복제 지연 + 멀티청크 |
| HSH-04 | 신규 slave 재구축 | OOS 적재된 master 대상으로 `copylogdb`(master 로그를 slave 로 복사)/`applylogdb`(복사 로그를 slave 에 반영) 로 slave 신규 구축 | master oos.log | slave 가 전 OOS 값 정확히 재구성 | 복제 부트스트랩 |

### 불변식 커버리지 매트릭스

불변식은 OOS-CONTEXT 의 Recovery/Replication/MVCC 정의를 따른다.

| 불변식 | 커버 시나리오 |
|--------|---------------|
| #1 WAL 완전성(크래시 -> 커밋 상태) | SH-01, SH-04, HSH-01 |
| #2 undo 가 이전 레코드를 OOS OID 포함 그대로 보존(resolved 값 아님) | SQL-08, SQL-09, SH-03 |
| #3 update 후 orphan OOS 없음; vacuum 이 구 OID 정리 | SH-05, HSQL-03 |
| #4 delete 안전성(vacuum 까지 OOS 유지) | SQL-07, SH-05 |
| #5 복제 로그 완전성(slave 값 동등성) | HSQL-01~05, HSH-01/03/04 |
| #6 OOS 파일 - heap 파일 1:1 | SH-06(drop), 전반 암묵 |

### QA 툴링 선행과제 (별도 child ticket 후보)

소스 대조 결과, OOS 발동 증명 방식을 제약하는 관측성 공백 2건이 확인됐다. 도입 전까지 OOS merge-gate 스위트는 debug 빌드에서 실행해야 한다(`oos.log` 게이트는 release 에서 컴파일 제외됨). release 실행은 production 대표성 확인용일 뿐 OOS 발동을 자체 증명할 수 없다.

| ID | 공백(코드 확인) | QA 영향 | 처리 방향 |
|----|------------------|---------|-----------|
| T1 | `cubrid spacedb` 가 `FILE_OOS` 를 heap 파일로 집계(`file_manager.c:12236`, `assert_release(false)` 워크어라운드) - `SPACEDB_OOS_FILE` 카테고리 부재 | OOS 포함 DB 에서 `cubrid spacedb` 가 `assert_release(false)`(`file_manager.c:12237`)로 abort - spacedb 는 OOS 공간 게이트/검증에 일절 사용 불가. 대체로 debug 계측(OOS 파일 페이지 수 덤프)을 쓴다 | 후속 티켓 후보: `SPACEDB_OOS_FILE` 추가 |
| T2 | OOS 파일 `FILE_DESCRIPTORS` 에 parent HFID(Heap File ID - 테이블 heap 파일 식별자) 미저장(`file_manager.c:1431`) - `cubrid diagdb`/`spacedb` 가 OOS 파일을 테이블에 귀속 불가 | 어느 테이블 데이터가 OOS 됐는지 툴로 검증 불가 | 후속 티켓 후보: OOS 파일 descriptor 에 parent HFID 저장 |

> 압축 쪽은 이미 해결돼 있다: `enable_string_compression=no`(server 파라미터, 기본값 `yes`)로 realistic `VARCHAR`/JSON 이 OOS 임계를 결정적으로 넘긴다 - 신규 기능 불필요. T1/T2 가 남은 과제다.

### 범위 외 (OOS 동작으로 테스트하지 말 것)

- 변경 없는 컬럼 UPDATE 시 OOS OID 재사용/dedup - 취소(구 M3). 현재 코드는 항상 새 OID 할당.
- ordered-fix 데드락 방지, OOS 모니터링 도구 - 취소(구 M4).
- PEEK 모드 OOS read, across-page compaction - 미래 과제, M2 비포함.
- CHAR 타입 OOS 후보화 - 미구현(`oos_file.cpp`/`heap_file.c` 에 결합 없음 확인).

---

## Acceptance Criteria

- [ ] 4개 버킷 시나리오(SQL 12 + Shell 11 + HA SQL 5 + HA Shell 4)가 CTP 포맷으로 작성돼 QA 스위트에 등록됨
- [ ] 모든 read/복제 단정 시나리오가 P1 OOS 발동 게이트 증거(oos.log 또는 동등 수단)를 함께 수집함
- [ ] 불변식 #1~#6 이 매트릭스대로 최소 1개 시나리오로 커버됨
- [ ] HA 버킷이 값 동등성으로 검증(OID 동등성 아님), `applyinfo` Fail=0 확인
- [ ] OOS merge-gate 스위트가 debug 빌드에서 통과(green)하고, 발동 게이트가 통과한 상태에서의 실패 0건
- [ ] T1/T2 가 별도 티켓으로 분리 등록됨(또는 본 이슈에서 범위 확정)

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과(병합 차단 OOS 결함 0건; 발동 게이트 통과 상태의 실패는 child bug 로 분리, 부모 epic CBRD-26583)
- [ ] 검증 시나리오 문서/매뉴얼 반영

---

## 참고 코드

- `src/storage/heap_file.c:12472` - OOS 컬럼 후보 판정(`column_size > 512`)
- `src/storage/oos_file.cpp` - `oos_insert`/`oos_read`, debug 시 `inserted to oid=` 로그
- `src/storage/file_manager.c:12236` - spacedb `FILE_OOS` 오집계(T1)
- `src/storage/file_manager.c:1431` - OOS 파일 parent HFID 부재(T2)
- `src/base/system_parameter.c:4115` - `enable_string_compression`(기본값 `yes`)

## Remarks

- 관련: 부모 epic CBRD-26583, HA triage CBRD-26854, `cbrd_24983` 검증 CBRD-26867
- 원본 작업 문서: `oos-qa-validation-scenarios.md`(`feature/oos-m2` 워크트리)
- T1/T2 는 본 이슈의 child ticket 으로 분리 권장(미생성 상태)
